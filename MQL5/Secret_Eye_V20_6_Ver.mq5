//+------------------------------------------------------------------+
//|           Stochastic Straight Algo Strategy V20.6.mq5           |
//|                                  Copyright 2025, Sanjeevas Inc.  |
//|                                             https://www.sanjeevas.com|
//+------------------------------------------------------------------+

// V20.6 Release - Aeron Binary Publisher Integration:
// - Integrated Aeron low-latency binary message publishing for trading signals
// - Added 104-byte binary protocol compatible with NinjaTrader AeronSignalPublisher
// - Dual signal broadcasting: LongEntry1/2 and ShortEntry1/2 with confidence metrics
// - Exit signal publishing: LongStopLoss, ShortStopLoss, and ProfitTarget events
// - Publisher lifecycle management in OnInit()/OnDeinit() with error handling
// - Configurable Aeron channel (IPC/UDP), stream ID, and media driver directory
// - Dynamic confidence calculation from stochastic indicator K-D spread
// - Comprehensive logging with success indicators and diagnostic messages
// - Full interoperability with existing JSON publisher (both run simultaneously)
// - Sub-millisecond signal distribution via shared memory (IPC) or UDP
//
// V20.5 Release - Aeron Binary Publisher (Initial Implementation)
// V20.4 Release - JSON Trade Publisher:
// - Added JSON trade telemetry publishing to Kafka-compatible endpoints
// - Dual-entry signal broadcasting (entry1 stop-loss only, entry2 with profit target)
// - Execution fill tracking with P&L and position state
// - Exit signal publishing for Stop Loss and Profit Target closures
// - Enhanced OnTradeTransaction to detect and publish exit reasons
// - Configurable message formats (New/Legacy/Both)
// - Low-latency design (<1ms signals, <2ms executions)
//
// V20.3 Previous Features - Fill-Or-Kill (FOK) Order Execution
// V20.2 Previous Features - Initial Order Delay
// V20.1 Previous Features - Daily Profit Protection System
// V20.0 Previous Features - REST API Trading Hours Integration

#property copyright "Copyright 2025, Sanjeevas Inc."
#property link      "https://www.sanjeevas.com"
#property version   "20.60"
#property description "V20.6 - Aeron Binary Publisher, JSON Publisher, FOK Orders, Delay, Profit Protection"
#include <Trade\Trade.mqh>
#include "AeronBridge.mqh"
#include "AeronPublisher.mqh"

//--- Message Format Enum
enum ENUM_MESSAGE_FORMAT
{
    MSG_NEW_ONLY,    // New Format Only
    MSG_LEGACY_ONLY, // Legacy Format Only
    MSG_BOTH         // Both Formats (default)
};

//--- JSON parsing structures (simplified for MQL5)
struct TradingWindow
{
    string start;
    string end;
};

struct TradingHoursResponse
{
    string symbol;
    string timezone;
    TradingWindow monday;
    TradingWindow tuesday;
    TradingWindow wednesday;
    TradingWindow thursday;
    TradingWindow friday;
    TradingWindow saturday;
    TradingWindow sunday;
};

//--- input parameters
input group             "Strategy Settings"
input int               K_Period = 10;                  // K Period
input int               D_Period = 10;                  // D Period
input int               slowing = 3;                    // Slowing
input ENUM_TIMEFRAMES   timeFrame = PERIOD_M15;         // Stochastic Timeframe

input group             "Trade Management"
input double            lot = 0.02;                     // Total Volume of position
input int               SL = 50;                        // Stop Loss (in points)
input int               TP = 100;                       // Take Profit for Scalp (in points)
input double            scalpLotMultiplier = 0.5;       // Multiplier for scalp position (0.5 = 50%)
input double            trendLotMultiplier = 0.5;       // Multiplier for trend position (0.5 = 50%)

input group             "EA Settings"
input bool              on = true;                      // SWITCH EA On/Off
input bool              ImmediateEntryOnLoad = false;   // ONCE: Enter trade immediately on load
input int               DelayOnInitialOrder = 0;        // Delay first trade of the day (in seconds)
input bool              ShowAlerts = true;              // Show dialog box alerts for trades
input bool              EnableKillSwitch = false;       // Enable position closure at end time
input bool              AutoDST = true;                 // Automatically handle DST transitions
input int               ManualServerOffset = 0;         // Manual server offset override (0 = auto-detect)
input double            MAX_DAILY_LOSS_PERCENTAGE = 2.5;// Daily loss percentage limit
input ulong             digital_name_ = 4;              // Digital name of Expert Advisor
input ulong             code_interaction_ = 1;          // Code of interaction

input group             "API Trading Hours"
input bool              UseAPITradingHours = true;      // Enable REST API trading hours
input string            HOST_URI = "192.168.2.17:8000";   // API Host URI (hostname:port)
input string            API_Symbol = "ES_F";            // Symbol for API query (e.g., 6E_F for EURUSD)
input int               ManualStartTime = 0;            // Fallback start time (hour)
input int               ManualStartMinute = 0;          // Fallback start time (minute)
input int               ManualEndTime = 23;             // Fallback end time (hour)
input int               ManualEndMinute = 0;            // Fallback end time (minute)

input group             "Advanced Position Management"
input bool              WaitForClosureConfirmation = true; // Wait for reverse positions to close before opening new ones
input bool              UseFillOrKill = false;          // Use Fill-Or-Kill (FOK) order execution

input group             "JSON Publishing"
input bool              PublishToKafka = true;          // Enable JSON publishing
input string            KafkaTopicName = "secreteye-signals"; // Topic name(s) - single or comma-separated (e.g., "topic1,topic2,topic3")
input ENUM_MESSAGE_FORMAT MessageFormat = MSG_BOTH;     // Message format selection
input string            PublishHostUri = "192.168.2.17:8000"; // Publishing host (overrides HOST_URI)
input string            InstrumentFullName = "";        // Instrument name for publishing (empty = use _Symbol)

input group             "Aeron Publishing"
input bool              EnableAeronPublishing = true;      // Enable Aeron binary signal publishing
input string            AeronPublishChannel = "aeron:ipc"; // Aeron publish channel
input int               AeronPublishStreamId = 1001;       // Aeron publish stream ID
input string            AeronPublishDir = "C:\\aeron\\standalone"; // Aeron directory
input string            AeronSourceTag = "SecretEye_V20_6"; // Source strategy identifier
input string            AeronInstrumentName = "";          // Custom symbol/instrument name for Aeron (e.g. "ES") - sets both fields

//--- Global variables
CTrade              trade;
static ulong        magic;
int                 stochHandle;
static datetime     lastBarTime = 0;
static double       todayStartingBalance = 0;
bool                stopTradingForDay = false;
static int          detectedServerOffset = 0;
static bool         killSwitchExecuted = false;
static bool         firstTradeOfDayPlaced = false;

// V20.2 - Immediate Entry Variables
static bool         immediateEntryPending = false;
static bool         immediateEntryCompleted = false;

// V20.1 - Daily Profit Protection Variables
static double       dailyMaxProfitBalance = 0;
static bool         profitProtectionActive = false;
static bool         stopTradingForProfitProtection = false;

// V20 - API Trading Hours Variables
static TradingHoursResponse cachedTradingHours;
static datetime     lastAPIFetch = 0;
static bool         apiDataValid = false;
static int          currentStartHour = 0;
static int          currentStartMinute = 0;
static int          currentEndHour = 23;
static int          currentEndMinute = 0;
static int          lastDayChecked = -1;               // Track last day for daily updates

// V19 - Dual Position Tracking Variables
bool scalpBuyOpened   = false, scalpSellOpened  = false;
bool trendBuyOpened   = false, trendSellOpened  = false;
ulong scalpBuyTicket  = 0,     scalpSellTicket  = 0;
ulong trendBuyTicket  = 0,     trendSellTicket  = 0;

// V20.4 - JSON Publishing State
static string  lastPublishedSignalId = "";
static ulong   lastPublishedTicket = 0;
static int     executionSequenceCounter = 0;
static uchar   publishFlags = 0;  // Bitmask: 0x01=signal published this tick, 0x02=exec published

#define PUBLISH_FLAG_SIGNAL   0x01
#define PUBLISH_FLAG_EXEC     0x02

// V20.4 - Static buffers for JSON messages (4KB each, pre-allocated)
static char    jsonSignalBuffer[4096];
static char    jsonExecBuffer[4096];
static char    httpResponseBuffer[2048];

//--- Forward Declarations
void UpdateAllPositionStatus();
void CloseAllBuyPositions();
void CloseAllSellPositions();
bool IsTradingAllowed();
bool IsInitialDelayOver();
void CheckDailyLossLimit();
void CheckDailyProfitProtection();
void OpenBuyPositions();
void OpenSellPositions();
void ExecuteImmediateTrade();
bool PositionExistsByTicket(ulong ticket);
void RecoverExistingPositions();
void CheckKillSwitchPostTimeRecovery();
bool AreAllReversePositionsClosed(bool checkingForBuy);
bool IsEasternDST(datetime time);
int GetEasternOffset(datetime time);
int DetectBrokerServerOffset();
int GetServerToEasternOffset(datetime time);
bool FetchTradingHoursFromAPI();
bool ParseTradingHoursJSON(string jsonResponse);
void SetTradingHoursForToday();
void CheckAndUpdateDailyTradingHours();
string GetDayOfWeekString(int dayOfWeek);
bool ParseTimeString(string timeStr, int &hour, int &minute);

// V20.4 - JSON Publishing Forward Declarations
string GetInstrumentSymbol(string fullName);
string TimeToISO8601(datetime time);
string TimeToESTReadable(datetime time);
bool BuildNewFormatSignal(string action, int stopLossTicks, int takeProfitTicks, string signalId);
bool BuildLegacyFormatSignal(string action, string signalId);
bool BuildExecutionFormat(string action, string executionType, string orderAction,
                          string orderName, double price, double quantity,
                          string marketPosition, double unrealizedPnL, double realizedPnL);
bool PublishJSON(char &buffer[], string topic);
void PublishExitSignal(string direction, string exitReason);

//+------------------------------------------------------------------+
//| V20.4 - Symbol Extraction Function                              |
//+------------------------------------------------------------------+

/**
 * @brief Extracts base symbol from full instrument name
 * @param fullName Full instrument name (e.g., "ES 12-25", "MES Mar'25")
 * @return Base symbol (e.g., "ES", "MES", "NQ")
 */
string GetInstrumentSymbol(string fullName)
{
    // Known futures symbols (expand as needed)
    string knownSymbols[] = {
        "ES", "NQ", "YM", "RTY", "GC", "SI", "CL", "NG", "ZB", "ZN",
        "MES", "MNQ", "MYM", "M2K", "MGC", "MCL", "6E", "6J", "6B", "6C"
    };
    
    // Check if any known symbol is prefix of fullName
    for(int i = 0; i < ArraySize(knownSymbols); i++)
    {
        if(StringFind(fullName, knownSymbols[i]) == 0)
        {
            return knownSymbols[i];
        }
    }
    
    // Fallback: extract first space-delimited token
    int spacePos = StringFind(fullName, " ");
    if(spacePos > 0)
    {
        return StringSubstr(fullName, 0, spacePos);
    }
    
    // Last resort: first 2-3 characters
    return StringSubstr(fullName, 0, MathMin(3, StringLen(fullName)));
}

//+------------------------------------------------------------------+
//| V20.4 - Topic Name Parsing Helper Functions                     |
//+------------------------------------------------------------------+

/**
 * @brief Parses comma-separated topic names from input string
 * @param topicInput Input string containing single or comma-separated topics
 * @param topics Output array to store parsed topic names
 * @return Number of topics parsed
 */
int ParseTopicNames(string topicInput, string &topics[])
{
    // Trim whitespace from input
    StringTrimLeft(topicInput);
    StringTrimRight(topicInput);
    
    // Check for empty input
    if(StringLen(topicInput) == 0)
    {
        ArrayResize(topics, 0);
        return 0;
    }
    
    // Count commas to estimate array size
    int commaCount = 0;
    for(int i = 0; i < StringLen(topicInput); i++)
    {
        if(StringGetCharacter(topicInput, i) == ',')
        {
            commaCount++;
        }
    }
    
    // Resize array to accommodate all topics
    int maxTopics = commaCount + 1;
    ArrayResize(topics, maxTopics);
    
    // Parse topics
    int topicCount = 0;
    int startPos = 0;
    
    for(int i = 0; i <= StringLen(topicInput); i++)
    {
        bool isComma = (i < StringLen(topicInput) && StringGetCharacter(topicInput, i) == ',');
        bool isEnd = (i == StringLen(topicInput));
        
        if(isComma || isEnd)
        {
            // Extract topic substring
            string topic = StringSubstr(topicInput, startPos, i - startPos);
            
            // Trim whitespace
            StringTrimLeft(topic);
            StringTrimRight(topic);
            
            // Add non-empty topics
            if(StringLen(topic) > 0)
            {
                topics[topicCount] = topic;
                topicCount++;
            }
            
            startPos = i + 1;
        }
    }
    
    // Resize array to actual topic count
    ArrayResize(topics, topicCount);
    return topicCount;
}

/**
 * @brief Publishes JSON payload to multiple topics
 * @param buffer Character array containing JSON payload (will be modified for each topic)
 * @param baseTopic Base topic name (used for logging)
 * @param topicSuffix Optional suffix to append to each topic (e.g., "-executions")
 * @return true if at least one publish succeeded, false if all failed
 */
