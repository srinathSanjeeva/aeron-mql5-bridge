#property strict

#include "AeronBridge.mqh"
#include <Trade/Trade.mqh>

CTrade trade;

//==============================
// Inputs (Safety + Ops)
//==============================
input bool   EnableTrading            = false;   // Kill switch (must be true to place orders)
input bool   DryRun                   = true;    // If true, logs orders but does not place
input int    TimerSeconds             = 1;       // Poll cadence
input int    MaxSignalsPerTimer       = 25;      // Drain up to N signals per timer tick
input double MinConfidence            = 0.0;     // Ignore signals below this

input int    CooldownSeconds          = 2;       // Per symbol+direction
input int    MinSignalsBeforeCooldown = 2;       // Require this many signals before cooldown
input int    MaxPositionsPerSymbol    = 2;       // Guardrail
input int    MaxTradesPerMinute       = 6;       // Guardrail
input int    SlippagePoints           = 20;      // Max slippage in points (broker-dependent)
input string QuantityMultipliers      = "";      // Per-instrument multipliers: "ES:2.0,NQ:1.5" (empty = 1.0 for all)
input double DefaultQuantityMultiplier = 1.0;    // Default multiplier if instrument not in QuantityMultipliers

input group             "Profit/Loss Protection"
input double MAX_DAILY_LOSS_PERCENTAGE = 2.5;    // Daily loss percentage limit
input bool   EnableProfitProtection    = true;   // Enable automatic profit protection
input bool   ShowAlerts                = true;   // Show dialog box alerts when limits hit

input string AeronDir                 = "C:\\aeron\\standalone";
// input string AeronChannel             = "aeron:udp?endpoint=192.168.2.15:40123";
input string AeronChannel             = "aeron:ipc";
input int    AeronStreamId            = 1001;
input int    AeronTimeoutMs           = 3000;

//==============================
// Internal state
//==============================
uchar  g_csvBuf[512];
uchar  g_errBuf[512];

// Trade-rate limiter
datetime g_minuteBucketStart = 0;
int      g_tradesThisMinute  = 0;

// Cooldown tracking (symbol+dir)
string   g_cdKey[200];
datetime g_cdUntil[200];
int      g_cdSignalCount[200];  // Track how many signals received per symbol+dir
int      g_cdCount = 0;

// Quantity multiplier per instrument (NT instrument name -> multiplier)
string   g_qtyInstrument[100];
double   g_qtyMultiplier[100];
int      g_qtyCount = 0;

// Profit/Loss Protection
static double       todayStartingBalance = 0;
bool                stopTradingForDay = false;
static double       dailyMaxProfitBalance = 0;
static bool         profitProtectionActive = false;
static bool         stopTradingForProfitProtection = false;

//==============================
// Utility
//==============================
int FindCooldownIndex(const string key)
{
   for(int i=0;i<g_cdCount;i++)
      if(g_cdKey[i] == key) return i;
   return -1;
}

double GetQuantityMultiplier(const string ntInstrument)
{
   // Extract prefix from instrument (e.g., "ES MAR26" -> "ES")
   string prefix = ntInstrument;
   int spacePos = StringFind(ntInstrument, " ");
   if(spacePos > 0)
      prefix = StringSubstr(ntInstrument, 0, spacePos);
   
   // Look up in configured multipliers
   for(int i=0; i<g_qtyCount; i++)
   {
      if(g_qtyInstrument[i] == prefix)
         return g_qtyMultiplier[i];
   }
   
   // Return default if not found
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
            PrintFormat("[QTY_MULT] %s -> %.2f", instrument, multiplier);
         }
      }
   }
}

bool IsInCooldown(const string symbol, const int dir /*+1 buy, -1 sell*/)
{
   // Cooldown is per symbol only (not per direction)
   string key = symbol;
   int idx = FindCooldownIndex(key);
   if(idx < 0) return false;
   
   // If cooldown expired, reset the signal count immediately
   if(TimeCurrent() >= g_cdUntil[idx])
   {
      g_cdSignalCount[idx] = 0;
      return false;
   }
   
   // Allow signals until MinSignalsBeforeCooldown is reached
   if(g_cdSignalCount[idx] < MinSignalsBeforeCooldown) return false;
   return true;  // In cooldown
}

