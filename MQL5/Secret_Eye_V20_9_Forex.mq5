//+------------------------------------------------------------------+
//|           Stochastic Straight Algo Strategy V20.9 FOREX         |
//|                                  Copyright 2025, Sanjeevas Inc.  |
//|                                             https://www.sanjeevas.com|
//+------------------------------------------------------------------+

// V20.9 FOREX Edition - Signal Reversal for USD Base Pairs:
// - Added SignalReversal input parameter to reverse published signals
// - When enabled, long positions on USDCHF publish as short signals (for 6S_F futures)
// - When enabled, short positions on USDCHF publish as long signals (for 6S_F futures)
// - Applies to all USD base currency pairs (USDCHF, USDJPY, USDCAD, etc.)
// - Actual MT5 trades remain unchanged - only the published signal direction is reversed
// - Enhanced logging shows both actual trade direction and published signal direction
// - Configurable per EA instance for maximum flexibility
//
// Use Cases:
// - Trading USDCHF spot but signaling 6S (Swiss Franc) futures (inverse relationship)
// - Trading USDJPY spot but signaling 6J (Yen) futures (inverse relationship)
// - Trading USDCAD spot but signaling 6C (Canadian Dollar) futures (inverse relationship)
// - Any scenario where base/quote currency inversion requires signal reversal
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

#property copyright "Copyright 2025, Sanjeevas Inc."
#property link      "https://www.sanjeevas.com"
#property version   "20.90"
#property description "V20.9 FOREX - Signal Reversal for USD Base Pairs + Exception Handling"
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
input int               ManualStartTime = 0;            // Fallback start time (hour)
input int               ManualStartMinute = 0;          // Fallback start time (minute)
input int               ManualEndTime = 23;             // Fallback end time (hour)
input int               ManualEndMinute = 0;            // Fallback end time (minute)

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
input string            AeronSourceTag = "SecretEye_V20_9_Forex"; // Source strategy identifier
input string            AeronInstrumentName = "";          // Custom symbol/instrument name for Aeron (e.g. "6S") - sets both fields