bool PublishJSONToMultipleTopics(char &buffer[], string baseTopic, string topicSuffix = "")
{
    if(!PublishToKafka)
    {
        return true;  // Publishing disabled, no-op
    }
    
    // Parse topic names
    string topics[];
    int topicCount = ParseTopicNames(KafkaTopicName, topics);
    
    if(topicCount == 0)
    {
        Print("WARNING: No valid topics found in KafkaTopicName. Skipping publish.");
        return false;
    }
    
    // Track success/failure
    bool anySuccess = false;
    int successCount = 0;
    int failureCount = 0;
    
    // Publish to each topic
    for(int i = 0; i < topicCount; i++)
    {
        string targetTopic = topics[i] + topicSuffix;
        
        // Re-build the JSON payload with the current topic
        // Find the actual message content (everything after "message":")
        string originalPayload = CharArrayToString(buffer);
        
        // Extract the message content (between "message\":\" and the closing \")
        int messageStart = StringFind(originalPayload, "\"message\":\"");
        if(messageStart == -1)
        {
            Print("ERROR: Invalid payload format - cannot find 'message' field");
            failureCount++;
            continue;
        }
        
        messageStart += 11;  // Length of "\"message\":\"" - position at start of message content
        int messageEnd = StringLen(originalPayload) - 2;  // Before closing "}
        
        string messageContent = StringSubstr(originalPayload, messageStart, messageEnd - messageStart);
        
        // Build new payload with current topic
        string newPayload = StringFormat("{\"topic\":\"%s\",\"message\":\"%s\"}",
                                         targetTopic, messageContent);
        
        if(StringLen(newPayload) >= 4095)
        {
            Print("ERROR: Payload exceeds buffer size for topic '", targetTopic, "'");
            failureCount++;
            continue;
        }
        
        // Create temporary buffer for this topic
        char topicBuffer[4096];
        ArrayInitialize(topicBuffer, 0);
        StringToCharArray(newPayload, topicBuffer, 0, StringLen(newPayload));
        topicBuffer[StringLen(newPayload)] = 0;
        
        // Publish to this topic
        if(PublishJSON(topicBuffer, targetTopic))
        {
            successCount++;
            anySuccess = true;
        }
        else
        {
            failureCount++;
        }
    }
    
    // Log summary for multiple topics
    if(topicCount > 1)
    {
        Print("Multi-topic publish complete: ", successCount, " succeeded, ", failureCount, " failed");
    }
    
    return anySuccess;
}

//+------------------------------------------------------------------+
//| V20.4 - Timestamp Conversion Functions                          |
//+------------------------------------------------------------------+

/**
 * @brief Converts datetime to UTC ISO 8601 format (yyyy-MM-ddTHH:mm:ssZ)
 * @param time Datetime to convert
 * @return ISO 8601 string
 */
string TimeToISO8601(datetime time)
{
    MqlDateTime dt;
    TimeToStruct(time, dt);
    
    return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
                        dt.year, dt.mon, dt.day,
                        dt.hour, dt.min, dt.sec);
}

/**
 * @brief Converts datetime to EST readable format (yyyy-MM-dd HH:mm:ss)
 * @param time Datetime to convert (server time)
 * @return EST formatted string
 */
string TimeToESTReadable(datetime time)
{
    // Apply server-to-eastern offset (already computed in existing code)
    int serverToEasternOffset = GetServerToEasternOffset(time);
    
    MqlDateTime dt;
    TimeToStruct(time, dt);
    
    // Adjust to EST/EDT
    int estHour = dt.hour + serverToEasternOffset;
    if(estHour < 0) estHour += 24;
    if(estHour >= 24) estHour -= 24;
    
    return StringFormat("%04d-%02d-%02d %02d:%02d:%02d",
                        dt.year, dt.mon, dt.day,
                        estHour, dt.min, dt.sec);
}

//+------------------------------------------------------------------+
//| V20.4 - JSON Helper Functions                                   |
//+------------------------------------------------------------------+

/**
 * @brief Escapes double quotes in a string for JSON embedding
 */
string EscapeJsonString(string str)
{
    string result = str;
    StringReplace(result, "\\", "\\\\");
    StringReplace(result, "\"", "\\\"");
    return result;
}

//+------------------------------------------------------------------+
//| V20.4 - JSON Message Builders                                   |
//+------------------------------------------------------------------+

/**
 * @brief Builds New Format signal JSON
 * @param action Trade action (e.g., "longentry1", "shortentry2")
 * @param stopLossTicks Stop loss in ticks
 * @param takeProfitTicks Take profit in ticks (0 for entry1)
 * @param signalId GUID for this signal
 * @return true if successful
 */
bool BuildNewFormatSignal(string action, int stopLossTicks, int takeProfitTicks, string signalId)
{
    string symbol = GetInstrumentSymbol(_Symbol);
    string timestamp = TimeToISO8601(TimeCurrent());
    string timestampEST = TimeToESTReadable(TimeCurrent());
    
    // Use custom instrument name if provided, otherwise fall back to _Symbol
    string instrumentName = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : _Symbol;
    
    // Get TD Sequential values (simplified - extend as needed)
    double tdBuySignal = 0;
    double tdSellSignal = 0;
    if(StringFind(action, "long") >= 0) tdSellSignal = 1;
    if(StringFind(action, "short") >= 0) tdBuySignal = 1;
    
    // Build message as JSON object (not escaped string)
    string message = StringFormat(
        "{\"Symbol\":\"%s\",\"Action\":\"%s\",\"StopLossTicks\":%d,\"TakeProfitTicks\":%d,"
        "\"Timestamp\":\"%s\",\"TimestampEST\":\"%s\",\"SignalId\":\"%s\",\"Confidence\":%.2f,"
        "\"PositionSize\":%d,\"RiskMultiplier\":%.1f,\"Source\":\"Secret_Eye_V20_4\","
        "\"InstrumentFullName\":\"%s\",\"TDSequentialBuySignal\":%.0f,\"TDSequentialSellSignal\":%.0f,"
        "\"BodyMultiplier\":%.1f,\"RequirePerfection\":false}",
        symbol, action, stopLossTicks, takeProfitTicks,
        timestamp, timestampEST, signalId, 0.85,
        1, 1.0, instrumentName, tdBuySignal, tdSellSignal, 1.5
    );
    
    // Escape message for embedding in JSON string field
    string escapedMessage = EscapeJsonString(message);
    
    // Wrap message as escaped string for Pydantic validation
    string payload = StringFormat("{\"topic\":\"%s\",\"message\":\"%s\"}",
                                  KafkaTopicName, escapedMessage);
    
    if(StringLen(payload) >= 4095)  // Leave room for null terminator
    {
        Print("ERROR: New format payload exceeds buffer size: ", StringLen(payload));
        return false;
    }
    
    // Null-terminate to prevent "Extra data" errors
    ArrayInitialize(jsonSignalBuffer, 0);
    StringToCharArray(payload, jsonSignalBuffer, 0, StringLen(payload));
    jsonSignalBuffer[StringLen(payload)] = 0;  // Explicit null terminator
    return true;
}

/**
 * @brief Builds Legacy Format signal JSON
 */
bool BuildLegacyFormatSignal(string action, string signalId)
{
    // Legacy format only has 3 fields: instrumentFullName, action, timestamp
    string timestampEST = TimeToESTReadable(TimeCurrent());
    
    // Use custom instrument name if provided, otherwise fall back to _Symbol
    string instrumentName = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : _Symbol;
    
    // Build inner message content (NOT escaped yet)
    string message = StringFormat(
        "{\"instrumentFullName\":\"%s\",\"action\":\"%s\",\"timestamp\":\"%s\"}",
        instrumentName, action, timestampEST
    );
    
    // Escape message for embedding in JSON string field
    string escapedMessage = EscapeJsonString(message);
    
    // Wrap message as escaped string for Pydantic validation
    string payload = StringFormat("{\"topic\":\"%s\",\"message\":\"%s\"}",
                                  KafkaTopicName, escapedMessage);
    
    if(StringLen(payload) >= 4095)  // Leave room for null terminator
    {
        Print("ERROR: Legacy format payload exceeds buffer size: ", StringLen(payload));
        return false;
    }
    
    // Null-terminate to prevent "Extra data" errors
    ArrayInitialize(jsonSignalBuffer, 0);
    StringToCharArray(payload, jsonSignalBuffer, 0, StringLen(payload));
    jsonSignalBuffer[StringLen(payload)] = 0;  // Explicit null terminator
    return true;
}

/**
 * @brief Builds Execution Format JSON
 */
bool BuildExecutionFormat(string action, string executionType, string orderAction,
                          string orderName, double price, double quantity,
                          string marketPosition, double unrealizedPnL, double realizedPnL)
{
    string symbol = GetInstrumentSymbol(_Symbol);
    string timestamp = TimeToISO8601(TimeCurrent());
    string timestampEST = TimeToESTReadable(TimeCurrent());
    string executionId = StringFormat("%lld", GetTickCount64());
    
    // Use custom instrument name if provided, otherwise fall back to _Symbol
    string instrumentName = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : _Symbol;
    
    executionSequenceCounter++;
    
    // Escape double quotes in message content
    string message = StringFormat(
        "{\\\"Symbol\\\":\\\"%s\\\",\\\"Action\\\":\\\"%s\\\",\\\"ExecutionType\\\":\\\"%s\\\",\\\"OrderAction\\\":\\\"%s\\\","
        "\\\"OrderName\\\":\\\"%s\\\",\\\"ExecutionId\\\":\\\"%s\\\",\\\"Price\\\":%.5f,\\\"Quantity\\\":%.2f,"
        "\\\"MarketPosition\\\":\\\"%s\\\",\\\"UnrealizedPnL\\\":%.2f,\\\"RealizedPnL\\\":%.2f,"
        "\\\"ExecutionTime\\\":\\\"%s\\\",\\\"ExecutionTimeEST\\\":\\\"%s\\\",\\\"Timestamp\\\":\\\"%s\\\","
        "\\\"TimestampEST\\\":\\\"%s\\\",\\\"Source\\\":\\\"Secret_Eye_V20_4\\\",\\\"InstrumentFullName\\\":\\\"%s\\\","
        "\\\"ExecutionSequence\\\":%d}",
        symbol, action, executionType, orderAction, orderName, executionId, price, quantity,
        marketPosition, unrealizedPnL, realizedPnL, timestamp, timestampEST, timestamp,
        timestampEST, instrumentName, executionSequenceCounter
    );
    
    // Escape message for embedding in JSON string field
    string escapedMessage = EscapeJsonString(message);
    
    // Wrap message as escaped string for Pydantic validation
    string payload = StringFormat("{\"topic\":\"%s-executions\",\"message\":\"%s\"}",
                                  KafkaTopicName, escapedMessage);
    
    if(StringLen(payload) >= 4095)  // Leave room for null terminator
    {
        Print("ERROR: Execution format payload exceeds buffer size: ", StringLen(payload));
        return false;
    }
    
    // Null-terminate to prevent "Extra data" errors
    ArrayInitialize(jsonExecBuffer, 0);
    StringToCharArray(payload, jsonExecBuffer, 0, StringLen(payload));
    jsonExecBuffer[StringLen(payload)] = 0;  // Explicit null terminator
    return true;
}

//+------------------------------------------------------------------+
//| V20.4 - HTTP POST Adapter                                       |
//+------------------------------------------------------------------+

/**
 * @brief Posts JSON payload to /publish endpoint
 * @param buffer Character array containing JSON payload
 * @param topic Topic name for logging
 * @return true if HTTP 200 received, false otherwise
 */
