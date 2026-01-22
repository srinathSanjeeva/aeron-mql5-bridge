#property strict

#include "BrokerMappings.mqh"
#include <Trade/Trade.mqh>

CTrade trade;

//==============================
// Inputs
//==============================
// Broker Configuration
input ENUM_BROKER_PROFILE BrokerProfile = BROKER_PROFILE_A;  // Broker Symbol Profile
input bool   AutoDetectBroker   = false;  // Auto-detect broker from account info
input string CustomMappingFile  = "";     // CSV file for custom mappings (leave empty to use profile)

// Safety + Ops
input bool   EnableTrading      = false;
input bool   DryRun             = true;
input int    TimerSeconds       = 1;
input int    MaxSignalsPerTimer = 25;
input double MinConfidence      = 0.0;

// Risk Management
input int    CooldownSeconds          = 2;
input int    MinSignalsBeforeCooldown = 2;
input int    MaxPositionsPerSymbol    = 2;
input int    MaxTradesPerMinute       = 6;
input int    SlippagePoints           = 20;
input string QuantityMultipliers      = "";  // "ES:2.0,NQ:1.5"
input double DefaultQuantityMultiplier = 1.0;

// Aeron Configuration
input string AeronDir       = "C:\\aeron\\standalone";
input string AeronChannel   = "aeron:ipc";
input int    AeronStreamId  = 1001;
input int    AeronTimeoutMs = 3000;

//==============================
// Internal State
//==============================
uchar  g_csvBuf[512];
uchar  g_errBuf[512];

datetime g_minuteBucketStart = 0;
int      g_tradesThisMinute  = 0;

string   g_cdKey[200];
datetime g_cdUntil[200];
int      g_cdSignalCount[200];
int      g_cdCount = 0;