void SetCooldown(const string symbol, const int dir)
{
   // Cooldown is per symbol only (not per direction)
   string key = symbol;
   datetime until = TimeCurrent() + CooldownSeconds;

   int idx = FindCooldownIndex(key);
   if(idx < 0)
   {
      if(g_cdCount < ArraySize(g_cdKey))
      {
         g_cdKey[g_cdCount] = key;
         g_cdUntil[g_cdCount] = until;
         g_cdSignalCount[g_cdCount] = 1;  // First signal for this symbol
         g_cdCount++;
      }
      return;
   }
   
   // Increment signal count and update cooldown expiration
   g_cdSignalCount[idx]++;
   g_cdUntil[idx] = until;
}

void ResetMinuteBucketIfNeeded()
{
   datetime now = TimeCurrent();
   if(g_minuteBucketStart == 0)
   {
      g_minuteBucketStart = now;
      g_tradesThisMinute = 0;
      return;
   }

   if((now - g_minuteBucketStart) >= 60)
   {
      g_minuteBucketStart = now;
      g_tradesThisMinute = 0;
   }
}

bool RateLimitAllowTrade()
{
   ResetMinuteBucketIfNeeded();
   if(g_tradesThisMinute >= MaxTradesPerMinute)
      return false;
   g_tradesThisMinute++;
   return true;
}

int CountPositionsForSymbol(const string symbol)
{
   int count = 0;
   int i = 0;
   for(i=PositionsTotal()-1; i>=0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         string s = PositionGetString(POSITION_SYMBOL);
         if(s == symbol) count++;
      }
   }
   return count;
}

int CountPositionsForSymbolByDirection(const string symbol, const int dir)
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         string s = PositionGetString(POSITION_SYMBOL);
         if(s == symbol)
         {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if((dir > 0 && posType == POSITION_TYPE_BUY) || (dir < 0 && posType == POSITION_TYPE_SELL))
               count++;
         }
      }
   }
   return count;
}

void CloseOppositePositions(const string symbol, const int dir)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         string s = PositionGetString(POSITION_SYMBOL);
         if(s == symbol)
         {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            // Close if position is opposite to the signal direction
            bool shouldClose = false;
            if(dir > 0 && posType == POSITION_TYPE_SELL) shouldClose = true;
            if(dir < 0 && posType == POSITION_TYPE_BUY) shouldClose = true;
            
            if(shouldClose)
            {
               if(DryRun || !EnableTrading)
               {
                  PrintFormat("[DRYRUN] Closing opposite position: ticket=%I64u %s %s",
                              ticket, s, (posType==POSITION_TYPE_BUY?"BUY":"SELL"));
               }
               else
               {
                  bool closed = trade.PositionClose(ticket);
                  if(closed)
                  {
                     PrintFormat("[CLOSE_OK] Closed opposite position: ticket=%I64u %s %s",
                                 ticket, s, (posType==POSITION_TYPE_BUY?"BUY":"SELL"));
                  }
                  else
                  {
                     PrintFormat("[CLOSE_FAIL] Failed to close position: ticket=%I64u err=%d",
                                 ticket, (int)GetLastError());
                  }
               }
            }
         }
      }
   }
}

double NormalizePrice(const string symbol, const double price)
{
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

//==============================
// Profit/Loss Protection
//==============================
void CloseAllPositions()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         string symbol = PositionGetString(POSITION_SYMBOL);
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         
         if(DryRun || !EnableTrading)
         {
            PrintFormat("[DRYRUN] Closing position for protection: ticket=%I64u %s %s",
                        ticket, symbol, (posType==POSITION_TYPE_BUY?"BUY":"SELL"));
         }
         else
         {
            bool closed = trade.PositionClose(ticket);
            if(closed)
            {
               PrintFormat("[CLOSE_OK] Closed position for protection: ticket=%I64u %s %s",
                           ticket, symbol, (posType==POSITION_TYPE_BUY?"BUY":"SELL"));
            }
            else
            {
               PrintFormat("[CLOSE_FAIL] Failed to close position: ticket=%I64u err=%d",
                           ticket, (int)GetLastError());
            }
         }
      }
   }
}