bool PublishJSON(char &buffer[], string topic)
{
    if(!PublishToKafka)
    {
        return true;  // Publishing disabled, no-op
    }
    
    string url = "http://" + PublishHostUri + "/publish";
    string headers = "Content-Type: application/json\r\n";
    char result[];
    string resultHeaders;
    int timeout = 5000;  // 5 seconds
    
    // Find actual payload length (up to first null terminator)
    int payloadLength = 0;
    for(int i = 0; i < ArraySize(buffer); i++)
    {
        if(buffer[i] == 0)
        {
            payloadLength = i;
            break;
        }
    }
    
    if(payloadLength == 0)
    {
        Print("ERROR: Empty payload for topic '", topic, "'");
        return false;
    }
    
    // Create properly sized buffer for WebRequest
    char sendBuffer[];
    ArrayResize(sendBuffer, payloadLength);
    ArrayCopy(sendBuffer, buffer, 0, 0, payloadLength);
    
    ulong startTime = GetMicrosecondCount();
    
    int httpResult = WebRequest("POST", url, headers, timeout, sendBuffer, result, resultHeaders);
    
    ulong latency = GetMicrosecondCount() - startTime;
    
    if(httpResult == -1)
    {
        int errorCode = GetLastError();
        Print("ERROR: WebRequest failed for topic '", topic, "' - Error: ", errorCode);
        
        if(errorCode == 4060)  // URL not in allowed list
        {
            Print("CRITICAL: Add ", PublishHostUri, " to MT5 WebRequest allowed URLs");
            Print("Go to: Tools → Options → Expert Advisors → Allow WebRequest");
            if(ShowAlerts)
            {
                Alert("⚠️ JSON PUBLISHING DISABLED: Add ", PublishHostUri, " to allowed URLs");
            }
        }
        return false;
    }
    
    // Accept both 200 (OK) and 202 (Accepted)
    if(httpResult != 200 && httpResult != 202)
    {
        Print("ERROR: HTTP ", httpResult, " from ", url, " for topic '", topic, "'");
        
        // Print server response for debugging
        if(ArraySize(result) > 0)
        {
            string serverResponse = CharArrayToString(result);
            Print("Server response: ", serverResponse);
        }
        
        return false;
    }
    
    // Log latency if exceeds threshold
    if(latency > 2000)  // 2ms threshold
    {
        Print("WARNING: High publish latency: ", latency, "µs for topic '", topic, "'");
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| V20.4 - Exit Signal Publisher Helper Function                   |
//+------------------------------------------------------------------+

/**
 * @brief Publishes exit signals for position closures
 * @param direction "long" or "short" to indicate position direction
 * @param exitReason "Stop loss" or "Profit target"
 */
void PublishExitSignal(string direction, string exitReason)
{
    if(!PublishToKafka)
    {
        return;
    }
    
    // Use exitReason directly as the action
    string action = exitReason;  // "Stop loss" or "Profit target"
    string signalId = StringFormat("%lld-%d", GetTickCount64(), MathRand());
    
    // Build exit signal message based on format preference
    if(MessageFormat == MSG_NEW_ONLY || MessageFormat == MSG_BOTH)
    {
        // New format exit signal
        string symbol = GetInstrumentSymbol(_Symbol);
        string timestamp = TimeToISO8601(TimeCurrent());
        string timestampEST = TimeToESTReadable(TimeCurrent());
        string instrumentName = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : _Symbol;
        
        string message = StringFormat(
            "{\"Symbol\":\"%s\",\"Action\":\"%s\",\"Direction\":\"%s\","
            "\"Timestamp\":\"%s\",\"TimestampEST\":\"%s\",\"SignalId\":\"%s\","
            "\"Source\":\"Secret_Eye_V20_4\",\"InstrumentFullName\":\"%s\"}",
            symbol, action, direction, timestamp, timestampEST, signalId, instrumentName
        );
        
        string escapedMessage = EscapeJsonString(message);
        string payload = StringFormat("{\"topic\":\"%s\",\"message\":\"%s\"}",
                                      "placeholder", escapedMessage);
        
        if(StringLen(payload) < 4095)
        {
            ArrayInitialize(jsonSignalBuffer, 0);
            StringToCharArray(payload, jsonSignalBuffer, 0, StringLen(payload));
            jsonSignalBuffer[StringLen(payload)] = 0;
            
            if(PublishJSONToMultipleTopics(jsonSignalBuffer, action + "-new", ""))
            {
                Print("Published exit signal (new format): ", action, " - ", exitReason);
            }
        }
    }
    
    if(MessageFormat == MSG_LEGACY_ONLY || MessageFormat == MSG_BOTH)
    {
        // Legacy format exit signal
        string timestampEST = TimeToESTReadable(TimeCurrent());
        string instrumentName = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : _Symbol;
        
        string message = StringFormat(
            "{\"instrumentFullName\":\"%s\",\"action\":\"%s\",\"timestamp\":\"%s\"}",
            instrumentName, action, timestampEST
        );
        
        string escapedMessage = EscapeJsonString(message);
        string payload = StringFormat("{\"topic\":\"%s\",\"message\":\"%s\"}",
                                      "placeholder", escapedMessage);
        
        if(StringLen(payload) < 4095)
        {
            ArrayInitialize(jsonSignalBuffer, 0);
            StringToCharArray(payload, jsonSignalBuffer, 0, StringLen(payload));
            jsonSignalBuffer[StringLen(payload)] = 0;
            
            if(PublishJSONToMultipleTopics(jsonSignalBuffer, "exit-legacy", ""))
            {
                Print("Published exit signal (legacy format): ", action, " - ", exitReason);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("Initializing Stochastic Algo V20.4 for symbol: ", _Symbol);
    magic = digital_name_ * 1000000 + code_interaction_ * 1000 + StringToInteger(_Symbol);
    trade.SetExpertMagicNumber(magic);
    trade.SetMarginMode();

    // --- V20.3: Set Order Filling Policy ---
    if (UseFillOrKill)
    {
        Print("Attempting to set Fill-Or-Kill (FOK) order policy.");
        long filling_modes = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
        if ((filling_modes & SYMBOL_FILLING_FOK) != 0)
        {
            trade.SetTypeFilling(ORDER_FILLING_FOK);
            Print("Success: FOK policy is supported and has been set for ", _Symbol);
            if (ShowAlerts) Alert("✅ Order Policy: Fill-Or-Kill (FOK) has been enabled for ", _Symbol);
        }
        else
        {
            Print("⚠️ WARNING: Fill-Or-Kill (FOK) is NOT supported for this symbol/broker.");
            Print("Reverting to the default filling policy for this symbol.");
            trade.SetTypeFillingBySymbol(_Symbol); // Fallback to default
            if (ShowAlerts) Alert("⚠️ WARNING: FOK not supported for ", _Symbol, ". Using default order policy.");
        }
    }
    else
    {
        // Default behavior if FOK is not requested
        trade.SetTypeFillingBySymbol(_Symbol);
    }

    stochHandle = iStochastic(_Symbol, timeFrame, K_Period, D_Period, slowing, MODE_SMA, STO_LOWHIGH);
    if(stochHandle == INVALID_HANDLE)
    {
        Print("Error creating Stochastic indicator handle - ", GetLastError());
        return(INIT_FAILED);
    }
    
    // Call CheckDailyLossLimit to properly initialize all daily variables
    CheckDailyLossLimit();

    if(ManualServerOffset == 0)
    {
        detectedServerOffset = DetectBrokerServerOffset();
        Print("Auto-detected broker server offset: ", detectedServerOffset, " hours from UTC");
    }
    else
    {
        detectedServerOffset = ManualServerOffset;
        Print("Using manual server offset: ", detectedServerOffset, " hours from UTC");
    }

    if(UseAPITradingHours)
    {
        Print("=== API TRADING HOURS INITIALIZATION ===");
        Print("Host URI: ", HOST_URI);
        Print("API Symbol: ", API_Symbol);
        Print("Target Chart Symbol: ", _Symbol);
        if(FetchTradingHoursFromAPI())
        {
            SetTradingHoursForToday();
            Print("API trading hours successfully configured");
            if(ShowAlerts) Alert("✅ Trading Hours: Successfully fetched for ", API_Symbol, " → ", _Symbol);
        }
        else
        {
            Print("❌ API fetch failed - using manual trading hours as fallback");
            Print("⚠️ Warning: Trading hours may not be accurate for ", _Symbol);
            currentStartHour = ManualStartTime;
            currentStartMinute = ManualStartMinute;
            currentEndHour = ManualEndTime;
            currentEndMinute = ManualEndMinute;
            
            if(ShowAlerts) 
            {
                Alert("⚠️ WARNING: Failed to fetch trading hours for ", API_Symbol, " from ", HOST_URI);
                Alert("Using manual fallback hours: ", StringFormat("%02d:%02d", ManualStartTime, ManualStartMinute), 
                      " - ", StringFormat("%02d:%02d", ManualEndTime, ManualEndMinute));
            }
        }
    }
    else
    {
        Print("Using manual trading hours configuration");
        currentStartHour = ManualStartTime;
        currentStartMinute = ManualStartMinute;
        currentEndHour = ManualEndTime;
        currentEndMinute = ManualEndMinute;
    }

    Print("Current Trading Window: ", StringFormat("%02d:%02d", currentStartHour, currentStartMinute), 
          " to ", StringFormat("%02d:%02d", currentEndHour, currentEndMinute));

    RecoverExistingPositions();
    CheckKillSwitchPostTimeRecovery();

    if(ImmediateEntryOnLoad)
    {
        Print("=== IMMEDIATE ENTRY ON LOAD ACTIVATED ===");
        Print("Immediate Entry option is ON. Will attempt to place trade after DelayOnInitialOrder.");
        Print("Current DelayOnInitialOrder setting: ", DelayOnInitialOrder, " seconds");
        Print("Note: Trade will be placed when trading hours + delay conditions are met");
        immediateEntryPending = true;
        immediateEntryCompleted = false;
    }
    
    // V20.4 - JSON Publishing Configuration
    if(PublishToKafka)
    {
        Print("=== JSON PUBLISHING CONFIGURATION ===");
        Print("Publishing Enabled: ", PublishToKafka ? "YES" : "NO");
        
        // Parse and display topic configuration
        string topics[];
        int topicCount = ParseTopicNames(KafkaTopicName, topics);
        
        if(topicCount == 0)
        {
            Print("WARNING: KafkaTopicName is empty - publishing will be disabled");
            if(ShowAlerts)
            {
                Alert("⚠️ WARNING: Kafka topic name is empty. Configure KafkaTopicName input.");
            }
        }
        else if(topicCount == 1)
        {
            Print("Base Topic: ", topics[0]);
            Print("Message Format: ", MessageFormat == MSG_NEW_ONLY ? "New Only" :
                                      MessageFormat == MSG_LEGACY_ONLY ? "Legacy Only" : "Both");
            Print("Publish Host: ", PublishHostUri);
            Print("Topics:");
            Print("  - Signals (New): ", topics[0], "-new");
            Print("  - Signals (Legacy): ", topics[0]);
            Print("  - Executions: ", topics[0], "-executions");
        }
        else
        {
            Print("Multiple Topics Configured: ", topicCount, " topics");
            Print("Message Format: ", MessageFormat == MSG_NEW_ONLY ? "New Only" :
                                      MessageFormat == MSG_LEGACY_ONLY ? "Legacy Only" : "Both");
            Print("Publish Host: ", PublishHostUri);
            Print("Topics (Signals):");
            for(int i = 0; i < topicCount; i++)
            {
                if(MessageFormat != MSG_LEGACY_ONLY)
                {
                    Print("  ", (i+1), ". ", topics[i], "-new");
                }
                if(MessageFormat != MSG_NEW_ONLY)
                {
                    Print("  ", (i+1), ". ", topics[i]);
                }
            }
            Print("Topics (Executions):");
            for(int i = 0; i < topicCount; i++)
            {
                Print("  ", (i+1), ". ", topics[i], "-executions");
            }
        }
        
        // Initialize JSON buffers
        ArrayInitialize(jsonSignalBuffer, 0);
        ArrayInitialize(jsonExecBuffer, 0);
        ArrayInitialize(httpResponseBuffer, 0);
        
        Print("JSON buffers initialized: Signal=4KB, Exec=4KB, Response=2KB");
        Print("JSON publishing configured - ready for live trading signals");
    }
    else
    {
        Print("JSON Publishing is DISABLED (PublishToKafka=false)");
    }
    
    // ===============================
    // V20.5 - Aeron Publishing Setup
    // ===============================
    if(EnableAeronPublishing)
    {
        Print("=== AERON BINARY PUBLISHING CONFIGURATION ===");
        Print("Aeron Publishing Enabled: YES");
        Print("Aeron Directory: ", AeronPublishDir);
        Print("Publish Channel: ", AeronPublishChannel);
        Print("Stream ID: ", AeronPublishStreamId);
        Print("Source Tag: ", AeronSourceTag);
        Print("Binary Protocol: 104-byte frame (matches NinjaTrader AeronSignalPublisher)");
        
        int result = AeronBridge_StartPublisherW(
            AeronPublishDir,
            AeronPublishChannel,
            AeronPublishStreamId,
            3000);
        
        if(result == 0)
        {
            uchar errBuf[512];
            int errLen = AeronBridge_LastError(errBuf, ArraySize(errBuf));
            string errMsg = (errLen > 0) ? CharArrayToString(errBuf, 0, errLen) : "Unknown error";
            
            PrintFormat("ERROR: Failed to start Aeron publisher: %s", errMsg);
            PrintFormat("Possible causes:");
            PrintFormat("  - MediaDriver not running");
            PrintFormat("  - Incorrect Aeron directory path");
            PrintFormat("  - Invalid channel format");
            
            if(ShowAlerts)
            {
                Alert("⚠️ ERROR: Failed to start Aeron publisher: ", errMsg);
                Alert("Check that MediaDriver is running and Aeron directory is correct");
            }
        }
        else
        {
            Print("✅ Aeron publisher started successfully");
            Print("Ready to broadcast binary trading signals via Aeron");
            Print("Signal consumers can subscribe on channel: ", AeronPublishChannel);
            Print("Stream ID: ", AeronPublishStreamId);
            
            if(ShowAlerts)
            {
                Alert("✅ Aeron Publisher: Started successfully on ", AeronPublishChannel);
            }
        }
    }
    else
    {
        Print("Aeron Binary Publishing is DISABLED (EnableAeronPublishing=false)");
    }
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit: Called when the EA is removed                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(stochHandle);
    
    // V20.5 - Cleanup Aeron publisher
    if(EnableAeronPublishing)
    {
        AeronBridge_StopPublisher();
        Print("Aeron publisher stopped and cleaned up");
    }
    
    Print("Terminating Stochastic Algo V20.5. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick: Main execution loop                                      |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!on) return;
    
    // V20.5 - Check and update trading hours daily
    CheckAndUpdateDailyTradingHours();
    
    // V20.4 - Reset publish flags for new tick
    publishFlags = 0;
    
    // === KILL SWITCH LOGIC ===
    // Check if kill switch should be executed (close positions at end time)
    if(!killSwitchExecuted)
    {
        MqlDateTime time;
        TimeToStruct(TimeCurrent(), time);

        // Get the server-to-eastern offset for kill switch timing
        int serverToEasternOffset = GetServerToEasternOffset(TimeCurrent());

        // Convert server time to EST/EDT
        int estHour = time.hour + serverToEasternOffset;
        if(estHour < 0) estHour += 24;
        if(estHour >= 24) estHour -= 24;

        // Check if we're at the kill switch time
        if(estHour == currentEndHour && time.min == currentEndMinute)
        {
            // Check if we actually have positions to close
            if(scalpBuyOpened || trendBuyOpened || scalpSellOpened || trendSellOpened)
            {
                Print("=== KILL SWITCH ACTIVATED ===");
                Print("Closing EA positions at ", currentEndHour, ":", StringFormat("%02d", currentEndMinute), " EST/EDT");
                Print("Current EST Time: ", estHour, ":", StringFormat("%02d", time.min));

                // Close only this EA's positions, not all account positions
                CloseAllBuyPositions();
                CloseAllSellPositions();

                if(ShowAlerts) Alert("Kill Switch: EA positions closed for ", _Symbol, " at end time");

                Print("Kill switch executed successfully. Positions closed.");
            }
            else
            {
                Print("Kill switch time reached but no positions to close for ", _Symbol);
            }

            // Mark kill switch as executed to prevent repeated execution
            killSwitchExecuted = true;

            // Disable trading for the rest of the session
            stopTradingForDay = true;
            Print("Trading disabled for remainder of session due to kill switch activation");
            return;
        }
    }

    datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, timeFrame, SERIES_LASTBAR_DATE);
    if(currentBarTime == lastBarTime) return;
    lastBarTime = currentBarTime;

    UpdateAllPositionStatus();
    
    // === IMMEDIATE ENTRY LOGIC ===
    // Check if immediate entry is pending and conditions are met
    if(immediateEntryPending && !immediateEntryCompleted)
    {
        if(IsTradingAllowed() && IsInitialDelayOver() && !stopTradingForDay && !stopTradingForProfitProtection)
        {
            Print("=== EXECUTING PENDING IMMEDIATE ENTRY ===");
            Print("Conditions met: Trading allowed + Initial delay over");
            ExecuteImmediateTrade();
            immediateEntryPending = false;
            immediateEntryCompleted = true;
        }
        else
        {
            // Log why immediate entry is still waiting (but only occasionally to avoid spam)
            static datetime lastImmediateEntryLog = 0;
            if(TimeCurrent() - lastImmediateEntryLog > 30) // Log every 30 seconds
            {
                Print("=== IMMEDIATE ENTRY WAITING ===");
                Print("Trading allowed: ", IsTradingAllowed() ? "YES" : "NO");
                Print("Initial delay over: ", IsInitialDelayOver() ? "YES" : "NO");
                Print("Stop trading for day: ", stopTradingForDay ? "YES" : "NO");
                Print("Stop for profit protection: ", stopTradingForProfitProtection ? "YES" : "NO");
                lastImmediateEntryLog = TimeCurrent();
            }
        }
    }
    
    CheckDailyLossLimit();
    CheckDailyProfitProtection();
    if(stopTradingForDay || stopTradingForProfitProtection) return;

    double mainLine[3], signalLine[3];
    if(CopyBuffer(stochHandle, 0, 1, 3, mainLine) <= 0 || CopyBuffer(stochHandle, 1, 1, 3, signalLine) <= 0)
    {
        Print("Error copying indicator buffers - ", GetLastError());
        return;
    }
    
    double prev_main = mainLine[0]; // Bar #2
    double prev_sign = signalLine[0]; // Bar #2
    double curr_main = mainLine[1]; // Bar #1 (most recently closed)
    double curr_sign = signalLine[1]; // Bar #1 (most recently closed)

    bool buySignal = (prev_main < prev_sign && curr_main > curr_sign);
    bool sellSignal = (prev_main > prev_sign && curr_main < curr_sign);

    if(buySignal)
    {
        CloseAllSellPositions();
        Sleep(100);
        UpdateAllPositionStatus();
        if(IsTradingAllowed() && !stopTradingForProfitProtection && !scalpBuyOpened && !trendBuyOpened)
        {
            if(IsInitialDelayOver())
            {
                if(WaitForClosureConfirmation)
                {
                    if(AreAllReversePositionsClosed(true))
                    {
                        OpenBuyPositions();
                        firstTradeOfDayPlaced = true;
                    }
                    else
                    {
                        Print("BUY signal detected but waiting for SELL positions to be fully closed. Skipping entry.");
                    }
                }
                else
                {
                    OpenBuyPositions();
                    firstTradeOfDayPlaced = true;
                }
            }
        }
    }

    if(sellSignal)
    {
        CloseAllBuyPositions();
        Sleep(100);
        UpdateAllPositionStatus();
        
        if(IsTradingAllowed() && !stopTradingForProfitProtection && !scalpSellOpened && !trendSellOpened) 
        {
            if(IsInitialDelayOver())
            {
                if(WaitForClosureConfirmation)
                {
                    if(AreAllReversePositionsClosed(false))
                    {
                        OpenSellPositions();
                        firstTradeOfDayPlaced = true;
                    }
                    else
                    {
                        Print("SELL signal detected but waiting for BUY positions to be fully closed. Skipping entry.");
                    }
                }
                else
                {
                    OpenSellPositions();
                    firstTradeOfDayPlaced = true;
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| V20.4 - OnTradeTransaction: Publishes execution details         |
//+------------------------------------------------------------------+

/**
 * @brief OnTradeTransaction: Publishes execution details when orders fill
 */
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    // Only process actual fills
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
    {
        return;
    }
    
    // Only process this EA's magic number
    ulong dealTicket = trans.deal;
    if(!HistoryDealSelect(dealTicket))
    {
        return;
    }
    
    ulong dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
    if(dealMagic != magic)
    {
        return;
    }
    
    // CRITICAL FIX: Verify this deal belongs to OUR symbol
    // Prevents cross-contamination when multiple EAs share the same magic number
    string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
    if(dealSymbol != _Symbol)
    {
        // This deal is for a different symbol - ignore it
        return;
    }
    
    // Prevent duplicate publishing
    if(dealTicket == lastPublishedTicket)
    {
        return;
    }
    lastPublishedTicket = dealTicket;
    
    // Extract deal details
    ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
    ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    ENUM_DEAL_REASON dealReason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
    double dealPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
    double dealVolume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
    double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
    string dealComment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
    
    // Debug logging for deal events
    string dealEntryStr = (dealEntry == DEAL_ENTRY_IN) ? "ENTRY_IN" : 
                          (dealEntry == DEAL_ENTRY_OUT) ? "ENTRY_OUT" : 
                          (dealEntry == DEAL_ENTRY_INOUT) ? "ENTRY_INOUT" : "UNKNOWN";
    string dealTypeStr = (dealType == DEAL_TYPE_BUY) ? "BUY" : 
                         (dealType == DEAL_TYPE_SELL) ? "SELL" : "OTHER";
    string dealReasonStr;
    if(dealReason == DEAL_REASON_SL)
        dealReasonStr = "SL";
    else if(dealReason == DEAL_REASON_TP)
        dealReasonStr = "TP";
    else
        dealReasonStr = IntegerToString((int)dealReason);
    
    Print(StringFormat("Deal Event: Ticket=%lld, Type=%s, Entry=%s, Reason=%s, Volume=%.2f, Profit=%.2f, Comment=%s",
                       dealTicket, dealTypeStr, dealEntryStr, dealReasonStr, dealVolume, dealProfit, dealComment));
    
    // Determine action and order name
    string action = "";
    string orderAction = "";
    string orderName = "";
    string exitReason = "";
    bool isExit = (dealEntry == DEAL_ENTRY_OUT);
    
    if(dealType == DEAL_TYPE_BUY)
    {
        if(isExit)
        {
            // Closing a short position (buy to cover)
            // Only publish exit signal if this is triggered by SL/TP
            if(dealVolume <= 0)
            {
                Print("Skipping exit signal - zero volume (likely order modification)");
                return;  // Don't publish for order modifications
            }

            if(dealReason == DEAL_REASON_SL || dealReason == DEAL_REASON_TP)
            {
                action = "shortexit_fill";
                orderAction = "Buy";
                exitReason = (dealReason == DEAL_REASON_TP) ? "Profit target" : "Stop loss";
                orderName = exitReason;

                // Publish exit signal strictly on SL/TP closures
                PublishExitSignal("short", exitReason);
                
                // V20.5 - Aeron exit signal publishing
                if(EnableAeronPublishing)
                {
                    // Use AeronInstrumentName for both symbol and instrument, or fallback to _Symbol
                    string aeronName = (StringLen(AeronInstrumentName) > 0) ? AeronInstrumentName : ExtractSymbolPrefix(_Symbol);
                    string symbol = aeronName;
                    string instrument = aeronName;
                    
                    if(dealReason == DEAL_REASON_TP)
                    {
                        AeronPublishSignal(symbol, instrument, AERON_PROFIT_TARGET,
                                          0, 0, 0, 1, 50.0, AeronSourceTag);
                        Print("[AERON_PUB] ✅ ProfitTarget (short): ", symbol);
                    }
                    else
                    {
                        AeronPublishSignal(symbol, instrument, AERON_SHORT_STOPLOSS,
                                          0, 0, 0, 1, 50.0, AeronSourceTag);
                        Print("[AERON_PUB] ✅ ShortStopLoss: ", symbol);
                    }
                }
            }
            else
            {
                // Suppress publishing for manual/reversal/other exit reasons
                Print("Exit detected but not SL/TP (reason=", dealReasonStr, ") - suppressing exit signal publish");
            }
        }
        else
        {
            // Opening a long position
            action = "longentry_fill";
            orderAction = "Buy";
            
            if(StringFind(dealComment, "Scalp") >= 0)
                orderName = "longEntry1";
            else if(StringFind(dealComment, "Trend") >= 0)
                orderName = "longEntry2";
            else
                orderName = "longEntry";
        }
    }
    else if(dealType == DEAL_TYPE_SELL)
    {
        if(isExit)
        {
            // Closing a long position (sell to close)
            // Only publish exit signal if this is triggered by SL/TP
            if(dealVolume <= 0)
            {
                Print("Skipping exit signal - zero volume (likely order modification)");
                return;  // Don't publish for order modifications
            }

            if(dealReason == DEAL_REASON_SL || dealReason == DEAL_REASON_TP)
            {
                action = "longexit_fill";
                orderAction = "Sell";
                exitReason = (dealReason == DEAL_REASON_TP) ? "Profit target" : "Stop loss";
                orderName = exitReason;

                // Publish exit signal strictly on SL/TP closures
                PublishExitSignal("long", exitReason);
                
                // V20.5 - Aeron exit signal publishing
                if(EnableAeronPublishing)
                {
                    // Use AeronInstrumentName for both symbol and instrument, or fallback to _Symbol
                    string aeronName = (StringLen(AeronInstrumentName) > 0) ? AeronInstrumentName : ExtractSymbolPrefix(_Symbol);
                    string symbol = aeronName;
                    string instrument = aeronName;
                    
                    if(dealReason == DEAL_REASON_TP)
                    {
                        AeronPublishSignal(symbol, instrument, AERON_PROFIT_TARGET,
                                          0, 0, 0, 1, 50.0, AeronSourceTag);
                        Print("[AERON_PUB] ✅ ProfitTarget (long): ", symbol);
                    }
                    else
                    {
                        AeronPublishSignal(symbol, instrument, AERON_LONG_STOPLOSS,
                                          0, 0, 0, 1, 50.0, AeronSourceTag);
                        Print("[AERON_PUB] ✅ LongStopLoss: ", symbol);
                    }
                }
            }
            else
            {
                // Suppress publishing for manual/reversal/other exit reasons
                Print("Exit detected but not SL/TP (reason=", dealReasonStr, ") - suppressing exit signal publish");
            }
        }
        else
        {
            // Opening a short position
            action = "shortentry_fill";
            orderAction = "Sell";
            
            if(StringFind(dealComment, "Scalp") >= 0)
                orderName = "shortEntry1";
            else if(StringFind(dealComment, "Trend") >= 0)
                orderName = "shortEntry2";
            else
                orderName = "shortEntry";
        }
    }
    
    // Get current position state
    string marketPosition = "Flat";
    double unrealizedPnL = 0;
    double realizedPnL = dealProfit;
    
    if(PositionSelect(_Symbol))
    {
        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        marketPosition = (posType == POSITION_TYPE_BUY) ? "Long" : "Short";
        unrealizedPnL = PositionGetDouble(POSITION_PROFIT);
    }
    
    // Build and publish execution message
    if(PublishToKafka && BuildExecutionFormat(action, "ACTUAL_FILL", orderAction, orderName,
                                              dealPrice, dealVolume, marketPosition,
                                              unrealizedPnL, realizedPnL))
    {
        PublishJSONToMultipleTopics(jsonExecBuffer, "execution", "-executions");
    }
}

//+------------------------------------------------------------------+
//| V20.2 - Checks if the initial trade delay has passed            |
//+------------------------------------------------------------------+
bool IsInitialDelayOver()
{
    if(DelayOnInitialOrder <= 0 || firstTradeOfDayPlaced)
    {
        return true;
    }

    MqlDateTime time;
    TimeCurrent(time);
    
    int serverToEasternOffset = GetServerToEasternOffset(TimeCurrent());
    int estHour = time.hour + serverToEasternOffset;
    if(estHour < 0) estHour += 24;
    if(estHour >= 24) estHour -= 24;
    long currentTimeInSeconds = estHour * 3600 + time.min * 60 + time.sec;

    long startTimeInSeconds = currentStartHour * 3600 + currentStartMinute * 60;

    if(currentTimeInSeconds >= (startTimeInSeconds + DelayOnInitialOrder))
    {
        return true;
    }
    else
    {
        static datetime lastDelayPrint = 0;
        if(TimeCurrent() - lastDelayPrint > 10)
        {
            Print("Initial order delay active. Waiting for ", DelayOnInitialOrder, " seconds after session open. Skipping signal.");
            lastDelayPrint = TimeCurrent();
        }
        return false;
    }
}

//+------------------------------------------------------------------+
//| V20 - REST API Trading Hours Functions                          |
//+------------------------------------------------------------------+

/**
 * @brief Fetches trading hours from REST API
 */
bool FetchTradingHoursFromAPI()
{
    string url = "http://" + HOST_URI + "/api/trading-hours?symbol=" + API_Symbol;
    string headers = "Content-Type: application/json\r\n";
    char data[];
    char result[];
    string resultHeaders;
    int timeout = 5000; // 5 seconds
    
    Print("Fetching trading hours from API: ", url);
    
    int httpResult = WebRequest("GET", url, headers, timeout, data, result, resultHeaders);
    
    if(httpResult == -1)
    {
        int errorCode = GetLastError();
        Print("❌ WebRequest error: ", errorCode);
        Print("Common causes:");
        Print("1. URL not in allowed list: Tools → Options → Expert Advisors → Allow WebRequest");
        Print("2. Network connectivity issues");
        Print("3. Invalid HOST_URI: ", HOST_URI);
        Print("Make sure the URL is added to allowed URLs in MetaTrader options");
        Print("Go to Tools → Options → Expert Advisors → Allow WebRequest for: ", HOST_URI);
        
        if(ShowAlerts)
        {
            Alert("❌ API ERROR: WebRequest failed (Error ", errorCode, ")");
            Alert("Add ", HOST_URI, " to MT5 allowed URLs: Tools→Options→Expert Advisors");
        }
        return false;
    }
    
    if(httpResult != 200)
    {
        Print("❌ HTTP Error: ", httpResult);
        Print("API endpoint may be unavailable or returned an error");
        Print("URL: ", url);
        Print("Expected: HTTP 200, Received: HTTP ", httpResult);
        
        if(ShowAlerts)
        {
            Alert("❌ API ERROR: HTTP ", httpResult, " from ", HOST_URI);
            Alert("Check if API server is running and endpoint exists");
        }
        return false;
    }
    
    string jsonResponse = CharArrayToString(result);
    Print("API Response received: ", StringLen(jsonResponse), " characters");
    
    return ParseTradingHoursJSON(jsonResponse);
}

/**
 * @brief Parse JSON response (simplified MQL5 implementation)
 */
bool ParseTradingHoursJSON(string jsonResponse)
{
    Print("Parsing trading hours JSON response...");
    
    cachedTradingHours.symbol = "";
    cachedTradingHours.timezone = "";
    
    int symbolPos = StringFind(jsonResponse, "\"symbol\":");
    if(symbolPos != -1)
    {
        int startQuote = StringFind(jsonResponse, "\"", symbolPos + 9);
        int endQuote = StringFind(jsonResponse, "\"", startQuote + 1);
        if(startQuote != -1 && endQuote != -1)
        {
            cachedTradingHours.symbol = StringSubstr(jsonResponse, startQuote + 1, endQuote - startQuote - 1);
        }
    }
    
    int timezonePos = StringFind(jsonResponse, "\"timezone\":");
    if(timezonePos != -1)
    {
        int startQuote = StringFind(jsonResponse, "\"", timezonePos + 11);
        int endQuote = StringFind(jsonResponse, "\"", startQuote + 1);
        if(startQuote != -1 && endQuote != -1)
        {
            cachedTradingHours.timezone = StringSubstr(jsonResponse, startQuote + 1, endQuote - startQuote - 1);
        }
    }
    
    string days[] = {"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"};
    
    for(int i = 0; i < 7; i++)
    {
        string dayPattern = "\"" + days[i] + "\":{\"start\":\"";
        int dayPos = StringFind(jsonResponse, dayPattern);
        
        if(dayPos != -1)
        {
            int startPos = dayPos + StringLen(dayPattern);
            int startEndPos = StringFind(jsonResponse, "\"", startPos);
            string startTime = StringSubstr(jsonResponse, startPos, startEndPos - startPos);
            
            string endPattern = "\"end\":\"";
            int endPatternPos = StringFind(jsonResponse, endPattern, startEndPos);
            if(endPatternPos != -1)
            {
                int endPos = endPatternPos + StringLen(endPattern);
                int endEndPos = StringFind(jsonResponse, "\"", endPos);
                string endTime = StringSubstr(jsonResponse, endPos, endEndPos - endPos);
                
                switch(i)
                {
                    case 0: cachedTradingHours.monday.start = startTime; cachedTradingHours.monday.end = endTime; break;
                    case 1: cachedTradingHours.tuesday.start = startTime; cachedTradingHours.tuesday.end = endTime; break;
                    case 2: cachedTradingHours.wednesday.start = startTime; cachedTradingHours.wednesday.end = endTime; break;
                    case 3: cachedTradingHours.thursday.start = startTime; cachedTradingHours.thursday.end = endTime; break;
                    case 4: cachedTradingHours.friday.start = startTime; cachedTradingHours.friday.end = endTime; break;
                    case 5: cachedTradingHours.saturday.start = startTime; cachedTradingHours.saturday.end = endTime; break;
                    case 6: cachedTradingHours.sunday.start = startTime; cachedTradingHours.sunday.end = endTime; break;
                }
            }
        }
    }
    
    apiDataValid = (cachedTradingHours.symbol != "");
    
    if(apiDataValid)
    {
        Print("Successfully parsed trading hours for symbol: ", cachedTradingHours.symbol);
        Print("Timezone: ", cachedTradingHours.timezone);
        Print("Monday: ", cachedTradingHours.monday.start, " - ", cachedTradingHours.monday.end);
        Print("Tuesday: ", cachedTradingHours.tuesday.start, " - ", cachedTradingHours.tuesday.end);
        Print("Wednesday: ", cachedTradingHours.wednesday.start, " - ", cachedTradingHours.wednesday.end);
        Print("Thursday: ", cachedTradingHours.thursday.start, " - ", cachedTradingHours.thursday.end);
        Print("Friday: ", cachedTradingHours.friday.start, " - ", cachedTradingHours.friday.end);
        Print("Saturday: ", cachedTradingHours.saturday.start, " - ", cachedTradingHours.saturday.end);
        Print("Sunday: ", cachedTradingHours.sunday.start, " - ", cachedTradingHours.sunday.end);
    }
    else
    {
        Print("❌ Failed to parse trading hours from API response");
        Print("Response length: ", StringLen(jsonResponse), " characters");
        Print("This may indicate:");
        Print("1. Invalid JSON format from API");
        Print("2. Missing required fields (symbol, weekly_schedule)");
        Print("3. API symbol '", API_Symbol, "' not found in database");
        
        if(ShowAlerts)
        {
            Alert("❌ PARSE ERROR: Invalid trading hours data from API");
            Alert("Symbol '", API_Symbol, "' may not exist in API database");
        }
    }
    
    return apiDataValid;
}

/**
 * @brief Set trading hours for current day based on API data
 */
void SetTradingHoursForToday()
{
    if(!apiDataValid)
    {
        Print("⚠️ No valid API data available - using manual hours");
        Print("Manual trading hours: ", StringFormat("%02d:%02d", ManualStartTime, ManualStartMinute), 
              " - ", StringFormat("%02d:%02d", ManualEndTime, ManualEndMinute));
        currentStartHour = ManualStartTime;
        currentStartMinute = ManualStartMinute;
        currentEndHour = ManualEndTime;
        currentEndMinute = ManualEndMinute;
        
        if(ShowAlerts)
        {
            Alert("⚠️ WARNING: Using manual trading hours (API data invalid)");
            Alert("Hours: ", StringFormat("%02d:%02d", ManualStartTime, ManualStartMinute), 
                  " - ", StringFormat("%02d:%02d", ManualEndTime, ManualEndMinute));
        }
        return;
    }
    
    MqlDateTime dt;
    TimeCurrent(dt);
    
    TradingWindow todayWindow;
    string dayName = GetDayOfWeekString(dt.day_of_week);
    
    switch(dt.day_of_week)
    {
        case 1: todayWindow = cachedTradingHours.monday; break;
        case 2: todayWindow = cachedTradingHours.tuesday; break;
        case 3: todayWindow = cachedTradingHours.wednesday; break;
        case 4: todayWindow = cachedTradingHours.thursday; break;
        case 5: todayWindow = cachedTradingHours.friday; break;
        case 6: todayWindow = cachedTradingHours.saturday; break;
        case 0: todayWindow = cachedTradingHours.sunday; break;
        default: 
            Print("Invalid day of week: ", dt.day_of_week);
            todayWindow.start = "";
            todayWindow.end = "";
            break;
    }
    
    if(todayWindow.start == "" || todayWindow.end == "")
    {
        Print("⚠️ No trading hours found for ", dayName, " - using impossible range (no trading today)");
        Print("This indicates either:");
        Print("1. ", dayName, " is not a trading day for ", API_Symbol);
        Print("2. API returned empty/null trading hours for this day");
        Print("3. Market is closed on ", dayName);
        currentStartHour = 25;
        currentStartMinute = 0;
        currentEndHour = 25;
        currentEndMinute = 0;
        
        if(ShowAlerts)
        {
            Alert("📅 INFO: No trading scheduled for ", dayName);
            Alert("Symbol: ", API_Symbol, " | Chart: ", _Symbol);
        }
        return;
    }
    
    int startHour, startMinute, endHour, endMinute;
    
    if(ParseTimeString(todayWindow.start, startHour, startMinute) && 
       ParseTimeString(todayWindow.end, endHour, endMinute))
    {
        currentStartHour = startHour;
        currentStartMinute = startMinute;
        currentEndHour = endHour;
        currentEndMinute = endMinute;
        
        Print("Trading hours set for ", dayName, ": ", 
              StringFormat("%02d:%02d", currentStartHour, currentStartMinute), " - ",
              StringFormat("%02d:%02d", currentEndHour, currentEndMinute));
    }
    else
    {
        Print("❌ Failed to parse time strings for ", dayName, " - using manual hours");
        Print("API returned invalid time format:");
        Print("Start: '", todayWindow.start, "' | End: '", todayWindow.end, "'");
        Print("Expected format: HH:MM (e.g., '09:30')");
        currentStartHour = ManualStartTime;
        currentStartMinute = ManualStartMinute;
        currentEndHour = ManualEndTime;
        currentEndMinute = ManualEndMinute;
        
        if(ShowAlerts)
        {
            Alert("❌ TIME FORMAT ERROR: Invalid time format from API");
            Alert("Using manual fallback for ", dayName, ": ", 
                  StringFormat("%02d:%02d", ManualStartTime, ManualStartMinute), " - ",
                  StringFormat("%02d:%02d", ManualEndTime, ManualEndMinute));
        }
    }
}

/**
 * @brief Check if day changed and update trading hours accordingly
 * @details This function detects when a new trading day starts and refreshes
 *          the currentStartHour/currentEndHour from the cached API data.
 *          Fixes issue where algorithm was using Monday's hours all week.
 */
void CheckAndUpdateDailyTradingHours()
{
    if(!UseAPITradingHours || !apiDataValid)
    {
        return; // Skip if not using API hours or data is invalid
    }
    
    MqlDateTime dt;
    TimeCurrent(dt);
    
    // Check if the day has changed
    if(lastDayChecked != dt.day_of_week)
    {
        Print("=== DAY CHANGE DETECTED ===");
        Print("Previous day: ", lastDayChecked == -1 ? "INITIALIZATION" : GetDayOfWeekString(lastDayChecked));
        Print("Current day: ", GetDayOfWeekString(dt.day_of_week));
        
        // Update trading hours for the new day
        SetTradingHoursForToday();
        
        // Update the last checked day
        lastDayChecked = dt.day_of_week;
        
        // Reset kill switch for the new day
        killSwitchExecuted = false;
        
        Print("Trading hours updated for new day: ", 
              StringFormat("%02d:%02d", currentStartHour, currentStartMinute), " - ",
              StringFormat("%02d:%02d", currentEndHour, currentEndMinute));
        
        if(ShowAlerts)
        {
            Alert("📅 Day Changed: Trading hours updated for ", GetDayOfWeekString(dt.day_of_week));
            Alert("New hours: ", 
                  StringFormat("%02d:%02d", currentStartHour, currentStartMinute), " - ",
                  StringFormat("%02d:%02d", currentEndHour, currentEndMinute), " EST/EDT");
        }
    }
}

/**
 * @brief Get day of week as string
 */
string GetDayOfWeekString(int dayOfWeek)
{
    switch(dayOfWeek)
    {
        case 1: return "Monday";
        case 2: return "Tuesday";
        case 3: return "Wednesday";
        case 4: return "Thursday";
        case 5: return "Friday";
        case 6: return "Saturday";
        case 0: return "Sunday";
        default: return "Unknown";
    }
}

/**
 * @brief Parse time string in H:MM or HH:MM format
 */
bool ParseTimeString(string timeStr, int &hour, int &minute)
{
    Print("DEBUG: Parsing time string: '", timeStr, "' (length: ", StringLen(timeStr), ")");
    
    int colonPos = StringFind(timeStr, ":");
    if(colonPos == -1)
    {
        Print("❌ Invalid time format - no colon found: ", timeStr);
        return false;
    }
    
    int timeLength = StringLen(timeStr);
    if(timeLength != 4 && timeLength != 5)
    {
        Print("❌ Invalid time format - wrong length (", timeLength, "): ", timeStr);
        Print("Expected: H:MM (4 chars) or HH:MM (5 chars)");
        return false;
    }
    
    string hourStr = StringSubstr(timeStr, 0, colonPos);
    string minuteStr = StringSubstr(timeStr, colonPos + 1);
    
    Print("DEBUG: Extracted hour string: '", hourStr, "', minute string: '", minuteStr, "'");
    
    if(StringLen(minuteStr) != 2)
    {
        Print("❌ Invalid minute format - should be 2 digits: '", minuteStr, "'");
        return false;
    }
    
    hour = (int)StringToInteger(hourStr);
    minute = (int)StringToInteger(minuteStr);
    
    Print("DEBUG: Parsed values - hour: ", hour, ", minute: ", minute);
    
    if(hour < 0 || hour > 23 || minute < 0 || minute > 59)
    {
        Print("❌ Time values out of range: ", timeStr, " (hour: ", hour, ", minute: ", minute, ")");
        return false;
    }
    
    Print("✅ Successfully parsed time: ", timeStr, " → ", StringFormat("%02d:%02d", hour, minute));
    return true;
}

/**
 * @brief Checks if the current time is within the allowed trading hours (API-enhanced)
 */
bool IsTradingAllowed()
{
    MqlDateTime time;
    TimeCurrent(time);
    
    int serverToEasternOffset = GetServerToEasternOffset(TimeCurrent());
    
    int estHour = time.hour + serverToEasternOffset;
    if(estHour < 0) estHour += 24;
    if(estHour >= 24) estHour -= 24;
    
    int estMinutes = estHour * 60 + time.min;
    int startMinutes = currentStartHour * 60 + currentStartMinute;
    int endMinutes = currentEndHour * 60 + currentEndMinute;

    static datetime lastPrintTime = 0;
    datetime currentTime = TimeCurrent();
    if(currentTime - lastPrintTime >= 3600)
    {
        string dstStatus = AutoDST ? (IsEasternDST(currentTime) ? "EDT" : "EST") : "Manual";
        string dataSource = UseAPITradingHours && apiDataValid ? "API" : "Manual";
        Print("=== TRADING HOURS STATUS ===");
        Print("Data Source: ", dataSource, " | Symbol: ", UseAPITradingHours ? API_Symbol : "N/A");
        Print("Server Time: ", time.hour, ":", StringFormat("%02d", time.min));
        Print("Current Eastern Time (", dstStatus, "): ", estHour, ":", StringFormat("%02d", time.min), " (", estMinutes, " minutes)");
        Print("Trading Start Time: ", currentStartHour, ":", StringFormat("%02d", currentStartMinute), " (", startMinutes, " minutes)");
        Print("Trading End Time: ", currentEndHour, ":", StringFormat("%02d", currentEndMinute), " (", endMinutes, " minutes)");
        Print("Server-to-Eastern Offset: ", serverToEasternOffset, " hours");
        lastPrintTime = currentTime;
    }

    if(currentStartHour >= 24 || currentEndHour >= 24)
    {
        static bool noTradingPrinted = false;
        if(!noTradingPrinted)
        {
            Print("No trading scheduled for today (impossible hours configured)");
            noTradingPrinted = true;
        }
        return false;
    }

    if(startMinutes < endMinutes)
    {
        bool withinHours = (estMinutes >= startMinutes && estMinutes < endMinutes);
        static bool lastStatus = false;
        if(withinHours != lastStatus)
        {
            Print("Trading hours status changed: ", withinHours ? "ALLOWED" : "NOT ALLOWED");
            lastStatus = withinHours;
        }
        return withinHours;
    }
    else if(startMinutes > endMinutes)
    {
        bool withinHours = (estMinutes >= startMinutes || estMinutes < endMinutes);
        static bool lastOvernightStatus = false;
        if(withinHours != lastOvernightStatus)
        {
            Print("Overnight trading hours status changed: ", withinHours ? "ALLOWED" : "NOT ALLOWED");
            lastOvernightStatus = withinHours;
        }
        return withinHours;
    }
    else
    {
        static bool invalidConfigPrinted = false;
        if(!invalidConfigPrinted)
        {
            Print("Invalid trading hours configuration: Start time equals end time");
            invalidConfigPrinted = true;
        }
        return false;
    }
}

//+------------------------------------------------------------------+
//| V20.4 - Enhanced Position Opening with Signal Publishing        |
//+------------------------------------------------------------------+

/**
 * @brief Opens the dual buy positions (scalp and trend) with JSON signal publishing
 */
void OpenBuyPositions()
{
    Print("BUY Signal Detected. Opening dual positions.");
    
    // V20.4 - Generate signal ID and publish signals
    string signalId = StringFormat("%lld-%d", GetTickCount64(), MathRand());
    
    if(PublishToKafka && !(publishFlags & PUBLISH_FLAG_SIGNAL))
    {
        // Entry 1: Stop loss only (TP = 0)
        if(MessageFormat == MSG_NEW_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildNewFormatSignal("longentry1", SL, 0, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, "longentry1-new", "");
            }
        }
        
        if(MessageFormat == MSG_LEGACY_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildLegacyFormatSignal("longentry1", signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, "longentry1-legacy", "");
            }
        }
        
        // Entry 2: Stop loss + profit target
        int profitOffset = (int)(TP * 0.4);
        if(MessageFormat == MSG_NEW_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildNewFormatSignal("longentry2", SL, SL + profitOffset, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, "longentry2-new", "");
            }
        }
        
        if(MessageFormat == MSG_LEGACY_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildLegacyFormatSignal("longentry2", signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, "longentry2-legacy", "");
            }
        }
        
        publishFlags |= PUBLISH_FLAG_SIGNAL;
        lastPublishedSignalId = signalId;
    }
    
    MqlTick latest_tick;
    SymbolInfoTick(_Symbol, latest_tick);
    double ask = latest_tick.ask;
    double point = _Point;
    
    double buyStopLoss = ask - SL * point;
    double scalpTakeProfit = ask + TP * point;
    double scalpLot = NormalizeDouble(lot * scalpLotMultiplier, 2);
    double trendLot = NormalizeDouble(lot * trendLotMultiplier, 2);

    if(scalpLot > 0 && trade.Buy(scalpLot, _Symbol, ask, buyStopLoss, scalpTakeProfit, "Scalp Buy"))
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(PositionSelectByTicket(PositionGetTicket(i)))
            {
                if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                   PositionGetInteger(POSITION_MAGIC) == magic &&
                   PositionGetString(POSITION_COMMENT) == "Scalp Buy")
                {
                    scalpBuyTicket = PositionGetTicket(i);
                    scalpBuyOpened = true;
                    Print("Scalp Buy Opened: #", scalpBuyTicket);
                    if(ShowAlerts) Alert("Scalp BUY Order Success for ", _Symbol, " - Ticket: #", scalpBuyTicket);
                    break;
                }
            }
        }
    }
    else if(scalpLot > 0)
    {
        if(ShowAlerts) Alert("Scalp BUY Order Failed for ", _Symbol, " - Error: ", GetLastError());
        Print("=== SCALP BUY ORDER FAILURE ===");
        Print("Error Code: ", GetLastError());
        Print("RetCode: ", trade.ResultRetcode());
    }
    
    if(trendLot > 0 && trade.Buy(trendLot, _Symbol, ask, buyStopLoss, 0, "Trend Buy"))
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(PositionSelectByTicket(PositionGetTicket(i)))
            {
                if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                   PositionGetInteger(POSITION_MAGIC) == magic &&
                   PositionGetString(POSITION_COMMENT) == "Trend Buy")
                {
                    trendBuyTicket = PositionGetTicket(i);
                    trendBuyOpened = true;
                    Print("Trend Buy Opened: #", trendBuyTicket);
                    if(ShowAlerts) Alert("Trend BUY Order Success for ", _Symbol, " - Ticket: #", trendBuyTicket);
                    break;
                }
            }
        }
    }
    else if(trendLot > 0)
    {
        if(ShowAlerts) Alert("Trend BUY Order Failed for ", _Symbol, " - Error: ", GetLastError());
        Print("=== TREND BUY ORDER FAILURE ===");
        Print("Error Code: ", GetLastError());
        Print("RetCode: ", trade.ResultRetcode());
    }

    // ===============================================
    // V20.6 - Aeron Binary Signal Publishing (AFTER successful trades)
    // ===============================================
    if(EnableAeronPublishing && (scalpBuyOpened || trendBuyOpened))
    {
        // Use AeronInstrumentName for both symbol and instrument, or fallback to _Symbol
        string aeronName = (StringLen(AeronInstrumentName) > 0) ? AeronInstrumentName : ExtractSymbolPrefix(_Symbol);
        string symbol = aeronName;
        string instrument = aeronName;

        // Calculate confidence based on stochastic values
        double mainBuffer[], signalBuffer[];
        ArraySetAsSeries(mainBuffer, true);
        ArraySetAsSeries(signalBuffer, true);

        float confidence = 80.0;
        if(CopyBuffer(stochHandle, 0, 0, 3, mainBuffer) > 0 &&
           CopyBuffer(stochHandle, 1, 0, 3, signalBuffer) > 0)
        {
            double K = mainBuffer[0];
            double D = signalBuffer[0];
            confidence = (float)MathMin(50.0 + MathAbs(K - D), 95.0);
        }

        // Publish LongEntry1 (stop loss only)
        bool pub1 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_LONG_ENTRY1,
            SL,
            0,
            0,
            1,
            confidence,
            AeronSourceTag
        );

        if(pub1)
        {
            PrintFormat("[AERON_PUB] ✅ LongEntry1: %s SL=%d qty=1 conf=%.1f", symbol, SL, confidence);
        }

        // Publish LongEntry2 (stop loss + profit target)
        int profitOffset = (int)(TP * 0.4);
        bool pub2 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_LONG_ENTRY2,
            SL,
            0,
            SL + profitOffset,
            1,
            confidence,
            AeronSourceTag
        );

        if(pub2)
        {
            PrintFormat("[AERON_PUB] ✅ LongEntry2: %s SL=%d TP=%d qty=1 conf=%.1f",
                        symbol, SL, SL + profitOffset, confidence);
        }
    }
}

