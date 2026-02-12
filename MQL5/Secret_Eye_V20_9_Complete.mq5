//+------------------------------------------------------------------+
//|           Stochastic Straight Algo Strategy V20.9.mq5           |
//|                                  Copyright 2025, Sanjeevas Inc.  |
//|                                             https://www.sanjeevas.com|
//+------------------------------------------------------------------+

// V20.9 Release - Dual Session Manual Trading Hours + Optional Kill Time:
// - Added second optional trading session for manual time mode (UseAPITradingHours = false)
// - New inputs: ManualStartTime2, ManualStartMinute2, ManualEndTime2, ManualEndMinute2
// - Second session activates when ManualStartTime2 > 0
// - Optional kill time override: ManualKillTime and ManualKillMinute for position closure
// - Kill time defaults to final session end (Session 2 if enabled, otherwise Session 1)
// - Separation of concerns: Session end times stop NEW orders, kill time closes EXISTING positions
// - Automatic session overlap validation prevents conflicting time ranges
// - Modified IsTradingAllowed() to check both sessions independently
// - Enhanced kill switch logic supports dual sessions and explicit kill time
// - Enhanced session logging displays both active sessions and kill time configuration
// - Backward compatible: V20.8 configurations work without changes (single session)
// - Use cases: London + New York sessions, Asian + European sessions, morning entries with EOD close
//
// V20.8.3 Hotfix - Aeron Publisher Restart Fix (Intermittent Failure Resolution):
// - Added global state tracking (g_AeronIpcStarted, g_AeronUdpStarted, g_LastPublisherCleanup)
// - Implemented CleanupAeronPublishersForce() for unconditional cleanup at startup
// - Added 200ms delay after cleanup to ensure DLL resources are fully released
// - Enhanced OnInit() to check publisher state before starting (prevents double-start)
// - Improved OnDeinit() to track cleanup timestamps and only cleanup active publishers
// - Better error messages indicating possible cleanup issues and retry guidance
// - Prevents race condition where previous EA instance leaves orphaned publishers
// - Fixes intermittent "Failed to start Aeron publisher" errors on restart
//
// V20.8 Release - Multi-Channel Aeron Publishing Architecture:
// - Enhanced Aeron publishing with ENUM_AERON_PUBLISH_MODE configuration system
// - Replaced EnableAeronPublishing (bool) with AeronPublishMode (enum: None/IPC/UDP/Both)
// - Dual independent channel support: AeronPublishChannelIpc and AeronPublishChannelUdp
// - Simultaneous IPC + UDP publishing capability (AERON_PUBLISH_IPC_AND_UDP mode)
// - Independent publisher initialization, error handling, and cleanup per channel
// - Enhanced logging with per-channel success/failure diagnostics
// - Graceful degradation: one channel can fail without affecting the other
// - Four publish modes: NONE, IPC_ONLY, UDP_ONLY, IPC_AND_UDP
// - Breaking change: V20.7 configurations require migration to new input parameters
//
// V20.7 Release - Futures Symbol & Tick Conversion + Exception Handling:
// - Added automatic MT5 points to futures ticks conversion for Aeron signals
// - Implemented futures symbol mapping (user-provided via AeronInstrumentName input)
// - Accurate tick value conversion for all major CME currency futures (6A, 6E, 6B, 6C, 6J, 6N, 6S)
// - Support for equity index futures (ES, NQ, YM) tick sizes
// - Global variables g_AeronSymbol and g_AeronInstrument for consistent symbol usage
// - ConvertPointsToFuturesTicks() function handles point/tick ratio calculations
// - All Aeron signal publishes now use converted tick values for SL/TP
// - Enhanced logging shows both points and converted ticks for transparency
// - Comprehensive exception handling and crash prevention system
// - Safe wrappers for all critical operations (indicators, arrays, DLL calls, WebRequests)
// - Graceful error recovery with detailed logging
// - Protected against: division by zero, null handles, array bounds, infinite loops, memory issues
//
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
#property version   "20.90"
#property description "V20.9 - Dual Session Manual Trading Hours + All V20.8.3 Features"
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

//--- Account Mode Enum
enum ENUM_ACCOUNT_MODE
{
    MODE_UNKNOWN = -1,
    MODE_NETTING = 0,   // One position per symbol
    MODE_HEDGING = 1    // Multiple positions per symbol
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
input int               ManualStartTime = 0;            // Session 1: Start time (hour)
input int               ManualStartMinute = 0;          // Session 1: Start time (minute)
input int               ManualEndTime = 23;             // Session 1: End time (hour)
input int               ManualEndMinute = 0;            // Session 1: End time (minute)

input group             "V20.9 - Second Trading Session (Manual Mode Only)"
input int               ManualStartTime2 = 0;           // Session 2: Start time (hour, 0=disabled)
input int               ManualStartMinute2 = 0;         // Session 2: Start time (minute)
input int               ManualEndTime2 = 0;             // Session 2: End time (hour)
input int               ManualEndMinute2 = 0;           // Session 2: End time (minute)

input group             "V20.9 - Kill Switch Time (Optional Override)"
input int               ManualKillTime = 0;             // Kill time: Hour to close positions (0=use session end)
input int               ManualKillMinute = 0;           // Kill time: Minute to close positions

input group             "Advanced Position Management"
input bool              WaitForClosureConfirmation = true; // Wait for reverse positions to close before opening new ones
input bool              UseFillOrKill = false;          // Use Fill-Or-Kill (FOK) order execution
input int               MaxClosureRetries = 5;          // Maximum retries for position closure
input int               ClosureRetryDelay = 200;        // Delay between closure retries (milliseconds)

input group             "JSON Publishing"
input bool              PublishToKafka = true;          // Enable JSON publishing
input string            KafkaTopicName = "secreteye-signals"; // Topic name(s) - single or comma-separated (e.g., "topic1,topic2,topic3")
input ENUM_MESSAGE_FORMAT MessageFormat = MSG_BOTH;     // Message format selection
input string            PublishHostUri = "192.168.2.17:8000"; // Publishing host (overrides HOST_URI)
input string            InstrumentFullName = "";        // Instrument name for publishing (empty = use _Symbol)

input group             "Aeron Publishing"
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP; // Aeron publish mode
input string            AeronPublishChannelIpc = "aeron:ipc"; // Aeron IPC channel
input string            AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123"; // Aeron UDP channel
input int               AeronPublishStreamId = 1001;       // Aeron publish stream ID
input string            AeronPublishDir = "C:\\aeron\\standalone"; // Aeron directory
input string            AeronSourceTag = "SecretEye_V20_9"; // Source strategy identifier
input string            AeronInstrumentName = "";          // Custom symbol/instrument name for Aeron (e.g. "ES") - sets both fields

//--- Global variables
CTrade              trade;
int                 stochHandle;
static ulong        g_ExpertMagic;              // Expert magic number
static datetime     lastBarTime = 0;
static double       todayStartingBalance = 0;
bool                stopTradingForDay = false;
static int          detectedServerOffset = 0;
static bool         killSwitchExecuted = false;
static bool         firstTradeOfDayPlaced = false;

// V20.5 - Account Mode Detection
static ENUM_ACCOUNT_MODE accountMode = MODE_UNKNOWN;
static bool         hedgingModeDetected = false;

// V20.2 - Immediate Entry Variables
static bool         immediateEntryPending = false;
static bool         immediateEntryCompleted = false;

// V20.7 - Futures Symbol Mapping for Aeron
static string       g_AeronSymbol = "";       // Resolved futures symbol (e.g., "6A", "ES")
static string       g_AeronInstrument = "";   // Full instrument name (e.g., "6A Futures")

// V20.8.3 - Aeron Publisher State Tracking (Restart Fix)
static bool         g_AeronIpcStarted = false;  // Track IPC publisher state
static bool         g_AeronUdpStarted = false;  // Track UDP publisher state
static datetime     g_LastPublisherCleanup = 0; // Track last cleanup time

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

// V20.9 - Second Session Variables (Manual Mode Only)
static int          currentStartHour2 = 0;
static int          currentStartMinute2 = 0;
static int          currentEndHour2 = 0;
static int          currentEndMinute2 = 0;
static bool         session2Enabled = false;           // Track if session 2 is active

// V20.9 - Kill Switch Time Variables
static int          killSwitchHour = 0;                // Effective kill switch hour
static int          killSwitchMinute = 0;              // Effective kill switch minute
static bool         useExplicitKillTime = false;       // True if ManualKillTime > 0

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

//+------------------------------------------------------------------+
//| V20.7 - Exception Handling and Crash Prevention System           |
//+------------------------------------------------------------------+

// Error tracking
static int     g_consecutiveErrors = 0;
static int     g_maxConsecutiveErrors = 10;
static datetime g_lastErrorTime = 0;
static string  g_lastErrorMessage = "";
static bool    g_criticalErrorDetected = false;

// Crash-loop prevention
static datetime g_lastInitTime = 0;
static int     g_initCount = 0;
static int     g_maxInitPer10Sec = 3;

// Operation context for error reporting
enum OPERATION_CONTEXT
{
    OP_INIT,
    OP_TICK,
    OP_INDICATOR,
    OP_TRADE,
    OP_WEBREQUEST,
    OP_DLL_CALL,
    OP_ARRAY_OP,
    OP_CALCULATION,
    OP_AERON_PUBLISH
};

//--- Forward Declarations for Exception Handling Functions
void HandleError(OPERATION_CONTEXT context, int errorCode, string message, bool isCritical = false);
bool SafeCopyBuffer(int indicator_handle, int buffer_num, int start_pos, int count, double &buffer[], OPERATION_CONTEXT context = OP_INDICATOR);
bool SafeStringToCharArray(string str, uchar &array[], int start, int count);
double SafeDivide(double numerator, double denominator, double defaultValue = 0.0);
bool ValidateArrayAccess(const double &array[], int index, string arrayName = "");
bool SafeWebRequest(string method, string url, string headers, int timeout, const char &data[], char &result[], string &resultHeaders, int &httpCode, int maxRetries = 3);
bool IsSafeToOperate();

//--- Forward Declarations
void UpdateAllPositionStatus();
bool CloseAllBuyPositions();
bool CloseAllSellPositions();
bool ClosePositionWithRetry(ulong ticket, string positionName, int maxRetries = 5);
bool IsTradingAllowed();
bool IsInitialDelayOver();
bool CheckDailyLossLimit();
bool CheckDailyProfitProtection();
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
ENUM_ACCOUNT_MODE DetectAccountMarginMode();
int CountPositionsByTypeAndSymbol(ENUM_POSITION_TYPE posType);
int ConvertPointsToFuturesTicks(int points, string futuresSymbol);  // V20.7 - Tick conversion
void CleanupAeronPublishersForce();  // V20.8.3 - Force publisher cleanup for restart fix
bool ValidateSessionsNonOverlapping();  // V20.9 - Session validation

//+------------------------------------------------------------------+
//| V20.5 - Account Margin Mode Detection                           |
//+------------------------------------------------------------------+

/**
 * @brief Detects account margin calculation mode (netting vs hedging)
 * @return ENUM_ACCOUNT_MODE Account margin mode
 */
ENUM_ACCOUNT_MODE DetectAccountMarginMode()
{
    ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
    
    switch(mode)
    {
        case ACCOUNT_MARGIN_MODE_RETAIL_NETTING:
            Print("✅ Account Mode: NETTING (One position per symbol)");
            return MODE_NETTING;
            
        case ACCOUNT_MARGIN_MODE_RETAIL_HEDGING:
            Print("✅ Account Mode: HEDGING (Multiple positions per symbol allowed)");
            return MODE_HEDGING;
            
        case ACCOUNT_MARGIN_MODE_EXCHANGE:
            Print("✅ Account Mode: EXCHANGE (Hedging typically allowed)");
            return MODE_HEDGING;
            
        default:
            Print("⚠️ WARNING: Unknown account margin mode: ", mode, " - Assuming HEDGING for safety");
            return MODE_HEDGING;
    }
}

/**
 * @brief Counts positions by type (buy/sell) for the current symbol
 * @param posType Position type (POSITION_TYPE_BUY or POSITION_TYPE_SELL)
 * @return Number of positions matching the criteria
 */
int CountPositionsByTypeAndSymbol(ENUM_POSITION_TYPE posType)
{
    int count = 0;
    int totalPositions = PositionsTotal();
    
    for(int i = 0; i < totalPositions; i++)
    {
        if(PositionGetSymbol(i) == _Symbol)
        {
            ulong posMagic = PositionGetInteger(POSITION_MAGIC);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            if(posMagic == g_ExpertMagic && type == posType)
            {
                count++;
            }
        }
    }
    
    return count;
}

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
    