void CheckDailyLossLimit()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // Initialize starting balance at midnight
   MqlDateTime nowStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   
   static int lastDay = -1;
   if(lastDay != nowStruct.day)
   {
      todayStartingBalance = currentBalance;
      stopTradingForDay = false;
      lastDay = nowStruct.day;
      PrintFormat("[PROFIT_PROTECTION] New day detected. Starting balance: %.2f", todayStartingBalance);
   }
   
   if(stopTradingForDay)
      return;
   
   if(todayStartingBalance <= 0)
      return;
   
   double lossAmount = todayStartingBalance - currentBalance;
   double lossPercent = (lossAmount / todayStartingBalance) * 100.0;
   
   if(lossPercent >= MAX_DAILY_LOSS_PERCENTAGE)
   {
      stopTradingForDay = true;
      string message = StringFormat("[LOSS LIMIT HIT] Daily loss limit reached!\nLoss: %.2f%% ($%.2f)\nClosing all positions and stopping trading.",
                                    lossPercent, lossAmount);
      PrintFormat("[LOSS_LIMIT_HIT] Daily loss limit reached! Loss: %.2f%% (%.2f). Closing all positions and stopping trading.",
                  lossPercent, lossAmount);
      
      if(ShowAlerts)
         Alert(message);
      
      CloseAllPositions();
   }
}

void CheckDailyProfitProtection()
{
   if(!EnableProfitProtection)
      return;
   
   if(stopTradingForProfitProtection)
      return;
   
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // Initialize starting balance at midnight
   MqlDateTime nowStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   
   static int lastDayProfit = -1;
   if(lastDayProfit != nowStruct.day)
   {
      if(todayStartingBalance == 0)
         todayStartingBalance = currentBalance;
      
      dailyMaxProfitBalance = currentBalance;
      profitProtectionActive = false;
      stopTradingForProfitProtection = false;
      lastDayProfit = nowStruct.day;
   }
   
   // Track maximum profit achieved today
   if(currentBalance > dailyMaxProfitBalance)
      dailyMaxProfitBalance = currentBalance;
   
   // Activate protection when profit exceeds daily loss percentage
   double profitAmount = dailyMaxProfitBalance - todayStartingBalance;
   double profitPercent = (profitAmount / todayStartingBalance) * 100.0;
   
   if(profitPercent >= MAX_DAILY_LOSS_PERCENTAGE && !profitProtectionActive)
   {
      profitProtectionActive = true;
      string message = StringFormat("[PROFIT PROTECTION ACTIVATED]\nProfit: %.2f%% ($%.2f)\nNow monitoring for %.2f%% drawdown from peak.",
                                    profitPercent, profitAmount, MAX_DAILY_LOSS_PERCENTAGE);
      PrintFormat("[PROFIT_PROTECTION] Profit protection activated at %.2f%% profit (%.2f). Monitoring for %.2f%% drawdown.",
                  profitPercent, profitAmount, MAX_DAILY_LOSS_PERCENTAGE);
      
      if(ShowAlerts)
         Alert(message);
   }
   
   // Check for drawdown from peak if protection is active
   if(profitProtectionActive)
   {
      double drawdownAmount = dailyMaxProfitBalance - currentBalance;
      double drawdownPercent = (drawdownAmount / dailyMaxProfitBalance) * 100.0;
      
      if(drawdownPercent >= MAX_DAILY_LOSS_PERCENTAGE)
      {
         stopTradingForProfitProtection = true;
         string message = StringFormat("[PROFIT PROTECTION HIT]\nDrawdown from peak: %.2f%% ($%.2f)\nClosing all positions and stopping trading.",
                                       drawdownPercent, drawdownAmount);
         PrintFormat("[PROFIT_PROTECTION_HIT] Drawdown from peak reached %.2f%% (%.2f). Closing all positions and stopping trading.",
                     drawdownPercent, drawdownAmount);
         
         if(ShowAlerts)
            Alert(message);
         
         CloseAllPositions();
      }
   }
}

//==============================
// CSV parsing: expected format
// action,qty,sl_points,pt_points,confidence,symbol,mt5_symbol,source,instrument
//==============================
bool SplitCsv9(const string csv,
               int &action, int &qty, int &slPts, int &ptPts, double &conf,
               string &sym, string &mt5sym, string &source, string &instrument)
{
   string parts[];
   int n = StringSplit(csv, ',', parts);
   if(n < 9) return false;

   action = (int)StringToInteger(parts[0]);
   qty    = (int)StringToInteger(parts[1]);
   slPts  = (int)StringToInteger(parts[2]);
   ptPts  = (int)StringToInteger(parts[3]);
   conf   = StringToDouble(parts[4]);

   sym        = parts[5];
   mt5sym     = parts[6];
   source     = parts[7];

   // instrument may contain commas? normally no; 
   // but join remaining fields just in case
   instrument = parts[8];
   for(int i=9;i<n;i++)
      instrument += ("," + parts[i]);

   return true;
}