/**
 * @brief Opens the dual sell positions (scalp and trend) with JSON signal publishing
 */
void OpenSellPositions()
{
    Print("SELL Signal Detected. Opening dual positions.");
    
    // V20.4 - Generate signal ID and publish signals
    string signalId = StringFormat("%lld-%d", GetTickCount64(), MathRand());
    
    if(PublishToKafka && !(publishFlags & PUBLISH_FLAG_SIGNAL))
    {
        // Entry 1: Stop loss only (TP = 0)
        if(MessageFormat == MSG_NEW_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildNewFormatSignal("shortentry1", SL, 0, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, "shortentry1-new", "");
            }
        }
        
        if(MessageFormat == MSG_LEGACY_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildLegacyFormatSignal("shortentry1", signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, "shortentry1-legacy", "");
            }
        }
        
        // Entry 2: Stop loss + profit target
        int profitOffset = (int)(TP * 0.4);
        if(MessageFormat == MSG_NEW_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildNewFormatSignal("shortentry2", SL, SL + profitOffset, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, "shortentry2-new", "");
            }
        }
        
        if(MessageFormat == MSG_LEGACY_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildLegacyFormatSignal("shortentry2", signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, "shortentry2-legacy", "");
            }
        }
        
        publishFlags |= PUBLISH_FLAG_SIGNAL;
        lastPublishedSignalId = signalId;
    }
    
    MqlTick latest_tick;
    SymbolInfoTick(_Symbol, latest_tick);
    double bid = latest_tick.bid;
    double point = _Point;
    
    double sellStopLoss = bid + SL * point;
    double scalpTakeProfit = bid - TP * point;
    double scalpLot = NormalizeDouble(lot * scalpLotMultiplier, 2);
    double trendLot = NormalizeDouble(lot * trendLotMultiplier, 2);

    if(scalpLot > 0 && trade.Sell(scalpLot, _Symbol, bid, sellStopLoss, scalpTakeProfit, "Scalp Sell"))
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(PositionSelectByTicket(PositionGetTicket(i)))
            {
                if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                   PositionGetInteger(POSITION_MAGIC) == magic &&
                   PositionGetString(POSITION_COMMENT) == "Scalp Sell")
                {
                    scalpSellTicket = PositionGetTicket(i);
                    scalpSellOpened = true;
                    Print("Scalp Sell Opened: #", scalpSellTicket);
                    if(ShowAlerts) Alert("Scalp SELL Order Success for ", _Symbol, " - Ticket: #", scalpSellTicket);
                    break;
                }
            }
        }
    }
    else if(scalpLot > 0)
    {
        if(ShowAlerts) Alert("Scalp SELL Order Failed for ", _Symbol, " - Error: ", GetLastError());
        Print("=== SCALP SELL ORDER FAILURE ===");
        Print("Error Code: ", GetLastError());
        Print("RetCode: ", trade.ResultRetcode());
    }

    if(trendLot > 0 && trade.Sell(trendLot, _Symbol, bid, sellStopLoss, 0, "Trend Sell"))
    {
        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            if(PositionSelectByTicket(PositionGetTicket(i)))
            {
                if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                   PositionGetInteger(POSITION_MAGIC) == magic &&
                   PositionGetString(POSITION_COMMENT) == "Trend Sell")
                {
                    trendSellTicket = PositionGetTicket(i);
                    trendSellOpened = true;
                    Print("Trend Sell Opened: #", trendSellTicket);
                    if(ShowAlerts) Alert("Trend SELL Order Success for ", _Symbol, " - Ticket: #", trendSellTicket);
                    break;
                }
            }
        }
    }
    else if(trendLot > 0)
    {
        if(ShowAlerts) Alert("Trend SELL Order Failed for ", _Symbol, " - Error: ", GetLastError());
        Print("=== TREND SELL ORDER FAILURE ===");
        Print("Error Code: ", GetLastError());
        Print("RetCode: ", trade.ResultRetcode());
    }

    // ===============================================
    // V20.6 - Aeron Binary Signal Publishing (AFTER successful trades)
    // ===============================================
    if(EnableAeronPublishing && (scalpSellOpened || trendSellOpened))
    {
        // Use AeronInstrumentName for both symbol and instrument, or fallback to _Symbol
        string aeronName = (StringLen(AeronInstrumentName) > 0) ? AeronInstrumentName : ExtractSymbolPrefix(_Symbol);
        string symbol = aeronName;
        string instrument = aeronName;

        double mainBuffer[], signalBuffer[];
        ArraySetAsSeries(mainBuffer, true);
        ArraySetAsSeries(signalBuffer, true);

        float confidence = 80.0;
        if(CopyBuffer(stochHandle, 0, 0, 3, mainBuffer) > 0 &&
           CopyBuffer(stochHandle, 1, 0, 3, signalBuffer) > 0)
        {
            double K = mainBuffer[0];
            double D = signalBuffer[0];
            confidence = (float)MathMin(50.0 + MathAbs(K - D), 95.0);
        }

        // Publish ShortEntry1 (stop loss only)
        bool pub1 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_SHORT_ENTRY1,
            0,
            SL,
            0,
            1,
            confidence,
            AeronSourceTag
        );

        if(pub1)
        {
            PrintFormat("[AERON_PUB] ✅ ShortEntry1: %s SL=%d qty=1 conf=%.1f", symbol, SL, confidence);
        }

        // Publish ShortEntry2 (stop loss + profit target)
        int profitOffset = (int)(TP * 0.4);
        bool pub2 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_SHORT_ENTRY2,
            0,
            SL,
            SL + profitOffset,
            1,
            confidence,
            AeronSourceTag
        );

        if(pub2)
        {
            PrintFormat("[AERON_PUB] ✅ ShortEntry2: %s SL=%d TP=%d qty=1 conf=%.1f",
                        symbol, SL, SL + profitOffset, confidence);
        }
    }
}