    // CRASH FIX - Reset error before WebRequest
    ResetLastError();
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
//| V20.8.3 - Force cleanup of Aeron publishers (Restart Fix)      |
//| Enhanced with exception handling for maximum reliability        |
//+------------------------------------------------------------------+
void CleanupAeronPublishersForce()
{
    Print("=== FORCED AERON CLEANUP ===");
    
    // Safety check - verify we're in a safe state to operate
    if(!IsSafeToOperate())
    {
        Print("⚠️ WARNING: System in error state - cleanup may be unreliable");
        Print("Attempting cleanup anyway to recover from errors...");
    }
    
    // Check if we recently cleaned up (within 2 seconds)
    datetime currentTime = TimeCurrent();
    if(g_LastPublisherCleanup > 0 && (currentTime - g_LastPublisherCleanup) < 2)
    {
        Print("Recent cleanup detected (", (currentTime - g_LastPublisherCleanup), "s ago) - skipping");
        return;
    }
    
    // Unconditionally attempt cleanup (handles orphaned publishers)
    // Wrap DLL calls with exception handling
    Print("Attempting to stop any orphaned IPC publishers...");
    ResetLastError();
    
    // Try-catch equivalent for DLL call
    bool ipcCleanupSuccess = true;
    AeronBridge_StopPublisherIpc();
    int errorIpc = GetLastError();
    
    if(errorIpc != 0)
    {
        ipcCleanupSuccess = false;
        HandleError(OP_DLL_CALL, errorIpc, "IPC publisher cleanup - expected if not running", false);
    }
    else
    {
        Print("✅ IPC publisher cleanup successful");
    }
    g_AeronIpcStarted = false;
    
    Print("Attempting to stop any orphaned UDP publishers...");
    ResetLastError();
    
    // Try-catch equivalent for DLL call
    bool udpCleanupSuccess = true;
    AeronBridge_StopPublisherUdp();
    int errorUdp = GetLastError();
    
    if(errorUdp != 0)
    {
        udpCleanupSuccess = false;
        HandleError(OP_DLL_CALL, errorUdp, "UDP publisher cleanup - expected if not running", false);
    }
    else
    {
        Print("✅ UDP publisher cleanup successful");
    }
    g_AeronUdpStarted = false;
    
    // Wait briefly to ensure cleanup completes
    Sleep(200);
    
    g_LastPublisherCleanup = currentTime;
    Print("Force cleanup complete - ready for fresh start");
    Print("Status: IPC=", (ipcCleanupSuccess ? "OK" : "WARN"), ", UDP=", (udpCleanupSuccess ? "OK" : "WARN"));
    Print("============================");
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // === CRASH-LOOP PREVENTION ===
    // Detect rapid restart cycles that indicate crash loops
    datetime currentTime = TimeCurrent();
    
    if(currentTime - g_lastInitTime < 10) // Within 10 seconds
    {
        g_initCount++;
        if(g_initCount >= g_maxInitPer10Sec)
        {
            Print("========================================");
            Print("⛔ EMERGENCY BRAKE ACTIVATED ⛔");
            Print("EA initialized ", g_initCount, " times in 10 seconds");
            Print("This indicates a crash loop!");
            Print("EA will NOT start to prevent system instability");
            Print("SOLUTION: Restart MT5 manually after fixing the issue");
            Print("========================================");
            Alert("⛔ EA EMERGENCY BRAKE: Crash loop detected. EA will not start. Restart MT5 manually.");
            return INIT_FAILED;
        }
    }
    else
    {
        // Reset counter if more than 10 seconds passed
        g_initCount = 1;
    }
    
    g_lastInitTime = currentTime;
    
    // Reset error tracking
    g_consecutiveErrors = 0;
    g_criticalErrorDetected = false;
    g_lastErrorTime = 0;
    g_lastErrorMessage = "";
    
    // V20.8.3 - Force cleanup of any orphaned publishers from previous instance
    // Only call DLL cleanup when Aeron publishing is actually enabled
    if(AeronPublishMode != AERON_PUBLISH_NONE)
    {
        CleanupAeronPublishersForce();
    }
    
    Print("========================================");
    Print("Initializing Stochastic Algo V20.9");
    Print("Symbol: ", _Symbol);
    Print("Build: Dual Session + Restart Fix + UTC Timestamp + Exception Handling");
    Print("========================================");
    
    ResetLastError();
    
    // Safe magic number calculation with overflow check
    ulong temp_magic = digital_name_ * 1000000 + code_interaction_ * 1000;
    if(temp_magic > ULONG_MAX / 10000) // Check for potential overflow
    {
        HandleError(OP_INIT, 0, "Magic number calculation potential overflow", true);
        return INIT_FAILED;
    }
    
    g_ExpertMagic = temp_magic + StringToInteger(_Symbol);
    trade.SetExpertMagicNumber(g_ExpertMagic);
    
    // Safe margin mode setting
    ResetLastError();
    trade.SetMarginMode();
    int marginError = GetLastError();
    if(marginError != 0)
    {
        HandleError(OP_INIT, marginError, "Failed to set margin mode", false);
    }

    // V20.5 - Detect account margin mode (hedging vs netting)
    accountMode = DetectAccountMarginMode();
    hedgingModeDetected = (accountMode == MODE_HEDGING);
    if(hedgingModeDetected)
    {
        Print("=== HEDGING MODE ACTIVE ===");
        Print("Enhanced position closure with retry logic will be used");
        Print("MaxClosureRetries: ", MaxClosureRetries);
        Print("ClosureRetryDelay: ", ClosureRetryDelay, "ms");
    }

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

    // Safe indicator initialization with parameter validation
    if(K_Period <= 0 || K_Period > 1000 || D_Period <= 0 || D_Period > 1000)
    {
        HandleError(OP_INIT, 0, 
                   StringFormat("Invalid indicator parameters: K=%d, D=%d", K_Period, D_Period), true);
        return INIT_FAILED;
    }
    
    ResetLastError();
    stochHandle = iStochastic(_Symbol, timeFrame, K_Period, D_Period, slowing, MODE_SMA, STO_LOWHIGH);
    int error = GetLastError();
    
    if(stochHandle == INVALID_HANDLE || error != 0)
    {
        HandleError(OP_INIT, error, 
                   StringFormat("Failed to create Stochastic indicator: K=%d, D=%d, TF=%d", 
                               K_Period, D_Period, timeFrame), true);
        return INIT_FAILED;
    }
    
    // Verify indicator is ready (with reduced wait time)
    double test_buffer[1];
    int wait_count = 0;
    while(!SafeCopyBuffer(stochHandle, 0, 0, 1, test_buffer, OP_INIT) && wait_count < 5)
    {
        Sleep(100);
        wait_count++;
    }
    
    if(wait_count >= 5)
    {
        HandleError(OP_INIT, 0, "Stochastic indicator not ready after 500ms", true);
        return INIT_FAILED;
    }
    
    Print("✅ Stochastic indicator initialized successfully");
    
    // Safe daily loss limit initialization
    if(!CheckDailyLossLimit())
    {
        HandleError(OP_INIT, 0, "Failed to initialize daily loss protection", false);
    }

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

    // V20.9 - Second Session Initialization (Manual Mode Only)
    if(!UseAPITradingHours)
    {
        if(ManualStartTime2 > 0)
        {
            Print("=== SECOND SESSION CONFIGURATION ===");
            currentStartHour2 = ManualStartTime2;
            currentStartMinute2 = ManualStartMinute2;
            currentEndHour2 = ManualEndTime2;
            currentEndMinute2 = ManualEndMinute2;
            session2Enabled = true;
            
            Print("Session 2 Time: ", StringFormat("%02d:%02d", currentStartHour2, currentStartMinute2),
                  " to ", StringFormat("%02d:%02d", currentEndHour2, currentEndMinute2));
            
            if(!ValidateSessionsNonOverlapping())
            {
                Print("⚠️ WARNING: Session validation failed - disabling session 2");
                session2Enabled = false;
            }
            else
            {
                Print("✅ Dual session mode enabled successfully");
                if(ShowAlerts)
                {
                    Alert("✅ DUAL SESSION: Trading in two time windows");
                    Alert("Session 1: ", StringFormat("%02d:%02d-%02d:%02d", 
                          currentStartHour, currentStartMinute, currentEndHour, currentEndMinute));
                    Alert("Session 2: ", StringFormat("%02d:%02d-%02d:%02d", 
                          currentStartHour2, currentStartMinute2, currentEndHour2, currentEndMinute2));
                }
            }
        }
        else
        {
            Print("Second session disabled (ManualStartTime2 = 0)");
            session2Enabled = false;
        }
    }
    else
    {
        Print("Second session is only available in manual mode (UseAPITradingHours=false)");
        session2Enabled = false;
    }
    
    // V20.9 - Kill Switch Time Configuration
    if(ManualKillTime > 0)
    {
        Print("=== KILL SWITCH TIME CONFIGURATION ===");
        killSwitchHour = ManualKillTime;
        killSwitchMinute = ManualKillMinute;
        useExplicitKillTime = true;
        Print("Explicit kill time set: ", StringFormat("%02d:%02d", killSwitchHour, killSwitchMinute), " EST/EDT");
        Print("Positions will close at this time regardless of session end times");
        if(ShowAlerts)
        {
            Alert("🔴 KILL SWITCH: Positions will close at ", StringFormat("%02d:%02d", killSwitchHour, killSwitchMinute));
        }
    }
    else
    {
        // Use end time of final active session
        if(session2Enabled)
        {
            killSwitchHour = currentEndHour2;
            killSwitchMinute = currentEndMinute2;
            Print("Kill switch will use Session 2 end time: ", StringFormat("%02d:%02d", killSwitchHour, killSwitchMinute));
        }
        else
        {
            killSwitchHour = currentEndHour;
            killSwitchMinute = currentEndMinute;
            Print("Kill switch will use Session 1 end time: ", StringFormat("%02d:%02d", killSwitchHour, killSwitchMinute));
        }
        useExplicitKillTime = false;
    }

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
    // V20.7 - Aeron Publishing Setup (Multi-Channel)
    // ===============================
    if(AeronPublishMode != AERON_PUBLISH_NONE)
    {
        Print("=== AERON BINARY PUBLISHING CONFIGURATION ===");
        Print("Aeron Publishing Mode: ", EnumToString(AeronPublishMode));
        Print("Aeron Directory: ", AeronPublishDir);
        Print("Stream ID: ", AeronPublishStreamId);
        Print("Source Tag: ", AeronSourceTag);
        Print("Binary Protocol: 104-byte frame (matches NinjaTrader AeronSignalPublisher)");
        
        bool ipcStarted = false;
        bool udpStarted = false;
        
        // Start IPC publisher if needed
        if(AeronPublishMode == AERON_PUBLISH_IPC_ONLY || AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
        {
            Print("Starting IPC Publisher...");
            Print("IPC Channel: ", AeronPublishChannelIpc);
            
            // V20.8.3 RESTART FIX - Check if already started
            if(g_AeronIpcStarted)
            {
                Print("⚠️ WARNING: IPC publisher already marked as started - forcing cleanup");
                ResetLastError();
                AeronBridge_StopPublisherIpc();
                int cleanupError = GetLastError();
                if(cleanupError != 0)
                {
                    HandleError(OP_DLL_CALL, cleanupError, "Force cleanup of IPC publisher before restart", false);
                }
                Sleep(100); // Allow time for cleanup
                g_AeronIpcStarted = false;
            }
            
            // V20.8 CRASH FIX - Reset error before DLL call
            ResetLastError();
            
            // Safe DLL call with exception handling
            int resultIpc = AeronBridge_StartPublisherIpcW(
                AeronPublishDir,
                AeronPublishChannelIpc,
                AeronPublishStreamId,
                3000);
            
            int dllError = GetLastError();
            
            if(resultIpc == 0 || dllError != 0)
            {
                uchar errBuf[512];
                ArrayInitialize(errBuf, 0);
                int errLen = AeronBridge_LastError(errBuf, ArraySize(errBuf));
                string errMsg = (errLen > 0) ? CharArrayToString(errBuf, 0, errLen) : "Unknown error";
                
                // Use exception handling system
                string detailedMsg = StringFormat("Failed to start IPC publisher: %s | Possible: MediaDriver not running, invalid path/channel, or orphaned instance", errMsg);
                HandleError(OP_DLL_CALL, dllError, detailedMsg, false);
                
                PrintFormat("ERROR: Failed to start Aeron IPC publisher: %s", errMsg);
                PrintFormat("Possible causes:");
                PrintFormat("  - MediaDriver not running");
                PrintFormat("  - Incorrect Aeron directory path");
                PrintFormat("  - Invalid IPC channel format");
                PrintFormat("  - Previous instance not fully cleaned up (retry in 5 seconds)");
                
                if(ShowAlerts)
                {
                    Alert("⚠️ ERROR: Failed to start Aeron IPC publisher: ", errMsg);
                }
                g_AeronIpcStarted = false;
            }
            else
            {
                ipcStarted = true;
                g_AeronIpcStarted = true;
                Print("✅ Aeron IPC publisher started successfully");
                Print("IPC consumers can subscribe on channel: ", AeronPublishChannelIpc);
            }
        }
        
        // Start UDP publisher if needed
        if(AeronPublishMode == AERON_PUBLISH_UDP_ONLY || AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
        {
            Print("Starting UDP Publisher...");
            Print("UDP Channel: ", AeronPublishChannelUdp);
            
            // V20.8.3 RESTART FIX - Check if already started
            if(g_AeronUdpStarted)
            {
                Print("⚠️ WARNING: UDP publisher already marked as started - forcing cleanup");
                ResetLastError();
                AeronBridge_StopPublisherUdp();
                int cleanupError = GetLastError();
                if(cleanupError != 0)
                {
                    HandleError(OP_DLL_CALL, cleanupError, "Force cleanup of UDP publisher before restart", false);
                }
                Sleep(100); // Allow time for cleanup
                g_AeronUdpStarted = false;
            }
            
            // V20.8 CRASH FIX - Reset error before DLL call
            ResetLastError();
            
            // Safe DLL call with exception handling
            int resultUdp = AeronBridge_StartPublisherUdpW(
                AeronPublishDir,
                AeronPublishChannelUdp,
                AeronPublishStreamId,
                3000);
            
            int dllError = GetLastError();
            
            if(resultUdp == 0 || dllError != 0)
            {
                uchar errBuf[512];
                ArrayInitialize(errBuf, 0);
                int errLen = AeronBridge_LastError(errBuf, ArraySize(errBuf));
                string errMsg = (errLen > 0) ? CharArrayToString(errBuf, 0, errLen) : "Unknown error";
                
                // Use exception handling system
                string detailedMsg = StringFormat("Failed to start UDP publisher: %s | Possible: MediaDriver not running, invalid path/channel/firewall, or orphaned instance", errMsg);
                HandleError(OP_DLL_CALL, dllError, detailedMsg, false);
                
                PrintFormat("ERROR: Failed to start Aeron UDP publisher: %s", errMsg);
                PrintFormat("Possible causes:");
                PrintFormat("  - MediaDriver not running");
                PrintFormat("  - Incorrect Aeron directory path");
                PrintFormat("  - Invalid UDP channel format or endpoint");
                PrintFormat("  - Firewall blocking UDP port");
                PrintFormat("  - Previous instance not fully cleaned up (retry in 5 seconds)");
                
                if(ShowAlerts)
                {
                    Alert("⚠️ ERROR: Failed to start Aeron UDP publisher: ", errMsg);
                }
                g_AeronUdpStarted = false;
            }
            else
            {
                udpStarted = true;
                g_AeronUdpStarted = true;
                Print("✅ Aeron UDP publisher started successfully");
                Print("UDP consumers can subscribe on channel: ", AeronPublishChannelUdp);
            }
        }
        
        // Summary
        if(ipcStarted || udpStarted)
        {
            Print("Ready to broadcast binary trading signals via Aeron");
            
            // V20.7 - Initialize futures symbol mapping
            if(AeronInstrumentName != "")
            {
                g_AeronSymbol = AeronInstrumentName;
                PrintFormat("✅ Using user-provided futures symbol: %s (from AeronInstrumentName)", g_AeronSymbol);
            }
            else
            {
                g_AeronSymbol = _Symbol;
                PrintFormat("⚠️ No AeronInstrumentName specified - using MT5 symbol: %s", g_AeronSymbol);
                PrintFormat("   Recommendation: Set AeronInstrumentName input (e.g., '6A' for AUDUSD futures)");
            }
            
            g_AeronInstrument = g_AeronSymbol;
            PrintFormat("Aeron Instrument Name: %s", g_AeronInstrument);
            PrintFormat("Point-to-Tick Conversion: Enabled for %s", g_AeronSymbol);
            
            if(ShowAlerts)
            {
                string channels = "";
                if(ipcStarted) channels += "IPC";
                if(ipcStarted && udpStarted) channels += " + ";
                if(udpStarted) channels += "UDP";
                Alert("✅ Aeron Publisher: Started successfully (", channels, ")");
            }
        }
        else
        {
            Print("⚠️ WARNING: No Aeron publishers were successfully started");
        }
    }
    else
    {
        Print("Aeron Binary Publishing is DISABLED (AeronPublishMode=None)");
    }
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit: Called when the EA is removed                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("========================================");
    Print("EA Deinitialization Started");
    Print("Reason code: ", reason);
    Print("========================================");
    
    // Safe indicator cleanup
    if(stochHandle != INVALID_HANDLE)
    {
        ResetLastError();
        if(!IndicatorRelease(stochHandle))
        {
            int error = GetLastError();
            Print("Warning: Failed to release indicator handle, error: ", error);
        }
        else
        {
            Print("✅ Stochastic indicator released");
        }
        stochHandle = INVALID_HANDLE;
    }
    
    // V20.8.3 - Safe Aeron publisher cleanup with state tracking and exception handling
    if(AeronPublishMode != AERON_PUBLISH_NONE)
    {
        Print("Cleaning up Aeron publishers...");
        
        if((AeronPublishMode == AERON_PUBLISH_IPC_ONLY || AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP) && g_AeronIpcStarted)
        {
            Print("Stopping IPC publisher...");
            ResetLastError();
            AeronBridge_StopPublisherIpc();
            int errorIpc = GetLastError();
            if(errorIpc != 0)
            {
                HandleError(OP_DLL_CALL, errorIpc, "IPC publisher cleanup during OnDeinit", false);
                Print("Warning: Aeron IPC publisher cleanup error: ", errorIpc);
            }
            else
            {
                Print("✅ Aeron IPC publisher stopped and cleaned up");
            }
            g_AeronIpcStarted = false;
        }
        
        if((AeronPublishMode == AERON_PUBLISH_UDP_ONLY || AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP) && g_AeronUdpStarted)
        {
            Print("Stopping UDP publisher...");
            ResetLastError();
            AeronBridge_StopPublisherUdp();
            int errorUdp = GetLastError();
            if(errorUdp != 0)
            {
                HandleError(OP_DLL_CALL, errorUdp, "UDP publisher cleanup during OnDeinit", false);
                Print("Warning: Aeron UDP publisher cleanup error: ", errorUdp);
            }
            else
            {
                Print("✅ Aeron UDP publisher stopped and cleaned up");
            }
            g_AeronUdpStarted = false;
        }
        
        g_LastPublisherCleanup = TimeCurrent();
        Print("Publisher cleanup timestamp recorded: ", TimeToString(g_LastPublisherCleanup));
    }
    
    // Print error statistics
    Print("========================================");
    Print("Session Error Statistics:");
    Print("Total consecutive errors: ", g_consecutiveErrors);
    Print("Critical error detected: ", g_criticalErrorDetected ? "YES" : "NO");
    if(g_lastErrorMessage != "")
    {
        Print("Last error: ", g_lastErrorMessage);
    }
    Print("========================================");
    
    Print("✅ Terminating Stochastic Algo V20.8.3 - Shutdown complete");
}

//+------------------------------------------------------------------+
//| OnTick: Main execution loop                                      |
//+------------------------------------------------------------------+
void OnTick()
{
    // Safety check - halt if critical error detected
    if(!IsSafeToOperate())
    {
        return;
    }
    
    if(!on) return;
    
    // Catch-all error handler for unexpected issues
    ResetLastError();
    
    // V20.5 - Check and update trading hours daily (protected)
    CheckAndUpdateDailyTradingHours();
    int updateError = GetLastError();
    if(updateError != 0)
    {
        HandleError(OP_TICK, updateError, "Failed to update daily trading hours", false);
    }
    
    // V20.4 - Reset publish flags for new tick
    publishFlags = 0;
    
    // === KILL SWITCH LOGIC ===
    // V20.9 - Enhanced: Uses kill time or end of final session, doesn't stop trading in earlier sessions
    if(EnableKillSwitch && !killSwitchExecuted)
    {
        MqlDateTime time;
        TimeToStruct(TimeCurrent(), time);

        // Get the server-to-eastern offset for kill switch timing
        int serverToEasternOffset = GetServerToEasternOffset(TimeCurrent());

        // Convert server time to EST/EDT
        int estHour = time.hour + serverToEasternOffset;
        if(estHour < 0) estHour += 24;
        if(estHour >= 24) estHour -= 24;

        // Check if we're at the kill switch time (explicit or final session end)
        if(estHour == killSwitchHour && time.min == killSwitchMinute)
        {
            // Check if we actually have positions to close
            if(scalpBuyOpened || trendBuyOpened || scalpSellOpened || trendSellOpened)
            {
                Print("=== KILL SWITCH ACTIVATED ===");
                if(useExplicitKillTime)
                {
                    Print("Closing positions at explicit kill time: ", killSwitchHour, ":", StringFormat("%02d", killSwitchMinute), " EST/EDT");
                }
                else if(session2Enabled)
                {
                    Print("Closing positions at Session 2 end time: ", killSwitchHour, ":", StringFormat("%02d", killSwitchMinute), " EST/EDT");
                }
                else
                {
                    Print("Closing positions at Session 1 end time: ", killSwitchHour, ":", StringFormat("%02d", killSwitchMinute), " EST/EDT");
                }
                Print("Current EST Time: ", estHour, ":", StringFormat("%02d", time.min));

                // Close only this EA's positions, not all account positions
                CloseAllBuyPositions();
                CloseAllSellPositions();

                string killReason = useExplicitKillTime ? "explicit kill time" : 
                                   (session2Enabled ? "Session 2 end" : "Session 1 end");
                if(ShowAlerts) Alert("Kill Switch: Positions closed at ", killReason, " for ", _Symbol);

                Print("Kill switch executed successfully. Positions closed.");
            }
            else
            {
                Print("Kill switch time reached but no positions to close for ", _Symbol);
            }

            // Mark kill switch as executed to prevent repeated execution
            killSwitchExecuted = true;

            // Disable trading for the rest of the day
            stopTradingForDay = true;
            Print("Trading disabled for remainder of day due to kill switch activation");
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
    
    if(!CheckDailyLossLimit())
    {
        HandleError(OP_TICK, 0, "CheckDailyLossLimit failed", false);
    }
    
    if(!CheckDailyProfitProtection())
    {
        HandleError(OP_TICK, 0, "CheckDailyProfitProtection failed", false);
    }
    
    if(stopTradingForDay || stopTradingForProfitProtection) return;

    // Safe indicator buffer reading with validation
    double mainLine[3], signalLine[3];
    ArrayInitialize(mainLine, 0);
    ArrayInitialize(signalLine, 0);
    
    if(!SafeCopyBuffer(stochHandle, 0, 1, 3, mainLine, OP_INDICATOR))
    {
        HandleError(OP_INDICATOR, GetLastError(), "Failed to copy main stochastic buffer", false);
        return;
    }
    
    if(!SafeCopyBuffer(stochHandle, 1, 1, 3, signalLine, OP_INDICATOR))
    {
        HandleError(OP_INDICATOR, GetLastError(), "Failed to copy signal stochastic buffer", false);
        return;
    }
    
    // Validate array indices before access
    if(!ValidateArrayAccess(mainLine, 0, "mainLine") || !ValidateArrayAccess(mainLine, 1, "mainLine") ||
       !ValidateArrayAccess(signalLine, 0, "signalLine") || !ValidateArrayAccess(signalLine, 1, "signalLine"))
    {
        return;
    }
    
    double prev_main = mainLine[0]; // Bar #2
    double prev_sign = signalLine[0]; // Bar #2
    double curr_main = mainLine[1]; // Bar #1 (most recently closed)
    double curr_sign = signalLine[1]; // Bar #1 (most recently closed)
    
    // Validate indicator values are in reasonable range
    if(prev_main < 0 || prev_main > 100 || curr_main < 0 || curr_main > 100 ||
       prev_sign < 0 || prev_sign > 100 || curr_sign < 0 || curr_sign > 100)
    {
        HandleError(OP_INDICATOR, 0, 
                   StringFormat("Invalid stochastic values: pmain=%.2f, cmain=%.2f, psig=%.2f, csig=%.2f",
                               prev_main, curr_main, prev_sign, curr_sign), false);
        return;
    }

    bool buySignal = (prev_main < prev_sign && curr_main > curr_sign);
    bool sellSignal = (prev_main > prev_sign && curr_main < curr_sign);

    if(buySignal)
    {
        bool closureSuccess = CloseAllSellPositions();
        if(!closureSuccess && accountMode == MODE_HEDGING)
        {
            Print("⚠️ HEDGING MODE WARNING: Failed to close all SELL positions. Skipping BUY entry for safety.");
            return;
        }
        
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
        bool closureSuccess = CloseAllBuyPositions();
        if(!closureSuccess && accountMode == MODE_HEDGING)
        {
            Print("⚠️ HEDGING MODE WARNING: Failed to close all BUY positions. Skipping SELL entry for safety.");
            return;
        }
        
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
    // V20.6 - Don't publish signals when EA is disabled
    if(!on)
    {
        return;
    }
    
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
    if(dealMagic != g_ExpertMagic)
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
                
                // V20.7 - Aeron exit signal publishing (multi-channel)
                if(AeronPublishMode != AERON_PUBLISH_NONE)
                {
                    // V20.7 - Use global Aeron symbol (initialized in OnInit)
                    if(dealReason == DEAL_REASON_TP)
                    {
                        AeronPublishSignalDual(g_AeronSymbol, g_AeronInstrument, AERON_PROFIT_TARGET,
                                          0, 0, 0, 1, 50.0, AeronSourceTag, AeronPublishMode);
                        Print("[AERON_PUB] ✅ ProfitTarget (short): ", g_AeronSymbol);
                    }
                    else
                    {
                        AeronPublishSignalDual(g_AeronSymbol, g_AeronInstrument, AERON_SHORT_STOPLOSS,
                                          0, 0, 0, 1, 50.0, AeronSourceTag, AeronPublishMode);
                        Print("[AERON_PUB] ✅ ShortStopLoss: ", g_AeronSymbol);
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
                
                // V20.7 - Aeron exit signal publishing (multi-channel)
                if(AeronPublishMode != AERON_PUBLISH_NONE)
                {
                    // V20.7 - Use global Aeron symbol (initialized in OnInit)
                    if(dealReason == DEAL_REASON_TP)
                    {
                        AeronPublishSignalDual(g_AeronSymbol, g_AeronInstrument, AERON_PROFIT_TARGET,
                                          0, 0, 0, 1, 50.0, AeronSourceTag, AeronPublishMode);
                        Print("[AERON_PUB] ✅ ProfitTarget (long): ", g_AeronSymbol);
                    }
                    else
                    {
                        AeronPublishSignalDual(g_AeronSymbol, g_AeronInstrument, AERON_LONG_STOPLOSS,
                                          0, 0, 0, 1, 50.0, AeronSourceTag, AeronPublishMode);
                        Print("[AERON_PUB] ✅ LongStopLoss: ", g_AeronSymbol);
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
    
    // CRASH FIX - Reset error before WebRequest (called during OnInit)
    ResetLastError();
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

//+------------------------------------------------------------------+
//| V20.9 - Validate that sessions don't overlap                     |
//+------------------------------------------------------------------+
bool ValidateSessionsNonOverlapping()
{
    if(!session2Enabled)
    {
        return true;  // No validation needed for single session
    }
    
    // Convert both sessions to minutes for comparison
    int session1Start = currentStartHour * 60 + currentStartMinute;
    int session1End = currentEndHour * 60 + currentEndMinute;
    int session2Start = currentStartHour2 * 60 + currentStartMinute2;
    int session2End = currentEndHour2 * 60 + currentEndMinute2;
    
    Print("=== SESSION OVERLAP VALIDATION ===");
    Print("Session 1: ", StringFormat("%02d:%02d", currentStartHour, currentStartMinute), 
          " - ", StringFormat("%02d:%02d", currentEndHour, currentEndMinute),
          " (", session1Start, " - ", session1End, " minutes)");
    Print("Session 2: ", StringFormat("%02d:%02d", currentStartHour2, currentStartMinute2), 
          " - ", StringFormat("%02d:%02d", currentEndHour2, currentEndMinute2),
          " (", session2Start, " - ", session2End, " minutes)");
    
    // Handle overnight sessions (when end < start)
    bool session1_overnight = (session1End < session1Start);
    bool session2_overnight = (session2End < session2Start);
    
    bool overlap = false;
    
    if(!session1_overnight && !session2_overnight)
    {
        // Both sessions are within same day
        // Check if they overlap: (s1.start < s2.end) && (s2.start < s1.end)
        overlap = (session1Start < session2End) && (session2Start < session1End);
    }
    else if(session1_overnight && !session2_overnight)
    {
        // Session 1 crosses midnight, session 2 doesn't
        // Session 1 spans [session1Start, 1440) and [0, session1End)
        // Check if session 2 falls within either range
        overlap = (session2Start >= session1Start) || (session2End <= session1End);
    }
    else if(!session1_overnight && session2_overnight)
    {
        // Session 2 crosses midnight, session 1 doesn't
        // Session 2 spans [session2Start, 1440) and [0, session2End)
        // Check if session 1 falls within either range
        overlap = (session1Start >= session2Start) || (session1End <= session2End);
    }
    else
    {
        // Both sessions cross midnight - they will always overlap
        overlap = true;
    }
    
    if(overlap)
    {
        Print("❌ SESSION OVERLAP DETECTED ❌");
        Print("Session 1 and Session 2 have overlapping time ranges!");
        Print("Please adjust the session times to avoid conflicts.");
        Print("Disabling Session 2 for safety...");
        
        if(ShowAlerts)
        {
            Alert("⚠️ SESSION OVERLAP ERROR");
            Alert("Session 1: ", StringFormat("%02d:%02d-%02d:%02d", 
                  currentStartHour, currentStartMinute, currentEndHour, currentEndMinute));
            Alert("Session 2: ", StringFormat("%02d:%02d-%02d:%02d", 
                  currentStartHour2, currentStartMinute2, currentEndHour2, currentEndMinute2));
            Alert("Please adjust times to avoid overlap. Session 2 disabled.");
        }
        
        session2Enabled = false;
        return false;
    }
    
    Print("✅ Sessions validated: No overlap detected");
    return true;
}

/**
 * @brief Checks if the current time is within the allowed trading hours (API-enhanced)
 * @details V20.9 - Enhanced to support dual sessions in manual mode
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
    
    // Session 1 check
    int startMinutes1 = currentStartHour * 60 + currentStartMinute;
    int endMinutes1 = currentEndHour * 60 + currentEndMinute;

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
        Print("Session 1: ", StringFormat("%02d:%02d", currentStartHour, currentStartMinute), 
              " - ", StringFormat("%02d:%02d", currentEndHour, currentEndMinute),
              " (", startMinutes1, " - ", endMinutes1, " minutes)");
        
        if(session2Enabled)
        {
            int startMinutes2 = currentStartHour2 * 60 + currentStartMinute2;
            int endMinutes2 = currentEndHour2 * 60 + currentEndMinute2;
            Print("Session 2: ", StringFormat("%02d:%02d", currentStartHour2, currentStartMinute2), 
                  " - ", StringFormat("%02d:%02d", currentEndHour2, currentEndMinute2),
                  " (", startMinutes2, " - ", endMinutes2, " minutes)");
        }
        else
        {
            Print("Session 2: DISABLED");
        }
        
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

    // Check Session 1
    bool withinSession1 = false;
    if(startMinutes1 < endMinutes1)
    {
        withinSession1 = (estMinutes >= startMinutes1 && estMinutes < endMinutes1);
    }
    else if(startMinutes1 > endMinutes1)
    {
        // Overnight session
        withinSession1 = (estMinutes >= startMinutes1 || estMinutes < endMinutes1);
    }
    
    // Check Session 2 (if enabled)
    bool withinSession2 = false;
    if(session2Enabled)
    {
        int startMinutes2 = currentStartHour2 * 60 + currentStartMinute2;
        int endMinutes2 = currentEndHour2 * 60 + currentEndMinute2;
        
        if(startMinutes2 < endMinutes2)
        {
            withinSession2 = (estMinutes >= startMinutes2 && estMinutes < endMinutes2);
        }
        else if(startMinutes2 > endMinutes2)
        {
            // Overnight session
            withinSession2 = (estMinutes >= startMinutes2 || estMinutes < endMinutes2);
        }
    }
    
    // Trading allowed if within either session
    bool withinHours = withinSession1 || withinSession2;
    
    static bool lastStatus = false;
    if(withinHours != lastStatus)
    {
        if(withinSession1 && withinSession2)
        {
            Print("Trading hours status changed: ALLOWED (both sessions active!)");
        }
        else if(withinSession1)
        {
            Print("Trading hours status changed: ALLOWED (session 1)");
        }
        else if(withinSession2)
        {
            Print("Trading hours status changed: ALLOWED (session 2)");
        }
        else
        {
            Print("Trading hours status changed: NOT ALLOWED");
        }
        lastStatus = withinHours;
    }
    
    return withinHours;
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
        scalpBuyTicket = trade.ResultOrder();
        scalpBuyOpened = true;
        Print("Scalp Buy Opened: #", scalpBuyTicket);
        if(ShowAlerts) Alert("Scalp BUY Order Success for ", _Symbol, " - Ticket: #", scalpBuyTicket);
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
        trendBuyTicket = trade.ResultOrder();
        trendBuyOpened = true;
        Print("Trend Buy Opened: #", trendBuyTicket);
        if(ShowAlerts) Alert("Trend BUY Order Success for ", _Symbol, " - Ticket: #", trendBuyTicket);
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
    if(AeronPublishMode != AERON_PUBLISH_NONE && (scalpBuyOpened || trendBuyOpened))
    {
        // V20.7 - Use global Aeron symbol and convert points to ticks
        
        // Calculate confidence based on stochastic values
        double mainBuffer[3], signalBuffer[3];

        float confidence = 80.0;
        if(SafeCopyBuffer(stochHandle, 0, 0, 3, mainBuffer, OP_INDICATOR) &&
           SafeCopyBuffer(stochHandle, 1, 0, 3, signalBuffer, OP_INDICATOR))
        {
            double K = mainBuffer[0];
            double D = signalBuffer[0];
            confidence = (float)MathMin(50.0 + MathAbs(K - D), 95.0);
        }
        else
        {
            Print("Warning: Could not read stochastic for confidence calculation");
        }

        // V20.7 - Convert MT5 points to futures ticks
        int slTicks = ConvertPointsToFuturesTicks(SL, g_AeronSymbol);
        int profitOffsetPoints = (int)(TP * 0.4);
        int profitTicks = ConvertPointsToFuturesTicks(SL + profitOffsetPoints, g_AeronSymbol);

        // Publish LongEntry1 (stop loss only)
        bool pub1 = AeronPublishSignalDual(
            g_AeronSymbol,
            g_AeronInstrument,
            AERON_LONG_ENTRY1,
            slTicks,
            0,
            0,
            1,
            confidence,
            AeronSourceTag,
            AeronPublishMode
        );

        if(pub1)
        {
            PrintFormat("[AERON_PUB] ✅ LongEntry1: %s SL=%d ticks (%d pts) qty=1 conf=%.1f", 
                        g_AeronSymbol, slTicks, SL, confidence);
        }

        // Publish LongEntry2 (stop loss + profit target)
        bool pub2 = AeronPublishSignalDual(
            g_AeronSymbol,
            g_AeronInstrument,
            AERON_LONG_ENTRY2,
            slTicks,
            0,
            profitTicks,
            1,
            confidence,
            AeronSourceTag,
            AeronPublishMode
        );

        if(pub2)
        {
            PrintFormat("[AERON_PUB] ✅ LongEntry2: %s SL=%d TP=%d ticks (%d/%d pts) qty=1 conf=%.1f",
                        g_AeronSymbol, slTicks, profitTicks, SL, SL + profitOffsetPoints, confidence);
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
        scalpSellTicket = trade.ResultOrder();
        scalpSellOpened = true;
        Print("Scalp Sell Opened: #", scalpSellTicket);
        if(ShowAlerts) Alert("Scalp SELL Order Success for ", _Symbol, " - Ticket: #", scalpSellTicket);
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
        trendSellTicket = trade.ResultOrder();
        trendSellOpened = true;
        Print("Trend Sell Opened: #", trendSellTicket);
        if(ShowAlerts) Alert("Trend SELL Order Success for ", _Symbol, " - Ticket: #", trendSellTicket);
    }
    else if(trendLot > 0)
    {
        if(ShowAlerts) Alert("Trend SELL Order Failed for ", _Symbol, " - Error: ", GetLastError());
        Print("=== TREND SELL ORDER FAILURE ===");
        Print("Error Code: ", GetLastError());
        Print("RetCode: ", trade.ResultRetcode());
    }

    // ===============================================
    // V20.7 - Aeron Binary Signal Publishing (Multi-Channel) - AFTER successful trades
    // ===============================================
    if(AeronPublishMode != AERON_PUBLISH_NONE && (scalpSellOpened || trendSellOpened))
    {
        // V20.7 - Use global Aeron symbol and convert points to ticks

        double mainBuffer[3], signalBuffer[3];

        float confidence = 80.0;
        if(SafeCopyBuffer(stochHandle, 0, 0, 3, mainBuffer, OP_INDICATOR) &&
           SafeCopyBuffer(stochHandle, 1, 0, 3, signalBuffer, OP_INDICATOR))
        {
            double K = mainBuffer[0];
            double D = signalBuffer[0];
            confidence = (float)MathMin(50.0 + MathAbs(K - D), 95.0);
        }
        else
        {
            Print("Warning: Could not read stochastic for confidence calculation");
        }

        // V20.7 - Convert MT5 points to futures ticks
        int slTicks = ConvertPointsToFuturesTicks(SL, g_AeronSymbol);
        int profitOffsetPoints = (int)(TP * 0.4);
        int profitTicks = ConvertPointsToFuturesTicks(SL + profitOffsetPoints, g_AeronSymbol);

        // Publish ShortEntry1 (stop loss only)
        bool pub1 = AeronPublishSignalDual(
            g_AeronSymbol,
            g_AeronInstrument,
            AERON_SHORT_ENTRY1,
            0,
            slTicks,
            0,
            1,
            confidence,
            AeronSourceTag,
            AeronPublishMode
        );

        if(pub1)
        {
            PrintFormat("[AERON_PUB] ✅ ShortEntry1: %s SL=%d ticks (%d pts) qty=1 conf=%.1f", 
                        g_AeronSymbol, slTicks, SL, confidence);
        }

        // Publish ShortEntry2 (stop loss + profit target)
        bool pub2 = AeronPublishSignalDual(
            g_AeronSymbol,
            g_AeronInstrument,
            AERON_SHORT_ENTRY2,
            0,
            slTicks,
            profitTicks,
            1,
            confidence,
            AeronSourceTag,
            AeronPublishMode
        );

        if(pub2)
        {
            PrintFormat("[AERON_PUB] ✅ ShortEntry2: %s SL=%d TP=%d ticks (%d/%d pts) qty=1 conf=%.1f",
                        g_AeronSymbol, slTicks, profitTicks, SL, SL + profitOffsetPoints, confidence);
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
    if(!SafeCopyBuffer(stochHandle, 0, 1, 2, immediateMainLine, OP_INDICATOR) ||
       !SafeCopyBuffer(stochHandle, 1, 1, 2, immediateSignalLine, OP_INDICATOR))
    {
        Print("Immediate entry failed: Could not get indicator data safely.");
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
               PositionGetInteger(POSITION_MAGIC) == g_ExpertMagic)
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
                   PositionGetInteger(POSITION_MAGIC) == g_ExpertMagic)
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

//+------------------------------------------------------------------+
//| V20.5 - Enhanced Position Closure with Retry Logic              |
//+------------------------------------------------------------------+

/**
 * @brief Closes a position with retry logic and exponential backoff
 * @param ticket Position ticket to close
 * @param positionName Human-readable position name for logging
 * @param maxRetries Maximum number of closure attempts
 * @return true if position closed successfully, false otherwise
 */
bool ClosePositionWithRetry(ulong ticket, string positionName, int maxRetries = 5)
{
    if(ticket == 0)
    {
        Print("Cannot close ", positionName, " - invalid ticket (0)");
        return true;  // Consider this success to avoid blocking
    }
    
    // Check if position still exists
    if(!PositionExistsByTicket(ticket))
    {
        Print(positionName, " position #", ticket, " already closed or doesn't exist");
        return true;
    }
    
    int attempt = 0;
    int delay = ClosureRetryDelay;
    
    while(attempt < maxRetries)
    {
        attempt++;
        Print("Attempting to close ", positionName, " #", ticket, " (Attempt ", attempt, "/", maxRetries, ")");
        
        // Attempt to close position
        if(trade.PositionClose(ticket))
        {
            Print("✅ SUCCESS: ", positionName, " #", ticket, " closed on attempt ", attempt);
            
            // Verify closure
            Sleep(50);  // Brief pause to allow server confirmation
            if(!PositionExistsByTicket(ticket))
            {
                Print("✅ CONFIRMED: ", positionName, " #", ticket, " closure verified");
                return true;
            }
            else
            {
                Print("⚠️ WARNING: Close request accepted but position still exists. Retrying...");
            }
        }
        else
        {
            int errorCode = GetLastError();
            uint retCode = trade.ResultRetcode();
            
            Print("❌ FAILED: ", positionName, " #", ticket, " close attempt ", attempt, " failed");
            Print("   Error Code: ", errorCode, " | RetCode: ", retCode);
            Print("   Description: ", trade.ResultRetcodeDescription());
        }
        
        // Exponential backoff delay
        if(attempt < maxRetries)
        {
            Print("   Waiting ", delay, "ms before retry...");
            Sleep(delay);
            delay = (int)(delay * 1.5);  // Exponential backoff
        }
    }
    
    // Final verification
    if(!PositionExistsByTicket(ticket))
    {
        Print("✅ Position ", positionName, " #", ticket, " no longer exists (closed externally?)");
        return true;
    }
    
    Print("❌ EXHAUSTED: Failed to close ", positionName, " #", ticket, " after ", maxRetries, " attempts");
    return false;
}

/**
 * @brief Closes all buy positions with enhanced hedging mode support
 * @return true if all positions closed successfully, false otherwise
 */
bool CloseAllBuyPositions()
{
    Print("=== CLOSING ALL BUY POSITIONS ===");
    Print("Account Mode: ", (accountMode == MODE_HEDGING ? "HEDGING" : "NETTING"));
    Print("Symbol: ", _Symbol, " | Magic: ", g_ExpertMagic);
    
    bool allClosed = true;
    
    // Close scalp buy position
    if(scalpBuyOpened && scalpBuyTicket != 0)
    {
        if(!ClosePositionWithRetry(scalpBuyTicket, "Scalp Buy", MaxClosureRetries))
        {
            allClosed = false;
            Print("⚠️ WARNING: Scalp Buy #", scalpBuyTicket, " closure incomplete");
        }
        else
        {
            scalpBuyOpened = false;
            scalpBuyTicket = 0;
        }
    }
    
    // Close trend buy position
    if(trendBuyOpened && trendBuyTicket != 0)
    {
        if(!ClosePositionWithRetry(trendBuyTicket, "Trend Buy", MaxClosureRetries))
        {
            allClosed = false;
            Print("⚠️ WARNING: Trend Buy #", trendBuyTicket, " closure incomplete");
        }
        else
        {
            trendBuyOpened = false;
            trendBuyTicket = 0;
        }
    }
    
    // V20.5: In hedging mode, scan for any remaining buy positions with our magic number
    if(accountMode == MODE_HEDGING)
    {
        int buyCount = CountPositionsByTypeAndSymbol(POSITION_TYPE_BUY);
        
        if(buyCount > 0)
        {
            Print("⚠️ HEDGING MODE: Found ", buyCount, " additional buy position(s) for ", _Symbol);
            
            // Close any remaining buy positions
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
                if(PositionGetSymbol(i) == _Symbol)
                {
                    ulong posMagic = PositionGetInteger(POSITION_MAGIC);
                    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                    ulong posTicket = PositionGetInteger(POSITION_TICKET);
                    
                    if(posMagic == g_ExpertMagic && posType == POSITION_TYPE_BUY)
                    {
                        Print("Found orphaned buy position #", posTicket, " - attempting closure");
                        if(!ClosePositionWithRetry(posTicket, "Orphaned Buy", MaxClosureRetries))
                        {
                            allClosed = false;
                        }
                    }
                }
            }
        }
    }
    
    // Final verification
    int finalBuyCount = CountPositionsByTypeAndSymbol(POSITION_TYPE_BUY);
    
    if(finalBuyCount == 0)
    {
        Print("✅ SUCCESS: All buy positions closed for ", _Symbol);
        scalpBuyOpened = false;
        scalpBuyTicket = 0;
        trendBuyOpened = false;
        trendBuyTicket = 0;
        return true;
    }
    else
    {
        Print("⚠️ WARNING: ", finalBuyCount, " buy position(s) still open for ", _Symbol);
        return false;
    }
}

/**
 * @brief Closes all sell positions with enhanced hedging mode support
 * @return true if all positions closed successfully, false otherwise
 */
bool CloseAllSellPositions()
{
    Print("=== CLOSING ALL SELL POSITIONS ===");
    Print("Account Mode: ", (accountMode == MODE_HEDGING ? "HEDGING" : "NETTING"));
    Print("Symbol: ", _Symbol, " | Magic: ", g_ExpertMagic);
    
    bool allClosed = true;
    
    // Close scalp sell position
    if(scalpSellOpened && scalpSellTicket != 0)
    {
        if(!ClosePositionWithRetry(scalpSellTicket, "Scalp Sell", MaxClosureRetries))
        {
            allClosed = false;
            Print("⚠️ WARNING: Scalp Sell #", scalpSellTicket, " closure incomplete");
        }
        else
        {
            scalpSellOpened = false;
            scalpSellTicket = 0;
        }
    }
    
    // Close trend sell position
    if(trendSellOpened && trendSellTicket != 0)
    {
        if(!ClosePositionWithRetry(trendSellTicket, "Trend Sell", MaxClosureRetries))
        {
            allClosed = false;
            Print("⚠️ WARNING: Trend Sell #", trendSellTicket, " closure incomplete");
        }
        else
        {
            trendSellOpened = false;
            trendSellTicket = 0;
        }
    }
    
    // V20.5: In hedging mode, scan for any remaining sell positions with our magic number
    if(accountMode == MODE_HEDGING)
    {
        int sellCount = CountPositionsByTypeAndSymbol(POSITION_TYPE_SELL);
        
        if(sellCount > 0)
        {
            Print("⚠️ HEDGING MODE: Found ", sellCount, " additional sell position(s) for ", _Symbol);
            
            // Close any remaining sell positions
            for(int i = PositionsTotal() - 1; i >= 0; i--)
            {
                if(PositionGetSymbol(i) == _Symbol)
                {
                    ulong posMagic = PositionGetInteger(POSITION_MAGIC);
                    ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                    ulong posTicket = PositionGetInteger(POSITION_TICKET);
                    
                    if(posMagic == g_ExpertMagic && posType == POSITION_TYPE_SELL)
                    {
                        Print("Found orphaned sell position #", posTicket, " - attempting closure");
                        if(!ClosePositionWithRetry(posTicket, "Orphaned Sell", MaxClosureRetries))
                        {
                            allClosed = false;
                        }
                    }
                }
            }
        }
    }
    
    // Final verification
    int finalSellCount = CountPositionsByTypeAndSymbol(POSITION_TYPE_SELL);
    
    if(finalSellCount == 0)
    {
        Print("✅ SUCCESS: All sell positions closed for ", _Symbol);
        scalpSellOpened = false;
        scalpSellTicket = 0;
        trendSellOpened = false;
        trendSellTicket = 0;
        return true;
    }
    else
    {
        Print("⚠️ WARNING: ", finalSellCount, " sell position(s) still open for ", _Symbol);
        return false;
    }
}

bool CheckDailyLossLimit()
{
    static datetime lastResetTime = 0;
    MqlDateTime dt;
    
    // Safe time structure retrieval
    ResetLastError();
    if(!TimeCurrent(dt))
    {
        HandleError(OP_CALCULATION, GetLastError(), "Failed to get current time", false);
        return false;
    }
    
    // Safe account balance retrieval
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(currentBalance <= 0)
    {
        HandleError(OP_CALCULATION, 0, 
                   StringFormat("Invalid account balance: %.2f", currentBalance), false);
        return false;
    }
    
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

    if(stopTradingForDay) return true;
    
    // Reuse currentBalance from earlier in function
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // Validate account values
    if(currentBalance <= 0 || currentEquity <= 0)
    {
        HandleError(OP_CALCULATION, 0, 
                   StringFormat("Invalid account values: balance=%.2f, equity=%.2f", 
                               currentBalance, currentEquity), false);
        return false;
    }
    
    double floatingLoss = MathMax(0, currentBalance - currentEquity);
    double realizedLoss = MathMax(0, todayStartingBalance - currentBalance);
    double totalLoss = realizedLoss + floatingLoss;
    
    if(totalLoss > 0 && todayStartingBalance > 0)
    {
        // Safe division for loss percentage
        double lossPercentage = SafeDivide(totalLoss * 100.0, todayStartingBalance, 0.0);
        
        if(lossPercentage >= MAX_DAILY_LOSS_PERCENTAGE)
        {
            stopTradingForDay = true;
            Print("!!! DAILY LOSS LIMIT of ", MAX_DAILY_LOSS_PERCENTAGE, "% REACHED. No new trades today. !!!");
            if(ShowAlerts)
            {
                Alert(StringFormat("DAILY LOSS LIMIT: %.2f%% loss detected. Trading stopped.", lossPercentage));
            }
        }
    }
    
    return true;
}

bool CheckDailyProfitProtection()
{
    if(stopTradingForProfitProtection) return true;
    
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    // Validate account values
    if(currentBalance <= 0 || currentEquity <= 0)
    {
        HandleError(OP_CALCULATION, 0, 
                   StringFormat("Invalid account values in profit protection: balance=%.2f, equity=%.2f", 
                               currentBalance, currentEquity), false);
        return false;
    }
    
    double currentProfitAmount = currentEquity - todayStartingBalance;
   double currentProfitPercentage = 0.0;
    
    if(todayStartingBalance > 0)
    {
        // Safe division for profit percentage
        currentProfitPercentage = SafeDivide(currentProfitAmount * 100.0, todayStartingBalance, 0.0);
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
    
    return true;
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

//+------------------------------------------------------------------+
//| V20.7 - Exception Handling Function Implementations              |
//+------------------------------------------------------------------+

/**
 * @brief Centralized error handler with detailed logging
 * @param context Operation context where error occurred
 * @param errorCode MT5 error code
 * @param message Custom error message
 * @param isCritical Whether this error should halt the EA
 */
void HandleError(OPERATION_CONTEXT context, int errorCode, string message, bool isCritical = false)
{
    string contextName = "";
    switch(context)
    {
        case OP_INIT: contextName = "INITIALIZATION"; break;
        case OP_TICK: contextName = "ONTICK"; break;
        case OP_INDICATOR: contextName = "INDICATOR"; break;
        case OP_TRADE: contextName = "TRADE"; break;
        case OP_WEBREQUEST: contextName = "WEBREQUEST"; break;
        case OP_DLL_CALL: contextName = "DLL_CALL"; break;
        case OP_ARRAY_OP: contextName = "ARRAY_OPERATION"; break;
        case OP_CALCULATION: contextName = "CALCULATION"; break;
        case OP_AERON_PUBLISH: contextName = "AERON_PUBLISH"; break;
    }
    
    string fullMessage = StringFormat("[ERROR:%s] Code:%d | %s", contextName, errorCode, message);
    Print(fullMessage);
    
    // Track consecutive errors
    if(TimeCurrent() - g_lastErrorTime < 5) // Within 5 seconds of last error
    {
        g_consecutiveErrors++;
    }
    else
    {
        g_consecutiveErrors = 1;
    }
    
    g_lastErrorTime = TimeCurrent();
    g_lastErrorMessage = message;
    
    // Critical error handling
    if(isCritical)
    {
        g_criticalErrorDetected = true;
        string alertMsg = StringFormat("CRITICAL ERROR in %s: %s (Code: %d)", contextName, message, errorCode);
        Print("========================================");
        Print(alertMsg);
        Print("EA will stop trading to prevent further issues");
        Print("========================================");
        if(ShowAlerts) Alert(alertMsg);
    }
    
    // Too many consecutive errors
    if(g_consecutiveErrors >= g_maxConsecutiveErrors)
    {
        g_criticalErrorDetected = true;
        string alertMsg = StringFormat("TOO MANY ERRORS (%d consecutive): Last error: %s", 
                                      g_consecutiveErrors, message);
        Print("========================================");
        Print(alertMsg);
        Print("EA will stop trading for safety");
        Print("========================================");
        if(ShowAlerts) Alert(alertMsg);
    }
}

/**
 * @brief Safe wrapper for CopyBuffer with validation
 * @return true if successful, false otherwise
 */
bool SafeCopyBuffer(int indicator_handle, int buffer_num, int start_pos, int count, 
                   double &buffer[], OPERATION_CONTEXT context = OP_INDICATOR)
{
    if(indicator_handle == INVALID_HANDLE)
    {
        HandleError(context, 4801,  // Invalid indicator handle
                   "Invalid indicator handle in SafeCopyBuffer", false);
        return false;
    }
    
    if(count <= 0 || count > 10000)
    {
        HandleError(context, 4003,  // Invalid parameter
                   StringFormat("Invalid buffer count: %d", count), false);
        return false;
    }
    
    ResetLastError();
    int copied = CopyBuffer(indicator_handle, buffer_num, start_pos, count, buffer);
    int error = GetLastError();
    
    if(copied <= 0 || error != 0)
    {
        HandleError(context, error, 
                   StringFormat("CopyBuffer failed: handle=%d, buffer_num=%d, copied=%d", 
                               indicator_handle, buffer_num, copied), false);
        return false;
    }
    
    // Validate buffer values
    for(int i = 0; i < copied; i++)
    {
        if(buffer[i] != buffer[i]) // NaN check
        {
            HandleError(context, 0, 
                       StringFormat("NaN detected in buffer at index %d", i), false);
            return false;
        }
    }
    
    return true;
}

/**
 * @brief Safe wrapper for StringToCharArray with bounds checking
 */
bool SafeStringToCharArray(string str, uchar &array[], int start, int count)
{
    if(count < 0 || count > ArraySize(array))
    {
        HandleError(OP_ARRAY_OP, 4002, 
                   StringFormat("Invalid StringToCharArray bounds: size=%d, count=%d", 
                               ArraySize(array), count), false);
        return false;
    }
    
    if(StringLen(str) > ArraySize(array) - 1)
    {
        HandleError(OP_ARRAY_OP, 4002, 
                   StringFormat("String too long for buffer: str_len=%d, array_size=%d", 
                               StringLen(str), ArraySize(array)), false);
        return false;
    }
    
    ResetLastError();
    int result = StringToCharArray(str, array, start, count);
    int error = GetLastError();
    
    if(result < 0 || error != 0)
    {
        HandleError(OP_ARRAY_OP, error, "StringToCharArray failed", false);
        return false;
    }
    
    return true;
}

/**
 * @brief Safe division with zero check
 */
double SafeDivide(double numerator, double denominator, double defaultValue = 0.0)
{
    if(MathAbs(denominator) < 0.0000001) // Practically zero
    {
        HandleError(OP_CALCULATION, 0, 
                   StringFormat("Division by zero attempted: %.8f / %.8f", numerator, denominator), 
                   false);
        return defaultValue;
    }
    return numerator / denominator;
}

/**
 * @brief Validate array access before use
 */
bool ValidateArrayAccess(const double &array[], int index, string arrayName = "")
{
    int size = ArraySize(array);
    if(index < 0 || index >= size)
    {
        HandleError(OP_ARRAY_OP, 4003, 
                   StringFormat("Array bounds violation: %s[%d], size=%d", 
                               arrayName, index, size), false);
        return false;
    }
    return true;
}

/**
 * @brief Safe WebRequest wrapper with retry logic
 */
bool SafeWebRequest(string method, string url, string headers, int timeout,
                   const char &data[], char &result[], string &resultHeaders,
                   int &httpCode, int maxRetries = 3)
{
    for(int attempt = 0; attempt < maxRetries; attempt++)
    {
        ResetLastError();
        httpCode = WebRequest(method, url, headers, timeout, data, result, resultHeaders);
        int error = GetLastError();
        
        if(httpCode > 0 && error == 0)
        {
            // Reset error counter on success
            if(g_consecutiveErrors > 0) g_consecutiveErrors = 0;
            return true;
        }
        
        // Log attempt
        Print(StringFormat("[WEBREQUEST] Attempt %d/%d failed: HTTP=%d, Error=%d", 
                          attempt + 1, maxRetries, httpCode, error));
        
        // Don't retry on configuration errors
        if(error == 5200 ||  // WebRequest invalid address
           error == 5203)    // WebRequest request failed
        {
            HandleError(OP_WEBREQUEST, error, 
                       StringFormat("WebRequest configuration error for URL: %s", url), false);
            break;
        }
        
        // Wait before retry (exponential backoff)
        if(attempt < maxRetries - 1)
        {
            Sleep((int)MathPow(2, attempt) * 1000);
        }
    }
    
    HandleError(OP_WEBREQUEST, GetLastError(), 
               StringFormat("WebRequest failed after %d attempts: %s", maxRetries, url), false);
    return false;
}

/**
 * @brief Check if EA should continue operating
 */
bool IsSafeToOperate()
{
    if(g_criticalErrorDetected)
    {
        static datetime lastWarning = 0;
        if(TimeCurrent() - lastWarning > 60) // Print warning every minute
        {
            Print("[SAFE_MODE] EA halted due to critical error. Restart required.");
            lastWarning = TimeCurrent();
        }
        return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| V20.7 - Convert MT5 Points to Futures Ticks                      |
//+------------------------------------------------------------------+

/**
 * @brief Converts MT5 forex points to futures ticks based on symbol
 * @param points Number of points in MT5 (e.g., SL=50 means 50 points = 0.00050)
 * @param futuresSymbol Futures symbol (e.g., "6A", "ES", "NQ")
 * @return Number of ticks for the futures contract
 * 
 * MT5 Forex standard: 1 point = 0.00001 (5 decimal places)
 * Futures tick sizes vary by contract (see CME specs)
 * 
 * Examples:
 * - AUDUSD 50 points → 6A: 10 ticks (0.00050 / 0.00005 = 10)
 * - EURUSD 50 points → 6E: 10 ticks (0.00050 / 0.00005 = 10)
 */
int ConvertPointsToFuturesTicks(int points, string futuresSymbol)
{
   // Input validation
   if(points < 0)
   {
      HandleError(OP_CALCULATION, 0, 
                 StringFormat("Invalid point value: %d", points), false);
      return 0;
   }
   
   // MT5 forex point size (standard for all major pairs)
   double forexPointSize = 0.00001;  // 5 decimal places
   
   // Futures tick sizes (from CME specifications)
   double futuresTickSize = 0.00005;  // Default fallback
   
   // CME Currency Futures (micro contracts)
   if(futuresSymbol == "6A")      futuresTickSize = 0.00005;  // Australian Dollar
   else if(futuresSymbol == "6B") futuresTickSize = 0.00005;  // British Pound
   else if(futuresSymbol == "6C") futuresTickSize = 0.00005;  // Canadian Dollar
   else if(futuresSymbol == "6E") futuresTickSize = 0.00005;  // Euro
   else if(futuresSymbol == "6J") futuresTickSize = 0.0000050;// Japanese Yen
   else if(futuresSymbol == "6N") futuresTickSize = 0.00005;  // New Zealand Dollar
   else if(futuresSymbol == "6S") futuresTickSize = 0.00005;  // Swiss Franc
   
   // CME Equity Index Futures
   else if(futuresSymbol == "ES") futuresTickSize = 0.25;     // E-mini S&P 500
   else if(futuresSymbol == "NQ") futuresTickSize = 0.25;     // E-mini NASDAQ
   else if(futuresSymbol == "YM") futuresTickSize = 1.0;      // E-mini Dow
   else if(futuresSymbol == "RTY") futuresTickSize = 0.10;    // E-mini Russell 2000
   
   // If unknown symbol, log warning and use default
   else
   {
      Print("WARNING: Unknown futures symbol '", futuresSymbol, "' - using default tick size 0.00005");
   }
   
   // Convert: (points * pointSize) / tickSize
   double pointsInPrice = points * forexPointSize;
   int ticks = (int)MathRound(pointsInPrice / futuresTickSize);
   
   return ticks;
}