input group             "Forex Signal Reversal (V20.9)"
input bool              SignalReversal = false;         // Reverse signal direction (for USD base pairs like USDCHF -> 6S_F)
input string            SignalReversalNote = "Enable for: USDCHF->6S, USDJPY->6J, USDCAD->6C"; // Guide: When to use

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
int ParseTopicNames(string topicInput, string &topics[]);
bool PublishJSONToMultipleTopics(char &buffer[], string baseTopic, string topicSuffix);
string EscapeJsonString(string str);
void CleanupAeronPublishersForce();

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // V20.7 - Crash-loop detection and prevention
    datetime now = TimeCurrent();
    if(now - g_lastInitTime < 10)
    {
        g_initCount++;
        if(g_initCount > g_maxInitPer10Sec)
        {
            Print("=== CRITICAL: EA restarting too frequently (", g_initCount, " times in 10 seconds) ===");
            Print("Possible crash loop detected. Please check logs for errors.");
            Print("Initialization blocked to prevent system instability.");
            return(INIT_FAILED);
        }
    }
    else
    {
        g_initCount = 1;
    }
    g_lastInitTime = now;

    Print("=== Secret Eye V20.9 FOREX Initialization ===");
    PrintFormat("Signal Reversal: %s", SignalReversal ? "ENABLED (signals will be inverted)" : "DISABLED (normal signal direction)");
    if(SignalReversal)
    {
        Print("⚠️  WARNING: Signal reversal is ACTIVE. Long trades will publish SHORT signals, short trades will publish LONG signals.");
        Print("    This is typically used when trading USD base pairs (USDCHF) but signaling futures (6S_F).");
    }

    // V20.8.3 - Force cleanup any orphaned Aeron publishers from previous EA instance
    Print("=== V20.8.3 - Performing forced cleanup of any orphaned Aeron publishers ===");
    CleanupAeronPublishersForce();
    Sleep(200);  // Critical: Allow DLL to fully release resources before re-initialization
    
    // Reset state tracking
    g_AeronIpcStarted = false;
    g_AeronUdpStarted = false;
    
    // Initialize stochastic indicator
    stochHandle = iStochastic(_Symbol, timeFrame, K_Period, D_Period, slowing, MODE_SMA, STO_LOWHIGH);
    if(stochHandle == INVALID_HANDLE)
    {
        HandleError(OP_INIT, GetLastError(), "Failed to initialize Stochastic indicator", true);
        return(INIT_FAILED);
    }
    
    // V20.5 - Detect account margin mode
    accountMode = DetectAccountMarginMode();
    if(accountMode == MODE_HEDGING)
    {
        hedgingModeDetected = true;
        Print("Account mode: HEDGING (multiple positions per symbol allowed)");
    }
    else if(accountMode == MODE_NETTING)
    {
        Print("Account mode: NETTING (one position per symbol)");
    }
    else
    {
        Print("Account mode: UNKNOWN (unable to determine)");
    }
    
    // Set unique expert magic
    datetime createdDate = (datetime)D'2025.01.01';
    g_ExpertMagic = (ulong)((createdDate / 86400) + digital_name_ + code_interaction_);
    trade.SetExpertMagicNumber(g_ExpertMagic);
    PrintFormat("Expert Magic Number: %llu", g_ExpertMagic);
    
    // V20 - Detect server offset
    detectedServerOffset = DetectBrokerServerOffset();
    
    // V20 - Fetch trading hours from API
    if(UseAPITradingHours)
    {
        if(FetchTradingHoursFromAPI())
        {
            SetTradingHoursForToday();
            PrintFormat("Trading hours set: %02d:%02d to %02d:%02d ET", 
                        currentStartHour, currentStartMinute, currentEndHour, currentEndMinute);
        }
        else
        {
            currentStartHour = ManualStartTime;
            currentStartMinute = ManualStartMinute;
            currentEndHour = ManualEndTime;
            currentEndMinute = ManualEndMinute;
            PrintFormat("Using manual trading hours: %02d:%02d to %02d:%02d", 
                        currentStartHour, currentStartMinute, currentEndHour, currentEndMinute);
        }
    }
    else
    {
        currentStartHour = ManualStartTime;
        currentStartMinute = ManualStartMinute;
        currentEndHour = ManualEndTime;
        currentEndMinute = ManualEndMinute;
        PrintFormat("API disabled. Using manual trading hours: %02d:%02d to %02d:%02d", 
                    currentStartHour, currentStartMinute, currentEndHour, currentEndMinute);
    }
    
    // V20.1 - Initialize daily profit/loss tracking via CheckDailyLossLimit
    // This ensures both loss protection AND profit protection are properly initialized
    if(!CheckDailyLossLimit())
    {
        HandleError(OP_INIT, 0, "Failed to initialize daily loss/profit protection", false);
    }
    Print("Daily loss/profit protection initialized. Starting balance: $", DoubleToString(todayStartingBalance, 2));
    
    // V20.2 - Handle immediate entry on load
    if(ImmediateEntryOnLoad && !immediateEntryCompleted)
    {
        immediateEntryPending = true;
        Print("Immediate entry on load is enabled. Will check for entry opportunity.");
    }
    
    // Recover existing positions
    RecoverExistingPositions();
    
    // V20.7 - Initialize Aeron symbol mapping
    if(StringLen(AeronInstrumentName) > 0)
    {
        g_AeronSymbol = AeronInstrumentName;
        g_AeronInstrument = AeronInstrumentName + " Futures";
        PrintFormat("Aeron symbol mapping: MT5=%s -> Futures=%s (%s)", _Symbol, g_AeronSymbol, g_AeronInstrument);
    }
    else
    {
        g_AeronSymbol = _Symbol;
        g_AeronInstrument = _Symbol;
        PrintFormat("Aeron symbol mapping: Using MT5 symbol directly (%s)", _Symbol);
    }
    
    // ===============================================
    // V20.8 - Multi-Channel Aeron Publisher Initialization
    // ===============================================
    if(AeronPublishMode != AERON_PUBLISH_NONE)
    {
        Print("=== V20.8 - Multi-Channel Aeron Publisher Initialization ===");
        
        bool ipcSuccess = false;
        bool udpSuccess = false;
        
        // Initialize IPC channel if needed
        if(AeronPublishMode == AERON_PUBLISH_IPC_ONLY || AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
        {
            Print("Starting IPC Aeron publisher...");
            PrintFormat("  Channel: %s", AeronPublishChannelIpc);
            PrintFormat("  Stream ID: %d", AeronPublishStreamId);
            PrintFormat("  Directory: %s", AeronPublishDir);
            
            if(!g_AeronIpcStarted)  // V20.8.3 - Check state before starting
            {
                if(AeronBridge_StartPublisherIpcW(AeronPublishDir, AeronPublishChannelIpc, AeronPublishStreamId, 5000) != 0)
                {
                    ipcSuccess = true;
                    g_AeronIpcStarted = true;  // V20.8.3 - Track successful start
                    Print("✅ IPC Aeron publisher started successfully");
                }
                else
                {
                    Print("❌ Failed to start IPC Aeron publisher");
                    Print("   This may be due to:");
                    Print("   1. Previous EA instance left orphaned publisher (try reloading EA)");
                    Print("   2. Aeron media driver not running");
                    Print("   3. Directory permissions issue");
                    Print("   Continuing with degraded functionality...");
                }
            }
            else
            {
                Print("⚠️  IPC publisher already started - skipping initialization");
                ipcSuccess = true;  // Consider it success since it's already running
            }
        }
        
        // Initialize UDP channel if needed
        if(AeronPublishMode == AERON_PUBLISH_UDP_ONLY || AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
        {
            Print("Starting UDP Aeron publisher...");
            PrintFormat("  Channel: %s", AeronPublishChannelUdp);
            PrintFormat("  Stream ID: %d", AeronPublishStreamId);
            PrintFormat("  Directory: %s", AeronPublishDir);
            
            if(!g_AeronUdpStarted)  // V20.8.3 - Check state before starting
            {
                if(AeronBridge_StartPublisherUdpW(AeronPublishDir, AeronPublishChannelUdp, AeronPublishStreamId, 5000) != 0)
                {
                    udpSuccess = true;
                    g_AeronUdpStarted = true;  // V20.8.3 - Track successful start
                    Print("✅ UDP Aeron publisher started successfully");
                }
                else
                {
                    Print("❌ Failed to start UDP Aeron publisher");
                    Print("   This may be due to:");
                    Print("   1. Previous EA instance left orphaned publisher (try reloading EA)");
                    Print("   2. Aeron media driver not running");
                    Print("   3. Network configuration issue");
                    Print("   4. Endpoint already in use");
                    Print("   Continuing with degraded functionality...");
                }
            }
            else
            {
                Print("⚠️  UDP publisher already started - skipping initialization");
                udpSuccess = true;  // Consider it success since it's already running
            }
        }
        
        // V20.8 - Report initialization summary
        Print("=== Aeron Publisher Initialization Summary ===");
        if(AeronPublishMode == AERON_PUBLISH_IPC_ONLY)
        {
            PrintFormat("Mode: IPC_ONLY | Status: %s", ipcSuccess ? "✅ OPERATIONAL" : "❌ DEGRADED");
        }
        else if(AeronPublishMode == AERON_PUBLISH_UDP_ONLY)
        {
            PrintFormat("Mode: UDP_ONLY | Status: %s", udpSuccess ? "✅ OPERATIONAL" : "❌ DEGRADED");
        }
        else if(AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
        {
            string status = "";
            if(ipcSuccess && udpSuccess)
                status = "✅ FULLY OPERATIONAL (Both channels active)";
            else if(ipcSuccess || udpSuccess)
                status = "⚠️  PARTIALLY OPERATIONAL (One channel active)";
            else
                status = "❌ DEGRADED (No channels active)";
            PrintFormat("Mode: IPC_AND_UDP | Status: %s", status);
            PrintFormat("  IPC: %s | UDP: %s", ipcSuccess ? "✅" : "❌", udpSuccess ? "✅" : "❌");
        }
        
        // Print protocol information
        Print("=== Aeron Binary Protocol Information ===");
        Print("Protocol Version: 1");
        Print("Frame Size: 104 bytes");
        Print("Magic: 0xA330BEEF");
        Print("Binary Protocol: 104-byte frame (matches NinjaTrader AeronSignalPublisher)");
        PrintFormat("Futures mapping: %s -> %s", _Symbol, g_AeronSymbol);
    }
    else
    {
        Print("Aeron publishing disabled (AeronPublishMode = NONE)");
    }
    
    Print("=== Initialization Complete ===");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("=== Secret Eye V20.9 FOREX Deinitialization ===");
    PrintFormat("Reason code: %d", reason);
    
    // Release indicator
    if(stochHandle != INVALID_HANDLE)
    {
        IndicatorRelease(stochHandle);
        stochHandle = INVALID_HANDLE;
    }
    
    // V20.8.3 - Cleanup Aeron publishers with state tracking
    if(AeronPublishMode == AERON_PUBLISH_IPC_ONLY || AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
    {
        if(g_AeronIpcStarted)  // V20.8.3 - Only cleanup if we started it
        {
            Print("Cleaning up IPC Aeron publisher...");
            AeronBridge_StopPublisherIpc();
            g_AeronIpcStarted = false;
            g_LastPublisherCleanup = TimeCurrent();  // V20.8.3 - Track cleanup time
        }
    }
    
    if(AeronPublishMode == AERON_PUBLISH_UDP_ONLY || AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
    {
        if(g_AeronUdpStarted)  // V20.8.3 - Only cleanup if we started it
        {
            Print("Cleaning up UDP Aeron publisher...");
            AeronBridge_StopPublisherUdp();
            g_AeronUdpStarted = false;
            g_LastPublisherCleanup = TimeCurrent();  // V20.8.3 - Track cleanup time
        }
    }
    
    Print("=== Deinitialization Complete ===");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // V20.7 - Check if safe to operate (prevents operations after critical errors)
    if(!IsSafeToOperate())
    {
        if(g_criticalErrorDetected)
        {
            static datetime lastCriticalMsg = 0;
            if(TimeCurrent() - lastCriticalMsg > 300)  // Every 5 minutes
            {
                Print("=== CRITICAL ERROR STATE: EA operations suspended ===");
                Print("Please check previous error messages and restart EA after resolving issues.");
                lastCriticalMsg = TimeCurrent();
            }
        }
        return;
    }

    // V20.4 - Reset publish flags at start of each tick
    publishFlags = 0;
    
    if(!on) return;
    
    // V20 - Check and update daily trading hours
    CheckAndUpdateDailyTradingHours();
    
    // V20.1 - Check daily loss limit and profit protection
    if(!CheckDailyLossLimit()) 
    {
        return;  // Stop trading for today
    }
    
    CheckDailyProfitProtection();
    if(stopTradingForProfitProtection)
    {
        return;  // Stop trading but keep EA running
    }
    
    // V20.2 - Handle immediate entry
    if(immediateEntryPending && !immediateEntryCompleted)
    {
        ExecuteImmediateTrade();
        immediateEntryPending = false;
        immediateEntryCompleted = true;
        return;
    }
    
    // Regular trading logic from here
    if(!IsTradingAllowed())
    {
        CheckKillSwitchPostTimeRecovery();
        return;
    }
    
    if(!IsInitialDelayOver())
    {
        return;
    }
    
    datetime currentBarTime = iTime(_Symbol, timeFrame, 0);
    if(currentBarTime == lastBarTime) return;
    lastBarTime = currentBarTime;

    UpdateAllPositionStatus();

    double mainLine[3], signalLine[3];
    if(!SafeCopyBuffer(stochHandle, 0, 1, 3, mainLine, OP_INDICATOR) ||
       !SafeCopyBuffer(stochHandle, 1, 1, 3, signalLine, OP_INDICATOR))
    {
        HandleError(OP_INDICATOR, GetLastError(), "Failed to copy stochastic buffers", false);
        return;
    }

    double k0 = mainLine[0], d0 = signalLine[0];
    double k1 = mainLine[1], d1 = signalLine[1];

    bool buyCondition = (k1 < d1) && (k0 > d0);
    bool sellCondition = (k1 > d1) && (k0 < d0);

    if(buyCondition && !scalpBuyOpened && !trendBuyOpened)
    {
        if(!WaitForClosureConfirmation || AreAllReversePositionsClosed(true))
        {
            OpenBuyPositions();
        }
        else
        {
            Print("Buy signal detected but waiting for sell positions to close.");
        }
    }

    if(sellCondition && !scalpSellOpened && !trendSellOpened)
    {
        if(!WaitForClosureConfirmation || AreAllReversePositionsClosed(false))
        {
            OpenSellPositions();
        }
        else
        {
            Print("Sell signal detected but waiting for buy positions to close.");
        }
    }
}

//+------------------------------------------------------------------+
//| V20.4 - OnTradeTransaction: Publishes execution details         |
//+------------------------------------------------------------------+

/**
 * @brief OnTradeTransaction: Publishes execution details when orders fill
 */
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
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

    // Verify this deal belongs to OUR symbol
    string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
    if(dealSymbol != _Symbol)
    {
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
            if(dealVolume <= 0)
            {
                Print("Skipping exit signal - zero volume (likely order modification)");
                return;
            }

            // Update position tracking
            ulong positionTicket = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
            if(positionTicket == scalpSellTicket) { scalpSellOpened = false; scalpSellTicket = 0; }
            else if(positionTicket == trendSellTicket) { trendSellOpened = false; trendSellTicket = 0; }

            if(dealReason == DEAL_REASON_SL || dealReason == DEAL_REASON_TP)
            {
                action = "shortexit_fill";
                orderAction = "Buy";
                exitReason = (dealReason == DEAL_REASON_TP) ? "Profit target" : "Stop loss";
                orderName = exitReason;

                PublishExitSignal("short", exitReason);

                // V20.9 - Aeron exit signal with signal reversal
                if(AeronPublishMode != AERON_PUBLISH_NONE)
                {
                    if(dealReason == DEAL_REASON_TP)
                    {
                        AeronPublishSignalDual(g_AeronSymbol, g_AeronInstrument, AERON_PROFIT_TARGET,
                                          0, 0, 0, 1, 50.0, AeronSourceTag, AeronPublishMode);
                        Print("[AERON_PUB] ✅ ProfitTarget (short): ", g_AeronSymbol);
                    }
                    else
                    {
                        AeronStrategyAction aeronAction = SignalReversal ? AERON_LONG_STOPLOSS : AERON_SHORT_STOPLOSS;
                        AeronPublishSignalDual(g_AeronSymbol, g_AeronInstrument, aeronAction,
                                          0, 0, 0, 1, 50.0, AeronSourceTag, AeronPublishMode);
                        string signalDir = SignalReversal ? "REVERSED" : "NORMAL";
                        PrintFormat("[AERON_PUB] ✅ ShortStopLoss (%s): %s", signalDir, g_AeronSymbol);
                    }
                }
            }
            else
            {
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
            if(dealVolume <= 0)
            {
                Print("Skipping exit signal - zero volume (likely order modification)");
                return;
            }

            // Update position tracking
            ulong positionTicket = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
            if(positionTicket == scalpBuyTicket) { scalpBuyOpened = false; scalpBuyTicket = 0; }
            else if(positionTicket == trendBuyTicket) { trendBuyOpened = false; trendBuyTicket = 0; }

            if(dealReason == DEAL_REASON_SL || dealReason == DEAL_REASON_TP)
            {
                action = "longexit_fill";
                orderAction = "Sell";
                exitReason = (dealReason == DEAL_REASON_TP) ? "Profit target" : "Stop loss";
                orderName = exitReason;

                PublishExitSignal("long", exitReason);

                // V20.9 - Aeron exit signal with signal reversal
                if(AeronPublishMode != AERON_PUBLISH_NONE)
                {
                    if(dealReason == DEAL_REASON_TP)
                    {
                        AeronPublishSignalDual(g_AeronSymbol, g_AeronInstrument, AERON_PROFIT_TARGET,
                                          0, 0, 0, 1, 50.0, AeronSourceTag, AeronPublishMode);
                        Print("[AERON_PUB] ✅ ProfitTarget (long): ", g_AeronSymbol);
                    }
                    else
                    {
                        AeronStrategyAction aeronAction = SignalReversal ? AERON_SHORT_STOPLOSS : AERON_LONG_STOPLOSS;
                        AeronPublishSignalDual(g_AeronSymbol, g_AeronInstrument, aeronAction,
                                          0, 0, 0, 1, 50.0, AeronSourceTag, AeronPublishMode);
                        string signalDir = SignalReversal ? "REVERSED" : "NORMAL";
                        PrintFormat("[AERON_PUB] ✅ LongStopLoss (%s): %s", signalDir, g_AeronSymbol);
                    }
                }
            }
            else
            {
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
//| V20.8.3 - Force cleanup of Aeron publishers (unconditional)     |
//+------------------------------------------------------------------+
void CleanupAeronPublishersForce()
{
    // Always attempt cleanup, regardless of state flags
    // This handles the case where EA crashed/restarted and state was lost
    
    if(AeronPublishMode == AERON_PUBLISH_IPC_ONLY || AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
    {
        Print("Force cleanup: IPC Aeron publisher");
        AeronBridge_StopPublisherIpc();
    }
    
    if(AeronPublishMode == AERON_PUBLISH_UDP_ONLY || AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
    {
        Print("Force cleanup: UDP Aeron publisher");
        AeronBridge_StopPublisherUdp();
    }
    
    Print("Force cleanup completed");
}

//+------------------------------------------------------------------+
//| V20.9 - Opens the dual buy positions with SIGNAL REVERSAL support|
//+------------------------------------------------------------------+
void OpenBuyPositions()
{
    Print("BUY Signal Detected. Opening dual positions.");
    if(SignalReversal)
    {
        Print("⚠️  SIGNAL REVERSAL ACTIVE: Will publish SHORT signals for this LONG trade");
    }
    
    // V20.4 - Generate signal ID and publish signals
    string signalId = StringFormat("%lld-%d", GetTickCount64(), MathRand());
    
    if(PublishToKafka && !(publishFlags & PUBLISH_FLAG_SIGNAL))
    {
        // V20.9 - Determine signal type based on SignalReversal
        string signalType1 = SignalReversal ? "shortentry1" : "longentry1";
        string signalType2 = SignalReversal ? "shortentry2" : "longentry2";
        
        // Entry 1: Stop loss only (TP = 0)
        if(MessageFormat == MSG_NEW_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildNewFormatSignal(signalType1, SL, 0, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, signalType1 + "-new", "");
            }
        }
        
        if(MessageFormat == MSG_LEGACY_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildLegacyFormatSignal(signalType1, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, signalType1 + "-legacy", "");
            }
        }
        
        // Entry 2: Stop loss + profit target
        int profitOffset = (int)(TP * 0.4);
        if(MessageFormat == MSG_NEW_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildNewFormatSignal(signalType2, SL, SL + profitOffset, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, signalType2 + "-new", "");
            }
        }
        
        if(MessageFormat == MSG_LEGACY_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildLegacyFormatSignal(signalType2, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, signalType2 + "-legacy", "");
            }
        }
        
        publishFlags |= PUBLISH_FLAG_SIGNAL;
        lastPublishedSignalId = signalId;
        
        if(SignalReversal)
        {
            Print("[JSON] ✅ Published REVERSED signals: ", signalType1, ", ", signalType2);
        }
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
    // V20.9 - Aeron Binary Signal Publishing with SIGNAL REVERSAL
    // ===============================================
    if(AeronPublishMode != AERON_PUBLISH_NONE && (scalpBuyOpened || trendBuyOpened))
    {
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

        // V20.9 - Determine Aeron action based on SignalReversal
        // For BUY trades: Send LONG signals normally, or SHORT signals if reversed
        AeronStrategyAction action1 = SignalReversal ? AERON_SHORT_ENTRY1 : AERON_LONG_ENTRY1;
        AeronStrategyAction action2 = SignalReversal ? AERON_SHORT_ENTRY2 : AERON_LONG_ENTRY2;

        // Publish Entry1 (stop loss only)
        bool pub1 = AeronPublishSignalDual(
            g_AeronSymbol,
            g_AeronInstrument,
            action1,
            SignalReversal ? 0 : slTicks,     // longSL (0 if reversed to short)
            SignalReversal ? slTicks : 0,     // shortSL (slTicks if reversed to short)
            0,
            1,
            confidence,
            AeronSourceTag,
            AeronPublishMode
        );

        if(pub1)
        {
            string direction = SignalReversal ? "SHORT (REVERSED)" : "LONG";
            PrintFormat("[AERON_PUB] ✅ Entry1: %s %s SL=%d ticks (%d pts) qty=1 conf=%.1f", 
                        g_AeronSymbol, direction, slTicks, SL, confidence);
        }

        // Publish Entry2 (stop loss + profit target)
        bool pub2 = AeronPublishSignalDual(
            g_AeronSymbol,
            g_AeronInstrument,
            action2,
            SignalReversal ? 0 : slTicks,     // longSL
            SignalReversal ? slTicks : 0,     // shortSL
            profitTicks,
            1,
            confidence,
            AeronSourceTag,
            AeronPublishMode
        );

        if(pub2)
        {
            string direction = SignalReversal ? "SHORT (REVERSED)" : "LONG";
            PrintFormat("[AERON_PUB] ✅ Entry2: %s %s SL=%d TP=%d ticks (%d/%d pts) qty=1 conf=%.1f",
                        g_AeronSymbol, direction, slTicks, profitTicks, SL, SL + profitOffsetPoints, confidence);
        }
        
        if(SignalReversal)
        {
            Print("⚠️  Signal reversal: Opened LONG position but published SHORT signals");
        }
    }
}

//+------------------------------------------------------------------+
//| V20.9 - Opens the dual sell positions with SIGNAL REVERSAL support|
//+------------------------------------------------------------------+
void OpenSellPositions()
{
    Print("SELL Signal Detected. Opening dual positions.");
    if(SignalReversal)
    {
        Print("⚠️  SIGNAL REVERSAL ACTIVE: Will publish LONG signals for this SHORT trade");
    }
    
    // V20.4 - Generate signal ID and publish signals
    string signalId = StringFormat("%lld-%d", GetTickCount64(), MathRand());
    
    if(PublishToKafka && !(publishFlags & PUBLISH_FLAG_SIGNAL))
    {
        // V20.9 - Determine signal type based on SignalReversal
        string signalType1 = SignalReversal ? "longentry1" : "shortentry1";
        string signalType2 = SignalReversal ? "longentry2" : "shortentry2";
        
        // Entry 1: Stop loss only (TP = 0)
        if(MessageFormat == MSG_NEW_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildNewFormatSignal(signalType1, SL, 0, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, signalType1 + "-new", "");
            }
        }
        
        if(MessageFormat == MSG_LEGACY_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildLegacyFormatSignal(signalType1, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, signalType1 + "-legacy", "");
            }
        }
        
        // Entry 2: Stop loss + profit target
        int profitOffset = (int)(TP * 0.4);
        if(MessageFormat == MSG_NEW_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildNewFormatSignal(signalType2, SL, SL + profitOffset, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, signalType2 + "-new", "");
            }
        }
        
        if(MessageFormat == MSG_LEGACY_ONLY || MessageFormat == MSG_BOTH)
        {
            if(BuildLegacyFormatSignal(signalType2, signalId))
            {
                PublishJSONToMultipleTopics(jsonSignalBuffer, signalType2 + "-legacy", "");
            }
        }
        
        publishFlags |= PUBLISH_FLAG_SIGNAL;
        lastPublishedSignalId = signalId;
        
        if(SignalReversal)
        {
            Print("[JSON] ✅ Published REVERSED signals: ", signalType1, ", ", signalType2);
        }
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
    // V20.9 - Aeron Binary Signal Publishing with SIGNAL REVERSAL
    // ===============================================
    if(AeronPublishMode != AERON_PUBLISH_NONE && (scalpSellOpened || trendSellOpened))
    {
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

        // V20.9 - Determine Aeron action based on SignalReversal
        // For SELL trades: Send SHORT signals normally, or LONG signals if reversed
        AeronStrategyAction action1 = SignalReversal ? AERON_LONG_ENTRY1 : AERON_SHORT_ENTRY1;
        AeronStrategyAction action2 = SignalReversal ? AERON_LONG_ENTRY2 : AERON_SHORT_ENTRY2;

        // Publish Entry1 (stop loss only)
        bool pub1 = AeronPublishSignalDual(
            g_AeronSymbol,
            g_AeronInstrument,
            action1,
            SignalReversal ? slTicks : 0,     // longSL (slTicks if reversed to long)
            SignalReversal ? 0 : slTicks,     // shortSL (0 if reversed to long)
            0,
            1,
            confidence,
            AeronSourceTag,
            AeronPublishMode
        );

        if(pub1)
        {
            string direction = SignalReversal ? "LONG (REVERSED)" : "SHORT";
            PrintFormat("[AERON_PUB] ✅ Entry1: %s %s SL=%d ticks (%d pts) qty=1 conf=%.1f", 
                        g_AeronSymbol, direction, slTicks, SL, confidence);
        }

        // Publish Entry2 (stop loss + profit target)
        bool pub2 = AeronPublishSignalDual(
            g_AeronSymbol,
            g_AeronInstrument,
            action2,
            SignalReversal ? slTicks : 0,     // longSL
            SignalReversal ? 0 : slTicks,     // shortSL
            profitTicks,
            1,
            confidence,
            AeronSourceTag,
            AeronPublishMode
        );

        if(pub2)
        {
            string direction = SignalReversal ? "LONG (REVERSED)" : "SHORT";
            PrintFormat("[AERON_PUB] ✅ Entry2: %s %s SL=%d TP=%d ticks (%d/%d pts) qty=1 conf=%.1f",
                        g_AeronSymbol, direction, slTicks, profitTicks, SL, SL + profitOffsetPoints, confidence);
        }
        
        if(SignalReversal)
        {
            Print("⚠️  Signal reversal: Opened SHORT position but published LONG signals");
        }
    }
}

//+------------------------------------------------------------------+
//| Remaining Support Functions (Unchanged from V20.8)              |
//+------------------------------------------------------------------+

/**
 * @brief Executes immediate trade on EA load if enabled
 */
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

/**
 * @brief Recovers existing positions after EA restart
 */
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

/**
 * @brief Check if past kill switch time after EA restart
 */
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

/**
 * @brief Check if position exists by ticket number
 */
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

/**
 * @brief Updates status of all tracked positions
 */
void UpdateAllPositionStatus()
{
    if(scalpBuyTicket != 0 && !PositionSelectByTicket(scalpBuyTicket)) { scalpBuyOpened = false; scalpBuyTicket = 0; Print("Scalp Buy position closed."); }
    if(trendBuyTicket != 0 && !PositionSelectByTicket(trendBuyTicket)) { trendBuyOpened = false; trendBuyTicket = 0; Print("Trend Buy position closed."); }
    if(scalpSellTicket != 0 && !PositionSelectByTicket(scalpSellTicket)) { scalpSellOpened = false; scalpSellTicket = 0; Print("Scalp Sell position closed."); }
    if(trendSellTicket != 0 && !PositionSelectByTicket(trendSellTicket)) { trendSellOpened = false; trendSellTicket = 0; Print("Trend Sell position closed."); }
}

/**
 * @brief Check if all reverse positions are closed before entering new position
 */
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

bool ClosePositionWithRetry(ulong ticket, string positionName, int maxRetries = 5)
{
    if(ticket == 0)
    {
        Print("Cannot close ", positionName, " - invalid ticket (0)");
        return true;
    }
    
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
        
        if(trade.PositionClose(ticket))
        {
            Print("✅ SUCCESS: ", positionName, " #", ticket, " closed on attempt ", attempt);
            
            Sleep(50);
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
        
        if(attempt < maxRetries)
        {
            Print("   Waiting ", delay, "ms before retry...");
            Sleep(delay);
            delay = (int)(delay * 1.5);
        }
    }
    
    if(!PositionExistsByTicket(ticket))
    {
        Print("✅ Position ", positionName, " #", ticket, " no longer exists (closed externally?)");
        return true;
    }
    
    Print("❌ EXHAUSTED: Failed to close ", positionName, " #", ticket, " after ", maxRetries, " attempts");
    return false;
}

bool CloseAllBuyPositions()
{
    Print("=== CLOSING ALL BUY POSITIONS ===");
    Print("Account Mode: ", (accountMode == MODE_HEDGING ? "HEDGING" : "NETTING"));
    Print("Symbol: ", _Symbol, " | Magic: ", g_ExpertMagic);
    
    bool allClosed = true;
    
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
    
    if(accountMode == MODE_HEDGING)
    {
        int buyCount = CountPositionsByTypeAndSymbol(POSITION_TYPE_BUY);
        
        if(buyCount > 0)
        {
            Print("⚠️ HEDGING MODE: Found ", buyCount, " additional buy position(s) for ", _Symbol);
            
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

bool CloseAllSellPositions()
{
    Print("=== CLOSING ALL SELL POSITIONS ===");
    Print("Account Mode: ", (accountMode == MODE_HEDGING ? "HEDGING" : "NETTING"));
    Print("Symbol: ", _Symbol, " | Magic: ", g_ExpertMagic);
    
    bool allClosed = true;
    
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
    
    if(accountMode == MODE_HEDGING)
    {
        int sellCount = CountPositionsByTypeAndSymbol(POSITION_TYPE_SELL);
        
        if(sellCount > 0)
        {
            Print("⚠️ HEDGING MODE: Found ", sellCount, " additional sell position(s) for ", _Symbol);
            
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

//+------------------------------------------------------------------+
//| Trading Hours and Account Mode Functions                         |
//+------------------------------------------------------------------+

bool IsTradingAllowed()
{
    if(!on) return false;
    if(stopTradingForDay) return false;
    if(stopTradingForProfitProtection) return false;
    
    if(!EnableKillSwitch) return true;
    
    MqlDateTime time;
    TimeCurrent(time);
    
    int serverToEasternOffset = GetServerToEasternOffset(TimeCurrent());
    int estHour = time.hour + serverToEasternOffset;
    int estMin = time.min;
    
    if(estHour < 0) estHour += 24;
    if(estHour >= 24) estHour -= 24;
    
    bool isWithinTradingHours = false;
    
    if(currentStartHour < currentEndHour)
    {
        isWithinTradingHours = (estHour > currentStartHour || (estHour == currentStartHour && estMin >= currentStartMinute)) &&
                               (estHour < currentEndHour || (estHour == currentEndHour && estMin < currentEndMinute));
    }
    else if(currentStartHour > currentEndHour)
    {
        isWithinTradingHours = (estHour > currentStartHour || (estHour == currentStartHour && estMin >= currentStartMinute)) ||
                               (estHour < currentEndHour || (estHour == currentEndHour && estMin < currentEndMinute));
    }
    else
    {
        isWithinTradingHours = (estMin >= currentStartMinute && estMin < currentEndMinute);
    }
    
    bool isPastEndTime = (estHour > currentEndHour) || (estHour == currentEndHour && estMin >= currentEndMinute);
    
    if(isPastEndTime && !killSwitchExecuted)
    {
        Print("=== KILL SWITCH TRIGGERED ===");
        Print("Current EST Time: ", estHour, ":", StringFormat("%02d", estMin));
        Print("End Time: ", currentEndHour, ":", StringFormat("%02d", currentEndMinute));
        
        bool hadPositions = false;
        
        if(scalpBuyOpened || trendBuyOpened)
        {
            Print("Closing all buy positions due to kill switch...");
            CloseAllBuyPositions();
            hadPositions = true;
        }
        
        if(scalpSellOpened || trendSellOpened)
        {
            Print("Closing all sell positions due to kill switch...");
            CloseAllSellPositions();
            hadPositions = true;
        }
        
        killSwitchExecuted = true;
        stopTradingForDay = true;
        
        Print("Kill switch executed. Trading disabled for remainder of day.");
        
        if(ShowAlerts && hadPositions)
        {
            Alert("Kill Switch: All positions closed for ", _Symbol, " at ", estHour, ":", StringFormat("%02d", estMin), " EST");
        }
    }
    
    return isWithinTradingHours;
}

bool IsInitialDelayOver()
{
    if(DelayOnInitialOrder <= 0) return true;
    if(firstTradeOfDayPlaced) return true;
    
    static datetime firstAllowedTradeTime = 0;
    
    if(firstAllowedTradeTime == 0)
    {
        MqlDateTime time;
        TimeCurrent(time);
        
        int serverToEasternOffset = GetServerToEasternOffset(TimeCurrent());
        int estHour = time.hour + serverToEasternOffset;
        int estMin = time.min;
        
        if(estHour < 0) estHour += 24;
        if(estHour >= 24) estHour -= 24;
        
        bool isAfterStartTime = (estHour > currentStartHour) || 
                               (estHour == currentStartHour && estMin >= currentStartMinute);
        
        if(isAfterStartTime)
        {
            firstAllowedTradeTime = TimeCurrent() + DelayOnInitialOrder;
            Print("Initial order delay activated. First trade allowed at: ", TimeToString(firstAllowedTradeTime));
        }
        else
        {
            return false;
        }
    }
    
    return (TimeCurrent() >= firstAllowedTradeTime);
}

ENUM_ACCOUNT_MODE DetectAccountMarginMode()
{
    long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
    
    if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
        return MODE_HEDGING;
    else if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
        return MODE_NETTING;
    else
        return MODE_UNKNOWN;
}

int CountPositionsByTypeAndSymbol(ENUM_POSITION_TYPE posType)
{
    int count = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetSymbol(i) == _Symbol)
        {
            if(PositionGetInteger(POSITION_MAGIC) == g_ExpertMagic &&
               (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
            {
                count++;
            }
        }
    }
    return count;
}

bool CheckDailyLossLimit()
{
    static datetime lastResetTime = 0;
    MqlDateTime dt;
    
    ResetLastError();
    if(!TimeCurrent(dt))
    {
        HandleError(OP_CALCULATION, GetLastError(), "Failed to get current time", false);
        return false;
    }
    
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
    
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
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
//| API Trading Hours Functions                                      |
//+------------------------------------------------------------------+

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
        Print("WebRequest error: ", errorCode);
        Print("Common causes:");
        Print("1. URL not in allowed list: Tools > Options > Expert Advisors > Allow WebRequest");
        Print("2. Network connectivity issues");
        Print("3. Invalid HOST_URI: ", HOST_URI);
        Print("Make sure the URL is added to allowed URLs in MetaTrader options");
        Print("Go to Tools > Options > Expert Advisors > Allow WebRequest for: ", HOST_URI);

        if(ShowAlerts)
        {
            Alert("API ERROR: WebRequest failed (Error ", errorCode, ")");
            Alert("Add ", HOST_URI, " to MT5 allowed URLs: Tools>Options>Expert Advisors");
        }
        return false;
    }

    if(httpResult != 200)
    {
        Print("HTTP Error: ", httpResult);
        Print("API endpoint may be unavailable or returned an error");
        Print("URL: ", url);
        Print("Expected: HTTP 200, Received: HTTP ", httpResult);

        if(ShowAlerts)
        {
            Alert("API ERROR: HTTP ", httpResult, " from ", HOST_URI);
            Alert("Check if API server is running and endpoint exists");
        }
        return false;
    }

    string jsonResponse = CharArrayToString(result);
    Print("API Response received: ", StringLen(jsonResponse), " characters");

    return ParseTradingHoursJSON(jsonResponse);
}

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
        Print("Failed to parse trading hours from API response");
        Print("Response length: ", StringLen(jsonResponse), " characters");
        Print("This may indicate:");
        Print("1. Invalid JSON format from API");
        Print("2. Missing required fields (symbol, weekly_schedule)");
        Print("3. API symbol '", API_Symbol, "' not found in database");

        if(ShowAlerts)
        {
            Alert("PARSE ERROR: Invalid trading hours data from API");
            Alert("Symbol '", API_Symbol, "' may not exist in API database");
        }
    }

    return apiDataValid;
}

void SetTradingHoursForToday()
{
    if(!apiDataValid)
    {
        Print("No valid API data available - using manual hours");
        Print("Manual trading hours: ", StringFormat("%02d:%02d", ManualStartTime, ManualStartMinute),
              " - ", StringFormat("%02d:%02d", ManualEndTime, ManualEndMinute));
        currentStartHour = ManualStartTime;
        currentStartMinute = ManualStartMinute;
        currentEndHour = ManualEndTime;
        currentEndMinute = ManualEndMinute;

        if(ShowAlerts)
        {
            Alert("WARNING: Using manual trading hours (API data invalid)");
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
        Print("No trading hours found for ", dayName, " - using impossible range (no trading today)");
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
            Alert("INFO: No trading scheduled for ", dayName);
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
        Print("Failed to parse time strings for ", dayName, " - using manual hours");
        Print("API returned invalid time format:");
        Print("Start: '", todayWindow.start, "' | End: '", todayWindow.end, "'");
        Print("Expected format: HH:MM (e.g., '09:30')");
        currentStartHour = ManualStartTime;
        currentStartMinute = ManualStartMinute;
        currentEndHour = ManualEndTime;
        currentEndMinute = ManualEndMinute;

        if(ShowAlerts)
        {
            Alert("TIME FORMAT ERROR: Invalid time format from API");
            Alert("Using manual fallback for ", dayName, ": ",
                  StringFormat("%02d:%02d", ManualStartTime, ManualStartMinute), " - ",
                  StringFormat("%02d:%02d", ManualEndTime, ManualEndMinute));
        }
    }
}

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
            Alert("Day Changed: Trading hours updated for ", GetDayOfWeekString(dt.day_of_week));
            Alert("New hours: ",
                  StringFormat("%02d:%02d", currentStartHour, currentStartMinute), " - ",
                  StringFormat("%02d:%02d", currentEndHour, currentEndMinute), " EST/EDT");
        }
    }
}

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

bool ParseTimeString(string timeStr, int &hour, int &minute)
{
    Print("DEBUG: Parsing time string: '", timeStr, "' (length: ", StringLen(timeStr), ")");

    int colonPos = StringFind(timeStr, ":");
    if(colonPos == -1)
    {
        Print("Invalid time format - no colon found: ", timeStr);
        return false;
    }

    int timeLength = StringLen(timeStr);
    if(timeLength != 4 && timeLength != 5)
    {
        Print("Invalid time format - wrong length (", timeLength, "): ", timeStr);
        Print("Expected: H:MM (4 chars) or HH:MM (5 chars)");
        return false;
    }

    string hourStr = StringSubstr(timeStr, 0, colonPos);
    string minuteStr = StringSubstr(timeStr, colonPos + 1);

    Print("DEBUG: Extracted hour string: '", hourStr, "', minute string: '", minuteStr, "'");

    if(StringLen(minuteStr) != 2)
    {
        Print("Invalid minute format - should be 2 digits: '", minuteStr, "'");
        return false;
    }

    hour = (int)StringToInteger(hourStr);
    minute = (int)StringToInteger(minuteStr);

    Print("DEBUG: Parsed values - hour: ", hour, ", minute: ", minute);

    if(hour < 0 || hour > 23 || minute < 0 || minute > 59)
    {
        Print("Time values out of range: ", timeStr, " (hour: ", hour, ", minute: ", minute, ")");
        return false;
    }

    Print("Successfully parsed time: ", timeStr, " -> ", StringFormat("%02d:%02d", hour, minute));
    return true;
}

//+------------------------------------------------------------------+
//| V20.7 - Exception Handling Function Implementations              |
//+------------------------------------------------------------------+

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
    
    if(TimeCurrent() - g_lastErrorTime < 5)
    {
        g_consecutiveErrors++;
    }
    else
    {
        g_consecutiveErrors = 1;
    }
    
    g_lastErrorTime = TimeCurrent();
    g_lastErrorMessage = message;
    
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

bool SafeCopyBuffer(int indicator_handle, int buffer_num, int start_pos, int count, 
                   double &buffer[], OPERATION_CONTEXT context = OP_INDICATOR)
{
    if(indicator_handle == INVALID_HANDLE)
    {
        HandleError(context, 4801,
                   "Invalid indicator handle in SafeCopyBuffer", false);
        return false;
    }
    
    if(count <= 0 || count > 10000)
    {
        HandleError(context, 4003,
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
    
    for(int i = 0; i < copied; i++)
    {
        if(buffer[i] != buffer[i])
        {
            HandleError(context, 0, 
                       StringFormat("NaN detected in buffer at index %d", i), false);
            return false;
        }
    }
    
    return true;
}

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

double SafeDivide(double numerator, double denominator, double defaultValue = 0.0)
{
    if(MathAbs(denominator) < 0.0000001)
    {
        HandleError(OP_CALCULATION, 0, 
                   StringFormat("Division by zero attempted: %.8f / %.8f", numerator, denominator), 
                   false);
        return defaultValue;
    }
    return numerator / denominator;
}

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
            if(g_consecutiveErrors > 0) g_consecutiveErrors = 0;
            return true;
        }
        
        Print(StringFormat("[WEBREQUEST] Attempt %d/%d failed: HTTP=%d, Error=%d", 
                          attempt + 1, maxRetries, httpCode, error));
        
        if(error == 5200 || error == 5203)
        {
            HandleError(OP_WEBREQUEST, error, 
                       StringFormat("WebRequest configuration error for URL: %s", url), false);
            break;
        }
        
        if(attempt < maxRetries - 1)
        {
            Sleep((int)MathPow(2, attempt) * 1000);
        }
    }
    
    HandleError(OP_WEBREQUEST, GetLastError(), 
               StringFormat("WebRequest failed after %d attempts: %s", maxRetries, url), false);
    return false;
}

bool IsSafeToOperate()
{
    if(g_criticalErrorDetected)
    {
        static datetime lastWarning = 0;
        if(TimeCurrent() - lastWarning > 60)
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

int ConvertPointsToFuturesTicks(int points, string futuresSymbol)
{
   if(points < 0)
   {
      HandleError(OP_CALCULATION, 0, 
                 StringFormat("Invalid point value: %d", points), false);
      return 0;
   }
   
   double forexPointSize = 0.00001;
   double futuresTickSize = 0.00005;
   
   if(futuresSymbol == "6A")      futuresTickSize = 0.00005;
   else if(futuresSymbol == "6B") futuresTickSize = 0.00005;
   else if(futuresSymbol == "6C") futuresTickSize = 0.00005;
   else if(futuresSymbol == "6E") futuresTickSize = 0.00005;
   else if(futuresSymbol == "6J") futuresTickSize = 0.0000050;
   else if(futuresSymbol == "6N") futuresTickSize = 0.00005;
   else if(futuresSymbol == "6S") futuresTickSize = 0.00005;
   else if(futuresSymbol == "ES") futuresTickSize = 0.25;
   else if(futuresSymbol == "NQ") futuresTickSize = 0.25;
   else if(futuresSymbol == "YM") futuresTickSize = 1.0;
   else if(futuresSymbol == "RTY") futuresTickSize = 0.10;
   else
   {
      Print("WARNING: Unknown futures symbol '", futuresSymbol, "' - using default tick size 0.00005");
   }
   
   double pointsInPrice = points * forexPointSize;
   int ticks = (int)MathRound(pointsInPrice / futuresTickSize);
   
   return ticks;
}

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
        "MES", "MNQ", "MYM", "M2K", "MGC", "MCL", "6E", "6J", "6B", "6C",
        "6A", "6S", "6N"
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
        "\"PositionSize\":%d,\"RiskMultiplier\":%.1f,\"Source\":\"Secret_Eye_V20_9\","
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

    // Build message as JSON object (not escaped string)
    string message = StringFormat(
        "{\"Symbol\":\"%s\",\"Action\":\"%s\",\"ExecutionType\":\"%s\",\"OrderAction\":\"%s\","
        "\"OrderName\":\"%s\",\"ExecutionId\":\"%s\",\"Price\":%.5f,\"Quantity\":%.2f,"
        "\"MarketPosition\":\"%s\",\"UnrealizedPnL\":%.2f,\"RealizedPnL\":%.2f,"
        "\"ExecutionTime\":\"%s\",\"ExecutionTimeEST\":\"%s\",\"Timestamp\":\"%s\","
        "\"TimestampEST\":\"%s\",\"Source\":\"Secret_Eye_V20_9\",\"InstrumentFullName\":\"%s\","
        "\"ExecutionSequence\":%d}",
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
        // Find the actual message content (everything after "message":
        string originalPayload = CharArrayToString(buffer);

        // Extract the message content (between "message":" and the closing ")
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
            "\"Source\":\"Secret_Eye_V20_9_FOREX\",\"InstrumentFullName\":\"%s\"}",
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