//+------------------------------------------------------------------+
//| Remaining Support Functions from V20.3                          |
//+------------------------------------------------------------------+

void ExecuteImmediateTrade()
{
    Print("=== EXECUTING IMMEDIATE TRADE ===");
    UpdateAllPositionStatus();

    if(!IsTradingAllowed())
    {
        Print("Immediate Entry: Trading is not allowed at this time.");
        Print("Current trading hours: ", StringFormat("%02d:%02d", currentStartHour, currentStartMinute), 
              " to ", StringFormat("%02d:%02d", currentEndHour, currentEndMinute));
        return;
    }
    
    if(!IsInitialDelayOver())
    {
        Print("Immediate Entry: Respecting DelayOnInitialOrder setting - waiting for initial delay to pass.");
        Print("DelayOnInitialOrder: ", DelayOnInitialOrder, " seconds");
        return;
    }

    if(scalpBuyOpened || trendBuyOpened || scalpSellOpened || trendSellOpened)
    {
        Print("Immediate entry skipped: A position for this EA already exists.");
        Print("Position status - ScalpBuy:", scalpBuyOpened, " TrendBuy:", trendBuyOpened, 
              " ScalpSell:", scalpSellOpened, " TrendSell:", trendSellOpened);
        return;
    }

    double immediateMainLine[2], immediateSignalLine[2];
    if(CopyBuffer(stochHandle, 0, 1, 2, immediateMainLine) < 2 || CopyBuffer(stochHandle, 1, 1, 2, immediateSignalLine) < 2)
    {
        Print("Immediate entry failed: Could not get indicator data.");
        return;
    }
    
    double last_closed_main = immediateMainLine[0];
    double last_closed_sign = immediateSignalLine[0];

    if(last_closed_main > last_closed_sign)
    {
        Print("Immediate entry condition: BUY (Main > Signal).");
        OpenBuyPositions();
        firstTradeOfDayPlaced = true;
        Print("✅ Immediate entry BUY positions opened successfully");
    }
    else if(last_closed_main < last_closed_sign)
    {
        Print("Immediate entry condition: SELL (Main < Signal).");
        OpenSellPositions();
        firstTradeOfDayPlaced = true;
        Print("✅ Immediate entry SELL positions opened successfully");
    }
    else
    {
        Print("Immediate entry skipped: No clear direction (Main == Signal).");
        Print("Stochastic values - Main: ", DoubleToString(last_closed_main, 2), 
              " Signal: ", DoubleToString(last_closed_sign, 2));
    }
}