//==============================
// Action mapping
// 1=LongEntry1, 2=LongEntry2, 3=ShortEntry1, 4=ShortEntry2
// 5/6 ignored
//==============================
bool ActionToDirection(const int action, int &dir /*+1 buy, -1 sell*/, bool &isEntry2)
{
   isEntry2 = false;

   if(action == 1) { dir = +1; isEntry2 = false; return true; }
   if(action == 2) { dir = +1; isEntry2 = true;  return true; }
   if(action == 3) { dir = -1; isEntry2 = false; return true; }
   if(action == 4) { dir = -1; isEntry2 = true;  return true; }

   return false;
}

//==============================
// Execution
//==============================
void ExecuteSignal(const string mt5Symbol,
                   const int action,
                   const int qty,
                   const int slPoints,
                   const int ptPoints,
                   const double confidence,
                   const string source,
                   const string ntInstrument)
{
   // Check profit/loss protection first
   if(stopTradingForDay)
   {
      PrintFormat("[DROP] Daily loss limit reached. Trading stopped for the day.");
      return;
   }
   
   if(stopTradingForProfitProtection)
   {
      PrintFormat("[DROP] Profit protection activated. Trading stopped for the day.");
      return;
   }
   
   // Apply per-instrument quantity multiplier
   double multiplier = GetQuantityMultiplier(ntInstrument);
   double adjustedQty = qty * multiplier;
   if(adjustedQty < 0.01) adjustedQty = 0.01;  // Minimum lot size
   
   // Basic validations
   if(mt5Symbol == "" || adjustedQty <= 0)
   {
      PrintFormat("[DROP] invalid mt5Symbol/qty. mt5Symbol='%s' qty=%.2f (orig=%d mult=%.2f inst=%s)", mt5Symbol, adjustedQty, qty, multiplier, ntInstrument);
      return;
   }

   if(!SymbolSelect(mt5Symbol, true))
   {
      PrintFormat("[DROP] SymbolSelect failed for '%s' (mapped from %s)", mt5Symbol, ntInstrument);
      return;
   }

   // Confidence filter
   if(confidence < MinConfidence)
   {
      PrintFormat("[DROP] confidence %.2f < %.2f (src=%s mt5=%s)", confidence, MinConfidence, source, mt5Symbol);
      return;
   }

   int dir;
   bool isEntry2;
   if(!ActionToDirection(action, dir, isEntry2))
   {
      // includes 5/6 etc.
      return;
   }

   // Cooldown per symbol+direction - enforce for ALL signals including reverse
   if(CooldownSeconds > 0 && IsInCooldown(mt5Symbol, dir))
   {
      PrintFormat("[DROP] cooldown active (mt5=%s dir=%s)", mt5Symbol, dir>0?"BUY":"SELL");
      return;
   }

   // Check if there are opposite positions that need to be closed (reverse signal)
   int oppositeCount = CountPositionsForSymbolByDirection(mt5Symbol, -dir);
   if(oppositeCount > 0)
   {
      PrintFormat("[REVERSE] Detected reverse signal for %s - closing %d opposite %s position(s)",
                  mt5Symbol, oppositeCount, (dir<0?"BUY":"SELL"));
      CloseOppositePositions(mt5Symbol, dir);
   }

   // Max positions per symbol - only count positions in the SAME direction
   // For reverse signals, we've already closed opposite positions above
   int sameDirCount = CountPositionsForSymbolByDirection(mt5Symbol, dir);
   if(sameDirCount >= MaxPositionsPerSymbol)
   {
      PrintFormat("[DROP] max positions reached: %s %s positions=%d max=%d",
                  mt5Symbol, (dir>0?"BUY":"SELL"), sameDirCount, MaxPositionsPerSymbol);
      return;
   }

   // Rate limiter
   if(!RateLimitAllowTrade())
   {
      PrintFormat("[DROP] max trades per minute reached (mt5=%s)", mt5Symbol);
      return;
   }

   // Market prices
   double bid = SymbolInfoDouble(mt5Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(mt5Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
   {
      PrintFormat("[DROP] invalid bid/ask for %s (bid=%.5f ask=%.5f)", mt5Symbol, bid, ask);
      return;
   }

   // Convert points -> price levels
   // slPoints/ptPoints already in MT5 points (from DLL conversion)
   double sl = 0.0;
   double tp = 0.0;

   if(slPoints > 0)
   {
      if(dir > 0) sl = bid - slPoints * _Point;
      else        sl = ask + slPoints * _Point;
      sl = NormalizePrice(mt5Symbol, sl);
   }

   // Set TP for all entry signals when ptPoints is provided
   if(ptPoints > 0)
   {
      if(dir > 0) tp = bid + ptPoints * _Point;
      else        tp = ask - ptPoints * _Point;
      tp = NormalizePrice(mt5Symbol, tp);
   }

   // Configure trade object
   trade.SetDeviationInPoints(SlippagePoints);

   string comment = StringFormat("%s|a=%d|c=%.2f|nt=%s", source, action, confidence, ntInstrument);

   // DryRun or live
   if(DryRun || !EnableTrading)
   {
      PrintFormat("[DRYRUN] %s %s qty=%.2f slPts=%d tpPts=%d SL=%.5f TP=%.5f comment=%s",
                  (dir>0?"BUY":"SELL"), mt5Symbol, adjustedQty, slPoints, ptPoints, sl, tp, comment);
      // even in dryrun, set cooldown to avoid log spam / repeated execution simulation
      if(CooldownSeconds > 0) SetCooldown(mt5Symbol, dir);
      return;
   }

   bool ok = false;
   if(dir > 0)
      ok = trade.Buy(adjustedQty, mt5Symbol, 0.0, sl, tp, comment);
   else
      ok = trade.Sell(adjustedQty, mt5Symbol, 0.0, sl, tp, comment);

   if(!ok)
   {
      int ec = (int)GetLastError();
      PrintFormat("[ORDER_FAIL] %s %s qty=%.2f err=%d",
                  (dir>0?"BUY":"SELL"), mt5Symbol, adjustedQty, ec);
      return;
   }

   PrintFormat("[ORDER_OK] %s %s qty=%.2f SL=%.5f TP=%.5f (src=%s a=%d conf=%.2f)",
               (dir>0?"BUY":"SELL"), mt5Symbol, adjustedQty, sl, tp, source, action, confidence);

   // Show alert if enabled
   if(ShowAlerts)
   {
      string alertMessage = StringFormat("[POSITION OPENED]\n%s %s\nQuantity: %.2f\nSL: %.5f\nTP: %.5f",
                                         (dir>0?"BUY":"SELL"), mt5Symbol, adjustedQty, sl, tp);
      Alert(alertMessage);
   }

   if(CooldownSeconds > 0) SetCooldown(mt5Symbol, dir);
}

//==============================
// MT5 lifecycle
//==============================
int OnInit()
{
   // Parse per-instrument quantity multipliers
   ParseQuantityMultipliers();
   
   // Start Aeron bridge
   int ok = AeronBridge_StartW(AeronDir, AeronChannel, AeronStreamId, AeronTimeoutMs);
   if(!ok)
   {
      int n = AeronBridge_LastError(g_errBuf, ArraySize(g_errBuf));
      Print("Aeron start failed: ", CharArrayToString(g_errBuf, 0, n));
      return INIT_FAILED;
   }

   EventSetTimer(TimerSeconds);
   Print("AeronAutoTraderEA ready. DryRun=", (DryRun?"true":"false"),
         " EnableTrading=", (EnableTrading?"true":"false"));
   return INIT_SUCCEEDED;
}

void OnTimer()
{
   // Check profit/loss protection limits
   CheckDailyLossLimit();
   CheckDailyProfitProtection();
   
   // Poll Aeron
   AeronBridge_Poll();

   // Drain up to MaxSignalsPerTimer
   for(int i=0;i<MaxSignalsPerTimer;i++)
   {
      if(!AeronBridge_HasSignal())
         break;

      int n = AeronBridge_GetSignalCsv(g_csvBuf, ArraySize(g_csvBuf));
      if(n <= 0)
         break;

      string csv = CharArrayToString(g_csvBuf, 0, n);

      int action, qty, slPts, ptPts;
      double conf;
      string sym, mt5sym, src, inst;

      if(!SplitCsv9(csv, action, qty, slPts, ptPts, conf, sym, mt5sym, src, inst))
      {
         Print("[DROP] bad CSV: ", csv);
         continue;
      }

      // Log all received signals for debugging
      PrintFormat("[SIGNAL] action=%d qty=%d slPts=%d ptPts=%d conf=%.2f mt5=%s src=%s",
                  action, qty, slPts, ptPts, conf, mt5sym, src);

      // EA-level defense: ignore exit actions too
      if(action == 5 || action == 6)
         continue;

      ExecuteSignal(mt5sym, action, qty, slPts, ptPts, conf, src, inst);
   }
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   AeronBridge_Stop();
   Print("AeronAutoTraderEA stopped.");
}