string   g_qtyInstrument[100];
double   g_qtyMultiplier[100];
int      g_qtyCount = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("==================================================");
   Print("Initializing Aeron Bridge Multi-Broker EA");
   Print("==================================================");
   
   // Step 1: Configure broker-specific symbol mappings
   bool mappingSuccess = false;
   
   if(CustomMappingFile != "")
   {
      // Load from CSV file (highest priority)
      Print("Loading custom mappings from CSV file: ", CustomMappingFile);
      mappingSuccess = LoadMappingsFromCSV(CustomMappingFile);
      
      if(!mappingSuccess)
      {
         Print("WARNING: Failed to load custom mapping file, falling back to profile");
      }
   }
   
   if(!mappingSuccess)
   {
      ENUM_BROKER_PROFILE activeProfile = BrokerProfile;
      
      if(AutoDetectBroker)
      {
         Print("Auto-detecting broker profile...");
         activeProfile = DetectBrokerProfile();
      }
      
      mappingSuccess = RegisterBrokerMappings(activeProfile);
   }
   
   if(!mappingSuccess)
   {
      Print("ERROR: Failed to register broker symbol mappings");
      return INIT_FAILED;
   }
   
   // Step 2: Start Aeron subscription
   Print("Starting Aeron subscription...");
   PrintFormat("  Aeron Dir: %s", AeronDir);
   PrintFormat("  Channel: %s", AeronChannel);
   PrintFormat("  Stream ID: %d", AeronStreamId);
   
   int result = AeronBridge_StartW(
       AeronDir,
       AeronChannel,
       AeronStreamId,
       AeronTimeoutMs
   );
   
   if(result == 0)
   {
      ArrayInitialize(g_errBuf, 0);
      int errLen = AeronBridge_LastError(g_errBuf, ArraySize(g_errBuf));
      string errMsg = (errLen > 0) ? CharArrayToString(g_errBuf, 0, errLen) : "Unknown error";
      
      PrintFormat("ERROR: Failed to start Aeron bridge: %s", errMsg);
      return INIT_FAILED;
   }
   
   Print("Aeron subscription started successfully");
   
   // Step 3: Parse quantity multipliers
   ParseQuantityMultipliers();
   
   // Step 4: Set up timer
   if(!EventSetTimer(TimerSeconds))
   {
      Print("ERROR: Failed to set timer");
      return INIT_FAILED;
   }
   
   // Step 5: Print configuration summary
   Print("==================================================");
   Print("Configuration Summary:");
   PrintFormat("  Trading Enabled: %s", EnableTrading ? "YES" : "NO");
   PrintFormat("  Dry Run Mode: %s", DryRun ? "YES" : "NO");
   PrintFormat("  Min Confidence: %.2f", MinConfidence);
   PrintFormat("  Max Positions Per Symbol: %d", MaxPositionsPerSymbol);
   PrintFormat("  Max Trades Per Minute: %d", MaxTradesPerMinute);
   PrintFormat("  Cooldown Seconds: %d", CooldownSeconds);
   Print("==================================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   AeronBridge_Stop();
   
   Print("Aeron Bridge EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function - polls for signals                               |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Poll Aeron for new messages
   int pollCount = AeronBridge_Poll();
   
   // Process queued signals
   int processed = 0;
   while(AeronBridge_HasSignal() && processed < MaxSignalsPerTimer)
   {
      ArrayInitialize(g_csvBuf, 0);
      int csvLen = AeronBridge_GetSignalCsv(g_csvBuf, ArraySize(g_csvBuf));
      
      if(csvLen > 0)
      {
         string csv = CharArrayToString(g_csvBuf, 0, csvLen);
         ProcessSignal(csv);
         processed++;
      }
      else
      {
         break;
      }
   }
   
   if(processed > 0)
   {
      PrintFormat("Processed %d signals", processed);
   }
}

//+------------------------------------------------------------------+
//| Utility Functions (same as original EA)                          |
//+------------------------------------------------------------------+
int FindCooldownIndex(const string key)
{
   for(int i=0; i<g_cdCount; i++)
      if(g_cdKey[i] == key) return i;
   return -1;
}

double GetQuantityMultiplier(const string ntInstrument)
{
   string prefix = ntInstrument;
   int spacePos = StringFind(ntInstrument, " ");
   if(spacePos > 0)
      prefix = StringSubstr(ntInstrument, 0, spacePos);
   
   for(int i=0; i<g_qtyCount; i++)
   {
      if(g_qtyInstrument[i] == prefix)
         return g_qtyMultiplier[i];
   }
   
   return DefaultQuantityMultiplier;
}

void ParseQuantityMultipliers()
{
   g_qtyCount = 0;
   
   if(QuantityMultipliers == "")
      return;
   
   string pairs[];
   int pairCount = StringSplit(QuantityMultipliers, ',', pairs);
   
   for(int i=0; i<pairCount && g_qtyCount<ArraySize(g_qtyInstrument); i++)
   {
      string pair = pairs[i];
      StringTrimLeft(pair);
      StringTrimRight(pair);
      
      int colonPos = StringFind(pair, ":");
      if(colonPos > 0)
      {
         string instrument = StringSubstr(pair, 0, colonPos);
         string multiplierStr = StringSubstr(pair, colonPos + 1);
         
         StringTrimLeft(instrument);
         StringTrimRight(instrument);
         StringTrimLeft(multiplierStr);
         StringTrimRight(multiplierStr);
         
         double multiplier = StringToDouble(multiplierStr);
         if(multiplier > 0)
         {
            g_qtyInstrument[g_qtyCount] = instrument;
            g_qtyMultiplier[g_qtyCount] = multiplier;
            g_qtyCount++;
            
            PrintFormat("Quantity multiplier: %s = %.2f", instrument, multiplier);
         }
      }
   }
}

void ProcessSignal(string csv)
{
   // Parse CSV: action,qty,sl_points,pt_points,confidence,symbol,mt5_symbol,source,instrument
   string fields[];
   int count = StringSplit(csv, ',', fields);
   
   if(count < 9)
   {
      Print("WARNING: Invalid signal CSV format: ", csv);
      return;
   }
   
   int action = (int)StringToInteger(fields[0]);
   int qty = (int)StringToInteger(fields[1]);
   int slPoints = (int)StringToInteger(fields[2]);
   int ptPoints = (int)StringToInteger(fields[3]);
   double confidence = StringToDouble(fields[4]);
   string symbol = fields[5];
   string mt5Symbol = fields[6];  // This is now broker-specific!
   string source = fields[7];
   string instrument = fields[8];
   
   // Apply quantity multiplier
   double qtyMultiplier = GetQuantityMultiplier(instrument);
   double adjustedQty = qty * qtyMultiplier;
   
   PrintFormat("Signal: %s [%s->%s] Action=%d Qty=%.2f (%.2fx) SL=%d PT=%d Conf=%.2f",
      instrument, symbol, mt5Symbol, action, adjustedQty, qtyMultiplier,
      slPoints, ptPoints, confidence);
   
   // Filter by confidence
   if(confidence < MinConfidence)
   {
      PrintFormat("  Rejected: confidence %.2f < %.2f", confidence, MinConfidence);
      return;
   }
   
   // TODO: Add remaining logic from original EA
   // - Cooldown checking
   // - Position limits
   // - Trade rate limiting
   // - Order execution
   
   if(DryRun)
   {
      Print("  [DRY RUN] Would execute trade here");
   }
   else if(EnableTrading)
   {
      Print("  [LIVE] Executing trade...");
      // Call trade execution logic
   }
   else
   {
      Print("  [DISABLED] Trading not enabled");
   }
}

//+------------------------------------------------------------------+