void RecoverExistingPositions()
{
    Print("=== POSITION RECOVERY AFTER RESTART ===");
    int recoveredPositions = 0;
    
    scalpBuyOpened = false; trendBuyOpened = false;
    scalpSellOpened = false; trendSellOpened = false;
    scalpBuyTicket = 0; trendBuyTicket = 0;
    scalpSellTicket = 0; trendSellTicket = 0;
    
    for(int i = 0; i < PositionsTotal(); i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == magic)
            {
                string comment = PositionGetString(POSITION_COMMENT);
                ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                
                if(comment == "Scalp Buy" && posType == POSITION_TYPE_BUY)
                {
                    scalpBuyTicket = ticket;
                    scalpBuyOpened = true;
                    Print("Recovered Scalp Buy position: #", ticket);
                    recoveredPositions++;
                }
                else if(comment == "Trend Buy" && posType == POSITION_TYPE_BUY)
                {
                    trendBuyTicket = ticket;
                    trendBuyOpened = true;
                    Print("Recovered Trend Buy position: #", ticket);
                    recoveredPositions++;
                }
                else if(comment == "Scalp Sell" && posType == POSITION_TYPE_SELL)
                {
                    scalpSellTicket = ticket;
                    scalpSellOpened = true;
                    Print("Recovered Scalp Sell position: #", ticket);
                    recoveredPositions++;
                }
                else if(comment == "Trend Sell" && posType == POSITION_TYPE_SELL)
                {
                    trendSellTicket = ticket;
                    trendSellOpened = true;
                    Print("Recovered Trend Sell position: #", ticket);
                    recoveredPositions++;
                }
            }
        }
    }
    
    Print("Position recovery complete. Recovered ", recoveredPositions, " positions.");
    
    if(recoveredPositions > 0 && ShowAlerts)
    {
        Alert("EA Restarted: Recovered ", recoveredPositions, " existing positions for ", _Symbol);
    }
}

void CheckKillSwitchPostTimeRecovery()
{
    if(!EnableKillSwitch) return;
    
    MqlDateTime time;
    TimeCurrent(time);
    
    int serverToEasternOffset = GetServerToEasternOffset(TimeCurrent());
    int estHour = time.hour + serverToEasternOffset;
    if(estHour < 0) estHour += 24;
    if(estHour >= 24) estHour -= 24;
    
    bool isPastKillTime = (estHour > currentEndHour) || (estHour == currentEndHour && time.min >= currentEndMinute);
    
    if(isPastKillTime && !scalpBuyOpened && !trendBuyOpened && !scalpSellOpened && !trendSellOpened)
    {
        killSwitchExecuted = true;
        stopTradingForDay = true;
        
        Print("=== KILL SWITCH POST-TIME RECOVERY ===");
        Print("EA restarted after kill switch time (", currentEndHour, ":", StringFormat("%02d", currentEndMinute), " EST/EDT)");
        Print("Current EST Time: ", estHour, ":", StringFormat("%02d", time.min));
        Print("No positions found - marking kill switch as executed and disabling trading");
        
        if(ShowAlerts)
        {
            Alert("Kill Switch Recovery: EA restarted after end time for ", _Symbol, " - Trading disabled");
        }
    }
}

bool PositionExistsByTicket(ulong ticket)
{
    if(ticket == 0) return false;
    
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) == ticket)
        {
            if(PositionSelectByTicket(ticket))
            {
                if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
                   PositionGetInteger(POSITION_MAGIC) == magic)
                {
                    return true;
                }
            }
        }
    }
    return false;
}

void UpdateAllPositionStatus()
{
    if(scalpBuyTicket != 0 && !PositionSelectByTicket(scalpBuyTicket)) { scalpBuyOpened = false; scalpBuyTicket = 0; Print("Scalp Buy position closed."); }
    if(trendBuyTicket != 0 && !PositionSelectByTicket(trendBuyTicket)) { trendBuyOpened = false; trendBuyTicket = 0; Print("Trend Buy position closed."); }
    if(scalpSellTicket != 0 && !PositionSelectByTicket(scalpSellTicket)) { scalpSellOpened = false; scalpSellTicket = 0; Print("Scalp Sell position closed."); }
    if(trendSellTicket != 0 && !PositionSelectByTicket(trendSellTicket)) { trendSellOpened = false; trendSellTicket = 0; Print("Trend Sell position closed."); }
}

bool AreAllReversePositionsClosed(bool checkingForBuy)
{
    if(checkingForBuy)
    {
        bool sellPositionsClosed = (!scalpSellOpened && !trendSellOpened);
        bool scalpSellExists = (scalpSellTicket != 0 && PositionExistsByTicket(scalpSellTicket));
        bool trendSellExists = (trendSellTicket != 0 && PositionExistsByTicket(trendSellTicket));
        
        bool confirmed = sellPositionsClosed && !scalpSellExists && !trendSellExists;
        
        if(!confirmed)
        {
            Print("SELL positions still open - Scalp: ", scalpSellExists ? "OPEN" : "CLOSED", 
                  " | Trend: ", trendSellExists ? "OPEN" : "CLOSED");
        }
        
        return confirmed;
    }
    else
    {
        bool buyPositionsClosed = (!scalpBuyOpened && !trendBuyOpened);
        bool scalpBuyExists = (scalpBuyTicket != 0 && PositionExistsByTicket(scalpBuyTicket));
        bool trendBuyExists = (trendBuyTicket != 0 && PositionExistsByTicket(trendBuyTicket));
        
        bool confirmed = buyPositionsClosed && !scalpBuyExists && !trendBuyExists;
        
        if(!confirmed)
        {
            Print("BUY positions still open - Scalp: ", scalpBuyExists ? "OPEN" : "CLOSED", 
                  " | Trend: ", trendBuyExists ? "OPEN" : "CLOSED");
        }
        
        return confirmed;
    }
}

void CloseAllBuyPositions()
{
    Print("Reversal signal: Sending request to close all BUY positions.");
    bool scalpCloseSuccess = true;
    bool trendCloseSuccess = true;
    
    if(scalpBuyOpened && scalpBuyTicket != 0) 
    {
        if(PositionExistsByTicket(scalpBuyTicket))
        {
            // Get position P&L before closing (for logging only, not publishing on reversal)
            if(PositionSelectByTicket(scalpBuyTicket))
            {
                double positionProfit = PositionGetDouble(POSITION_PROFIT);
                string exitReason = (positionProfit >= 0) ? "Profit target" : "Stop loss";
                
                if(trade.PositionClose(scalpBuyTicket))
                {
                    Print("Scalp Buy position close request sent successfully. Ticket: #", scalpBuyTicket, " Exit: ", exitReason, " (Reversal - no Kafka publish)");
                    
                    // V20.4 - Do NOT publish exit signal on reversal (new short entry will be published)
                    
                    if(ShowAlerts) Alert("Scalp BUY Position Closed (Reversal) for ", _Symbol, " - Ticket: #", scalpBuyTicket);
                }
                else
                {
                    scalpCloseSuccess = false;
                    Print("=== SCALP BUY CLOSE FAILURE ===");
                    Print("Failed to close Scalp Buy position #", scalpBuyTicket);
                    Print("Error Code: ", GetLastError());
                    Print("RetCode: ", trade.ResultRetcode());
                }
            }
        }
        else
        {
            Print("Scalp Buy position #", scalpBuyTicket, " no longer exists. Resetting tracking.");
            scalpBuyOpened = false;
            scalpBuyTicket = 0;
        }
    }
    
    if(trendBuyOpened && trendBuyTicket != 0) 
    {
        if(PositionExistsByTicket(trendBuyTicket))
        {
            // Get position P&L before closing (for logging only, not publishing on reversal)
            if(PositionSelectByTicket(trendBuyTicket))
            {
                double positionProfit = PositionGetDouble(POSITION_PROFIT);
                string exitReason = (positionProfit >= 0) ? "Profit target" : "Stop loss";
                
                if(trade.PositionClose(trendBuyTicket))
                {
                    Print("Trend Buy position close request sent successfully. Ticket: #", trendBuyTicket, " Exit: ", exitReason, " (Reversal - no Kafka publish)");
                    
                    // V20.4 - Do NOT publish exit signal on reversal (new short entry will be published)
                    
                    if(ShowAlerts) Alert("Trend BUY Position Closed (Reversal) for ", _Symbol, " - Ticket: #", trendBuyTicket);
                }
                else
                {
                    trendCloseSuccess = false;
                    Print("=== TREND BUY CLOSE FAILURE ===");
                    Print("Failed to close Trend Buy position #", trendBuyTicket);
                    Print("Error Code: ", GetLastError());
                    Print("RetCode: ", trade.ResultRetcode());
                }
            }
        }
        else
        {
            Print("Trend Buy position #", trendBuyTicket, " no longer exists. Resetting tracking.");
            trendBuyOpened = false;
            trendBuyTicket = 0;
        }
    }
    
    if(scalpCloseSuccess)
    {
        scalpBuyOpened = false;
        scalpBuyTicket = 0;
    }
    
    if(trendCloseSuccess)
    {
        trendBuyOpened = false;
        trendBuyTicket = 0;
    }
}

void CloseAllSellPositions()
{
    Print("Reversal signal: Sending request to close all SELL positions.");
    bool scalpCloseSuccess = true;
    bool trendCloseSuccess = true;
    
    if(scalpSellOpened && scalpSellTicket != 0) 
    {
        if(PositionExistsByTicket(scalpSellTicket))
        {
            // Get position P&L before closing (for logging only, not publishing on reversal)
            if(PositionSelectByTicket(scalpSellTicket))
            {
                double positionProfit = PositionGetDouble(POSITION_PROFIT);
                string exitReason = (positionProfit >= 0) ? "Profit target" : "Stop loss";
                
                if(trade.PositionClose(scalpSellTicket))
                {
                    Print("Scalp Sell position close request sent successfully. Ticket: #", scalpSellTicket, " Exit: ", exitReason, " (Reversal - no Kafka publish)");
                    
                    // V20.4 - Do NOT publish exit signal on reversal (new long entry will be published)
                    
                    if(ShowAlerts) Alert("Scalp SELL Position Closed (Reversal) for ", _Symbol, " - Ticket: #", scalpSellTicket);
                }
                else
                {
                    scalpCloseSuccess = false;
                    Print("=== SCALP SELL CLOSE FAILURE ===");
                    Print("Failed to close Scalp Sell position #", scalpSellTicket);
                    Print("Error Code: ", GetLastError());
                    Print("RetCode: ", trade.ResultRetcode());
                }
            }
        }
        else
        {
            Print("Scalp Sell position #", scalpSellTicket, " no longer exists. Resetting tracking.");
            scalpSellOpened = false;
            scalpSellTicket = 0;
        }
    }
    
    if(trendSellOpened && trendSellTicket != 0) 
    {
        if(PositionExistsByTicket(trendSellTicket))
        {
            // Get position P&L before closing (for logging only, not publishing on reversal)
            if(PositionSelectByTicket(trendSellTicket))
            {
                double positionProfit = PositionGetDouble(POSITION_PROFIT);
                string exitReason = (positionProfit >= 0) ? "Profit target" : "Stop loss";
                
                if(trade.PositionClose(trendSellTicket))
                {
                    Print("Trend Sell position close request sent successfully. Ticket: #", trendSellTicket, " Exit: ", exitReason, " (Reversal - no Kafka publish)");
                    
                    // V20.4 - Do NOT publish exit signal on reversal (new long entry will be published)
                    
                    if(ShowAlerts) Alert("Trend SELL Position Closed (Reversal) for ", _Symbol, " - Ticket: #", trendSellTicket);
                }
                else
                {
                    trendCloseSuccess = false;
                    Print("=== TREND SELL CLOSE FAILURE ===");
                    Print("Failed to close Trend Sell position #", trendSellTicket);
                    Print("Error Code: ", GetLastError());
                    Print("RetCode: ", trade.ResultRetcode());
                }
            }
        }
        else
        {
            Print("Trend Sell position #", trendSellTicket, " no longer exists. Resetting tracking.");
            trendSellOpened = false;
            trendSellTicket = 0;
        }
    }
    
    if(scalpCloseSuccess)
    {
        scalpSellOpened = false;
        scalpSellTicket = 0;
    }
    
    if(trendCloseSuccess)
    {
        trendSellOpened = false;
        trendSellTicket = 0;
    }
}

void CheckDailyLossLimit()
{
    static datetime lastResetTime = 0;
    MqlDateTime dt;
    TimeCurrent(dt);
    
    int serverToEasternOffset = GetServerToEasternOffset(TimeCurrent());
    int estHour = dt.hour + serverToEasternOffset;
    if(estHour < 0) estHour += 24;
    if(estHour >= 24) estHour -= 24;
    
    bool shouldReset = false;
    datetime todayResetBoundary = (datetime)StringToTime(TimeToString(TimeCurrent(), TIME_DATE)) + 18 * 3600;
    if(lastResetTime == 0) shouldReset = true;
    
    string dateStr = TimeToString(TimeCurrent(), TIME_DATE);
    datetime est_reset_time_for_today = StringToTime(dateStr) - (serverToEasternOffset - (-5)) * 3600 + 18 * 3600;
    
    MqlDateTime server_time; TimeCurrent(server_time);
    MqlDateTime est_time; TimeGMT(est_time);
    est_time.hour -= 5;
    
    static int last_reset_day = 0;
    if (est_time.day != last_reset_day && est_time.hour >= 18)
    {
        shouldReset = true;
        last_reset_day = est_time.day;
    }
    
    if(shouldReset)
    {
        todayStartingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        if(stopTradingForDay) Print("Trading day reset at 18:00 EST. Daily loss limit has been reset.");
        Print("Daily loss limit reset at 18:00 EST. Starting balance: $", DoubleToString(todayStartingBalance, 2));
        stopTradingForDay = false;
        killSwitchExecuted = false;
        
        dailyMaxProfitBalance = todayStartingBalance;
        profitProtectionActive = false;
        stopTradingForProfitProtection = false;
        Print("Daily profit protection reset. Initial max profit balance: $", DoubleToString(dailyMaxProfitBalance, 2));

        firstTradeOfDayPlaced = false;
        
        if(ImmediateEntryOnLoad && !immediateEntryCompleted)
        {
            immediateEntryPending = true;
            immediateEntryCompleted = false;
            Print("Immediate entry flags reset for new trading day - will attempt immediate entry again");
        }
        
        Print("Initial order delay flag has been reset for the new trading day.");
    }

    if(stopTradingForDay) return;
    
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    double floatingLoss = fmax(0, currentBalance - currentEquity);
    double realizedLoss = fmax(0, todayStartingBalance - currentBalance);
    double totalLoss = realizedLoss + floatingLoss;
    if(totalLoss > 0 && todayStartingBalance > 0)
    {
        double lossPercentage = (totalLoss / todayStartingBalance) * 100.0;
        if(lossPercentage >= MAX_DAILY_LOSS_PERCENTAGE)
        {
            stopTradingForDay = true;
            Print("!!! DAILY LOSS LIMIT of ", MAX_DAILY_LOSS_PERCENTAGE, "% REACHED. No new trades today. !!!");
        }
    }
}

void CheckDailyProfitProtection()
{
    if(stopTradingForProfitProtection) return;
    
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    double currentProfitAmount = currentEquity - todayStartingBalance;
    double currentProfitPercentage = 0.0;
    
    if(todayStartingBalance > 0)
    {
        currentProfitPercentage = (currentProfitAmount / todayStartingBalance) * 100.0;
    }
    
    if(!profitProtectionActive && currentProfitPercentage >= MAX_DAILY_LOSS_PERCENTAGE)
    {
        profitProtectionActive = true;
        dailyMaxProfitBalance = currentEquity;
        Print("=== PROFIT PROTECTION ACTIVATED ===");
        Print("Daily profit reached threshold: ", DoubleToString(currentProfitPercentage, 2), "% (≥", DoubleToString(MAX_DAILY_LOSS_PERCENTAGE, 1), "%)");
        Print("Starting balance: $", DoubleToString(todayStartingBalance, 2));
        Print("Current equity: $", DoubleToString(currentEquity, 2));
        Print("Profit amount: $", DoubleToString(currentProfitAmount, 2));
        Print("Now monitoring for 50% profit drawdown from peak...");
        
        if(ShowAlerts)
        {
            Alert("💰 PROFIT PROTECTION: Activated for ", _Symbol, " at ", DoubleToString(currentProfitPercentage, 2), "% profit");
            Alert("Monitoring for 50% drawdown from peak to protect gains");
        }
    }
    
    if(profitProtectionActive)
    {
        bool newPeakReached = false;
        if(currentEquity > dailyMaxProfitBalance)
        {
            newPeakReached = true;
            double previousPeak = dailyMaxProfitBalance;
            dailyMaxProfitBalance = currentEquity;
            
            double peakIncrease = dailyMaxProfitBalance - previousPeak;
            double peakIncreasePercentage = (peakIncrease / todayStartingBalance) * 100.0;
            
            if(peakIncrease >= 100.0 || peakIncreasePercentage >= 1.0)
            {
                double totalProfitFromPeak = dailyMaxProfitBalance - todayStartingBalance;
                double totalProfitPercentageFromPeak = (totalProfitFromPeak / todayStartingBalance) * 100.0;
                
                Print("📈 NEW PROFIT PEAK: $", DoubleToString(dailyMaxProfitBalance, 2), 
                      " (", DoubleToString(totalProfitPercentageFromPeak, 2), "% total profit)");
            }
        }
        
        double drawdownFromPeak = dailyMaxProfitBalance - currentEquity;
        double maxProfitAmount = dailyMaxProfitBalance - todayStartingBalance;
        double drawdownPercentage = 0.0;
        
        if(maxProfitAmount > 0)
        {
            drawdownPercentage = (drawdownFromPeak / maxProfitAmount) * 100.0;
        }
        
        static datetime lastProtectionLog = 0;
        if(TimeCurrent() - lastProtectionLog >= 30)
        {
            Print("PROFIT PROTECTION STATUS:");
            Print("Peak Balance: $", DoubleToString(dailyMaxProfitBalance, 2));
            Print("Current Equity: $", DoubleToString(currentEquity, 2));
            Print("Drawdown from Peak: $", DoubleToString(drawdownFromPeak, 2), " (", DoubleToString(drawdownPercentage, 1), "%)");
            Print("Trigger Level: 50% drawdown");
            lastProtectionLog = TimeCurrent();
        }
        
        if(drawdownPercentage >= 50.0)
        {
            stopTradingForProfitProtection = true;
            
            Print("=== PROFIT PROTECTION TRIGGERED ===");
            Print("50% drawdown detected from peak profit!");
            Print("Peak equity reached: $", DoubleToString(dailyMaxProfitBalance, 2));
            Print("Current equity: $", DoubleToString(currentEquity, 2));
            Print("Drawdown amount: $", DoubleToString(drawdownFromPeak, 2));
            Print("Drawdown percentage: ", DoubleToString(drawdownPercentage, 2), "%");
            Print("Closing all positions and stopping trading to conserve profits...");
            
            CloseAllBuyPositions();
            CloseAllSellPositions();
            
            double protectedProfitAmount = currentEquity - todayStartingBalance;
            double protectedProfitPercentage = (protectedProfitAmount / todayStartingBalance) * 100.0;
            
            Print("=== PROFIT PROTECTION SUMMARY ===");
            Print("Starting balance: $", DoubleToString(todayStartingBalance, 2));
            Print("Peak balance reached: $", DoubleToString(dailyMaxProfitBalance, 2));
            Print("Final protected equity: $", DoubleToString(currentEquity, 2));
            Print("Protected profit: $", DoubleToString(protectedProfitAmount, 2), " (", DoubleToString(protectedProfitPercentage, 2), "%)");
            Print("Trading disabled for remainder of day to protect gains");
            
            if(ShowAlerts)
            {
                Alert("🛡️ PROFIT PROTECTION: Trading stopped for ", _Symbol);
                Alert("Protected ", DoubleToString(protectedProfitPercentage, 2), "% profit ($", DoubleToString(protectedProfitAmount, 2), ")");
                Alert("50% drawdown from peak detected - conserving gains");
            }
        }
    }
}

bool IsEasternDST(datetime time)
{
    MqlDateTime dt;
    TimeToStruct(time, dt);
    
    if(dt.mon == 12 || dt.mon <= 2) return false;
    if(dt.mon >= 4 && dt.mon <= 10) return true;
    
    if(dt.mon == 3)
    {
        int firstSunday = 0;
        for(int day = 1; day <= 7; day++)
        {
            MqlDateTime testDate = dt;
            testDate.day = day;
            testDate.hour = 2;
            testDate.min = 0;
            testDate.sec = 0;
            datetime testTime = StructToTime(testDate);
            TimeToStruct(testTime, testDate);
            if(testDate.day_of_week == 0)
            {
                firstSunday = day;
                break;
            }
        }
        int secondSunday = firstSunday + 7;
        
        if(dt.day > secondSunday) return true;
        if(dt.day == secondSunday && dt.hour >= 2) return true;
        return false;
    }
    
    if(dt.mon == 11)
    {
        int firstSunday = 0;
        for(int day = 1; day <= 7; day++)
        {
            MqlDateTime testDate = dt;
            testDate.day = day;
            testDate.hour = 2;
            testDate.min = 0;
            testDate.sec = 0;
            datetime testTime = StructToTime(testDate);
            TimeToStruct(testTime, testDate);
            if(testDate.day_of_week == 0)
            {
                firstSunday = day;
                break;
            }
        }
        
        if(dt.day < firstSunday) return true;
        if(dt.day == firstSunday && dt.hour < 2) return true;
        return false;
    }
    
    return false;
}

int GetEasternOffset(datetime time)
{
    if(IsEasternDST(time))
        return -4;
    else
        return -5;
}

int DetectBrokerServerOffset()
{
    MqlDateTime serverTime;
    TimeCurrent(serverTime);
    
    datetime gmtTime = TimeGMT();
    datetime serverTimeVal = TimeCurrent();
    
    if(gmtTime > 0)
    {
        int offsetSeconds = (int)(serverTimeVal - gmtTime);
        int offsetHours = offsetSeconds / 3600;
        
        if(offsetSeconds % 3600 > 1800) offsetHours++;
        if(offsetSeconds % 3600 < -1800) offsetHours--;
        
        Print("Detected server offset using TimeGMT(): ", offsetHours, " hours from UTC");
        return offsetHours;
    }
    
    int currentHour = serverTime.hour;
    
    if(currentHour >= 8 && currentHour <= 18)
    {
        Print("Heuristic detection: Likely European broker server (UTC+2/+3)");
        return 2;
    }
    else if(currentHour >= 0 && currentHour <= 6)
    {
        Print("Heuristic detection: Possibly Asian broker server (UTC+7)");
        return 7;
    }
    else
    {
        Print("Heuristic detection: Defaulting to UTC broker server");
        return 0;
    }
}

int GetServerToEasternOffset(datetime time)
{
    if(AutoDST)
    {
        int easternFromUTC = GetEasternOffset(time);
        int serverToEastern = -detectedServerOffset + easternFromUTC;
        return serverToEastern;
    }
    else
    {
        return -detectedServerOffset - 5;
    }
}
