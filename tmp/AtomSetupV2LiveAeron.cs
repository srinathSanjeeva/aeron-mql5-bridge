#region Using declarations
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.ComponentModel.DataAnnotations;
using NinjaTrader.Cbi;
using NinjaTrader.Data;
using NinjaTrader.NinjaScript;
using NinjaTrader.NinjaScript.Indicators;
using NinjaTrader.NinjaScript.Common;
using Newtonsoft.Json;

// Aeron + Agrona (.NET)
using Adaptive.Aeron;
using Adaptive.Aeron.LogBuffer;
using Adaptive.Agrona.Concurrent;
using Adaptive.Agrona;
#endregion

namespace NinjaTrader.NinjaScript.Strategies
{
    public class AtomSetupV2LiveAeron : Strategy
    {
        private DeMarkSequentialSignalV2Fast tdIndicator;
        private AeronSignalPublisher ipcPublisher;
        private AeronSignalPublisher udpPublisher;
        private bool isRealtime = false;
        private static Dictionary<string, TradingHoursResponse> tradingHoursCache = new Dictionary<string, TradingHoursResponse>();

        // Cached time control variables to avoid repeated property access
        private TimeSpan cachedStartTime;
        private TimeSpan cachedEndTime;

        // Entry names constants
        private const string LongEntry1 = "Long_TD_1";
        private const string LongEntry2 = "Long_TD_2";
        private const string ShortEntry1 = "Short_TD_1";
        private const string ShortEntry2 = "Short_TD_2";

        // Cached properties to avoid repeated property access
        private double cachedBodyMultiplier;
        private bool cachedExitAfterTD9;
        private bool cachedRequirePerfection;
        private int cachedStopLossTicks;
        private int cachedProfitOffsetTicks;

        // Live trading safety features
        private int maxTradesPerDay = 1000;
        private int tradesPlacedToday = 0;
        private DateTime lastTradeDate = DateTime.MinValue;
        private double maxDailyLoss = 50000.0; // Default $500 max daily loss
        private double dailyPnL = 0.0;
        private DateTime currentDay = DateTime.MinValue;

        // Instance protection - now per instrument AND account instead of just per instrument
        private static readonly object instanceLock = new object();
        private static readonly System.Collections.Generic.Dictionary<string, bool> runningInstances = new System.Collections.Generic.Dictionary<string, bool>();
        private bool thisInstanceActive = false;
        private string accountInstrumentKey;

        // Bar-level trade tracking to prevent multiple trades on same bar
        private int lastTradeBarNumber = -1;
        private DateTime lastTradeTime = DateTime.MinValue;

        private static readonly TimeZoneInfo EstTimeZone =
            TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time");

        #region NinjaScript Properties - Trading Parameters

        [NinjaScriptProperty]
        [Range(1, 2.0)]
        [Display(Name = "Body Size Multiplier", Order = 1, GroupName = "TD Sequential")]
        public double BodyMultiplier { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Exit After TD9", Order = 2, GroupName = "TD Sequential")]
        public bool ExitAfterTD9 { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Require Perfection for TD9", Order = 3, GroupName = "TD Sequential")]
        public bool RequirePerfection { get; set; }

        [NinjaScriptProperty]
        [Range(1, 100)]
        [Display(Name = "Stop Loss (Ticks)", Order = 4, GroupName = "Risk Management")]
        public int StopLossTicks { get; set; }

        [NinjaScriptProperty]
        [Range(1, 200)]
        [Display(Name = "Profit Offset (Ticks)", Order = 5, GroupName = "Risk Management")]
        public int ProfitOffsetTicks { get; set; }

        [NinjaScriptProperty]
        [Range(1, int.MaxValue)]
        [Display(Name = "UNITS", Order = 6, GroupName = "Risk Management")]
        public int UNITS { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Use API for Trading Hours", Description = "Fetch trading hours from API instead of manual settings", Order = 7, GroupName = "Trading Hours")]
        public bool UseApiForTradingHours { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "API Base URL", Description = "Base URL for trading hours API", Order = 8, GroupName = "Trading Hours")]
        public string ApiBaseUrl { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Is Micros", Description = "Set to true for micro contracts (e.g., MES, MNQ)", Order = 9, GroupName = "Trading Hours")]
        public bool IsMicros { get; set; }

        [NinjaScriptProperty]
        [Range(0, 23)]
        [Display(Name = "Start Time Hour (Manual)", Order = 10, GroupName = "Trading Hours")]
        public int StartTimeHour { get; set; }

        [NinjaScriptProperty]
        [Range(0, 59)]
        [Display(Name = "Start Time Minute (Manual)", Order = 11, GroupName = "Trading Hours")]
        public int StartTimeMinute { get; set; }

        [NinjaScriptProperty]
        [Range(0, 23)]
        [Display(Name = "End Time Hour (Manual)", Order = 12, GroupName = "Trading Hours")]
        public int EndTimeHour { get; set; }

        [NinjaScriptProperty]
        [Range(0, 59)]
        [Display(Name = "End Time Minute (Manual)", Order = 13, GroupName = "Trading Hours")]
        public int EndTimeMinute { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Enable Trading Hours", Order = 14, GroupName = "Trading Hours")]
        public bool EnableTradingHours { get; set; }

        // Live Trading Safety Parameters
        [NinjaScriptProperty]
        [Range(1, 1000)]
        [Display(Name = "Max Trades Per Day", Description = "Maximum number of trades allowed per day", Order = 15, GroupName = "Live Trading Safety")]
        public int MaxTradesPerDay
        {
            get { return maxTradesPerDay; }
            set { maxTradesPerDay = value; }
        }

        [NinjaScriptProperty]
        [Range(100.0, 50000.0)]
        [Display(Name = "Max Daily Loss", Description = "Maximum daily loss before stopping trading", Order = 16, GroupName = "Live Trading Safety")]
        public double MaxDailyLoss
        {
            get { return maxDailyLoss; }
            set { maxDailyLoss = value; }
        }

        [NinjaScriptProperty]
        [Display(Name = "Enable Live Trading Safety", Description = "Enable daily loss and trade count limits", Order = 17, GroupName = "Live Trading Safety")]
        public bool EnableLiveTradingSafety { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Flatten at End of Session", Description = "Close all positions before session end", Order = 18, GroupName = "Live Trading Safety")]
        public bool FlattenAtEndOfSession { get; set; }

        [NinjaScriptProperty]
        [Range(1, 120)]
        [Display(Name = "Minutes Before Session End", Description = "How many minutes before session end to flatten positions", Order = 19, GroupName = "Live Trading Safety")]
        public int MinutesBeforeSessionEnd { get; set; }

        #endregion

        #region NinjaScript Properties - Aeron Configuration

        [NinjaScriptProperty]
        [Display(Name = "Aeron Publish Mode", GroupName = "Aeron", Order = 30)]
        public AeronPublishMode PublishMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "IPC Channel", GroupName = "Aeron", Order = 31)]
        public string IpcChannel { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "UDP Channel", GroupName = "Aeron", Order = 32)]
        public string UdpChannel { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Aeron Stream ID", GroupName = "Aeron", Order = 33)]
        public int AeronStreamId { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Source Strategy Tag", GroupName = "Aeron", Order = 34)]
        public string SourceStrategyTag { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Aeron Directory", GroupName = "Aeron", Order = 35)]
        public string AeronDirectory { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Emit Historical Signals", Description = "Allow emitting signals from historical bars (before real-time). False = only emit live signals.", GroupName = "Aeron", Order = 36)]
        public bool EmitHistoricalSignals { get; set; }

        #endregion

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Description = @"Live trading version of AtomSetupV2 with Aeron signal emission, safety features, and optimizations for real-time execution.";
                Name = "AtomSetupV2LiveAeron";
                Calculate = Calculate.OnBarClose;
                EntriesPerDirection = 2;
                EntryHandling = EntryHandling.AllEntries;
                IsExitOnSessionCloseStrategy = true;
                ExitOnSessionCloseSeconds = 120;
                IsFillLimitOnTouch = false;
                MaximumBarsLookBack = MaximumBarsLookBack.TwoHundredFiftySix;
                OrderFillResolution = OrderFillResolution.Standard;
                Slippage = 1; // Add 1 tick slippage for live trading realism
                StartBehavior = StartBehavior.WaitUntilFlat;
                TimeInForce = TimeInForce.Gtc;
                TraceOrders = true; // Enable for live trading monitoring
                RealtimeErrorHandling = RealtimeErrorHandling.StopCancelClose;
                StopTargetHandling = StopTargetHandling.PerEntryExecution;
                BarsRequiredToTrade = 10;
                IsInstantiatedOnEachOptimizationIteration = false;

                // Default values
                BodyMultiplier = 1.8;
                ExitAfterTD9 = false;
                RequirePerfection = true;
                StopLossTicks = 35;
                ProfitOffsetTicks = 30;
                UNITS = 1;
                UseApiForTradingHours = false;
                ApiBaseUrl = "http://Moonshots:8000";
                IsMicros = false;
                StartTimeHour = 8;
                StartTimeMinute = 31;
                EndTimeHour = 16;
                EndTimeMinute = 0;
                EnableTradingHours = true;

                // Live trading safety defaults
                MaxTradesPerDay = 1000;
                MaxDailyLoss = 50000.0;
                EnableLiveTradingSafety = false;
                FlattenAtEndOfSession = true;
                MinutesBeforeSessionEnd = 15; // Default to 15 minutes before session end

                // Aeron defaults
                PublishMode = AeronPublishMode.IpcAndUdp;
                IpcChannel = "aeron:ipc";
                UdpChannel = "aeron:udp?endpoint=127.0.0.1:40123";
                AeronStreamId = 1002; // Different from SecretEye to avoid conflicts
                SourceStrategyTag = "AtomSetupV2Aeron";
                AeronDirectory = ""; // empty = Aeron default
                EmitHistoricalSignals = false; // Skip past signals by default
            }
            else if (State == State.DataLoaded)
            {
                // Instance protection - prevent multiple instances from running on the same instrument
                lock (instanceLock)
                {
                    accountInstrumentKey = Account.Name + Instrument.FullName; // Use account and instrument's full name as key
                    if (runningInstances.ContainsKey(accountInstrumentKey) && runningInstances[accountInstrumentKey])
                    {
                        Print($"WARNING: Another instance of AtomSetupV2LiveAeron is already running for this instrument. This instance will be disabled.");
                        return;
                    }
                    runningInstances[accountInstrumentKey] = true;
                    thisInstanceActive = true;
                    Print($"AtomSetupV2LiveAeron instance activated - ID: {GetHashCode()} for {Instrument.FullName}");
                }

                // Cache frequently used values
                CacheProperties();

                // Use the fast version of the indicator
                tdIndicator = DeMarkSequentialSignalV2Fast(cachedBodyMultiplier, cachedExitAfterTD9, cachedRequirePerfection);

                // Add indicator to chart for live trading visibility
                AddChartIndicator(tdIndicator);

                // Set stop losses and profit targets
                SetStopLoss(LongEntry1, CalculationMode.Ticks, StopLossTicks, true);
                SetStopLoss(LongEntry2, CalculationMode.Ticks, StopLossTicks, true);
                SetStopLoss(ShortEntry1, CalculationMode.Ticks, StopLossTicks, true);
                SetStopLoss(ShortEntry2, CalculationMode.Ticks, StopLossTicks, true);

                SetProfitTarget(LongEntry2, CalculationMode.Ticks, StopLossTicks + ProfitOffsetTicks);
                SetProfitTarget(ShortEntry2, CalculationMode.Ticks, StopLossTicks + ProfitOffsetTicks);

                // Initialize Aeron publishers
                if (PublishMode != AeronPublishMode.None)
                {
                    if (PublishMode == AeronPublishMode.IpcOnly ||
                        PublishMode == AeronPublishMode.IpcAndUdp)
                    {
                        ipcPublisher = new AeronSignalPublisher(
                            AeronDirectory,
                            IpcChannel,
                            AeronStreamId,
                            SourceStrategyTag,
                            Print
                        );
                        ipcPublisher.Start();
                    }

                    if (PublishMode == AeronPublishMode.UdpOnly ||
                        PublishMode == AeronPublishMode.IpcAndUdp)
                    {
                        udpPublisher = new AeronSignalPublisher(
                            AeronDirectory,
                            UdpChannel,
                            AeronStreamId,
                            SourceStrategyTag,
                            Print
                        );
                        udpPublisher.Start();
                    }
                }

                Print($"AtomSetupV2LiveAeron initialized - Max Daily Loss: ${MaxDailyLoss}, Max Trades/Day: {MaxTradesPerDay}, Aeron Mode: {PublishMode}");
            }
            else if (State == State.Realtime)
            {
                // Mark that we've transitioned to real-time
                isRealtime = true;
            }
            else if (State == State.Terminated)
            {
                // Dispose Aeron publishers
                ipcPublisher?.Dispose();
                udpPublisher?.Dispose();

                ipcPublisher = null;
                udpPublisher = null;

                // Release instance lock when strategy terminates
                if (thisInstanceActive)
                {
                    lock (instanceLock)
                    {
                        runningInstances[accountInstrumentKey] = false;
                        thisInstanceActive = false;
                        Print($"AtomSetupV2LiveAeron instance deactivated - ID: {GetHashCode()} for {Instrument.FullName}");
                    }
                }
                Print($"AtomSetupV2LiveAeron terminated - Trades today: {tradesPlacedToday}, Daily P&L: ${dailyPnL:F2}");
            }
        }

        protected override void OnBarUpdate()
        {
            // Early exit conditions
            if (CurrentBar < 10)
                return;

            // Check if we're within trading hours
            if (EnableTradingHours && !IsWithinTradingHours())
                return;

            // Live trading safety checks
            if (EnableLiveTradingSafety && !PassesLiveTradingSafetyChecks())
                return;

            // Get indicator signals
            double buySignal = tdIndicator.GetBuySignalSeries()[0];
            double sellSignal = tdIndicator.GetSellSignalSeries()[0];

            // --- SHORT SIGNAL LOGIC ---
            if (buySignal == -1) // Signal to be SHORT
            {
                // If we are not already in a short position, enter one.
                // NinjaTrader will automatically handle reversing from a long position if necessary.
                if (Position.MarketPosition != MarketPosition.Short)
                {
                    EnterShort(Convert.ToInt32(UNITS), ShortEntry1);
                    EnterShort(Convert.ToInt32(UNITS), ShortEntry2);

                    // Publish Aeron signals - only if configured to emit historical signals OR we're in real-time
                    if (EmitHistoricalSignals || isRealtime)
                    {
                        PublishSignal(StrategyAction.ShortEntry1);
                        PublishSignal(StrategyAction.ShortEntry2);
                    }

                    IncrementTradeCount();
                    lastTradeBarNumber = CurrentBar;
                    Print($"AtomSetupV2LiveAeron - SHORT signal received. Entering/reversing to SHORT at {Close[0]:F2}");
                }
            }
            // --- LONG SIGNAL LOGIC ---
            else if (sellSignal == 1) // Signal to be LONG
            {
                // If we are not already in a long position, enter one.
                // NinjaTrader will automatically handle reversing from a short position if necessary.
                if (Position.MarketPosition != MarketPosition.Long)
                {
                    EnterLong(Convert.ToInt32(UNITS), LongEntry1);
                    EnterLong(Convert.ToInt32(UNITS), LongEntry2);

                    // Publish Aeron signals - only if configured to emit historical signals OR we're in real-time
                    if (EmitHistoricalSignals || isRealtime)
                    {
                        PublishSignal(StrategyAction.LongEntry1);
                        PublishSignal(StrategyAction.LongEntry2);
                    }

                    IncrementTradeCount();
                    lastTradeBarNumber = CurrentBar;
                    Print($"AtomSetupV2LiveAeron - LONG signal received. Entering/reversing to LONG at {Close[0]:F2}");
                }
            }

            // Flatten positions near end of session if enabled
            if (FlattenAtEndOfSession && ShouldFlattenForEndOfSession())
            {
                if (Position.MarketPosition != MarketPosition.Flat)
                {
                    if (Position.MarketPosition == MarketPosition.Long)
                    {
                        ExitLong();
                        if (EmitHistoricalSignals || isRealtime)
                        {
                            PublishSignal(StrategyAction.LongExit);
                        }
                    }
                    else if (Position.MarketPosition == MarketPosition.Short)
                    {
                        ExitShort();
                        if (EmitHistoricalSignals || isRealtime)
                        {
                            PublishSignal(StrategyAction.ShortExit);
                        }
                    }

                    Print($"AtomSetupV2LiveAeron - Flattening position for end of session");
                }
            }
        }

        protected override void OnExecutionUpdate(Execution execution, string executionId, double price, int quantity, MarketPosition marketPosition, string orderId, DateTime time)
        {
            // Track daily P&L for safety monitoring
            if (execution.Order.OrderState == OrderState.Filled)
            {
                UpdateDailyPnL();
                Print($"AtomSetupV2LiveAeron - Execution: {execution.Order.OrderAction} {Math.Abs(quantity)} @ {price:F2} - Daily P&L: ${dailyPnL:F2}");

                // Publish Aeron signals for stop loss and profit target hits
                if (execution.Order.Name != null && (EmitHistoricalSignals || isRealtime))
                {
                    // Check if this is a stop loss order
                    if (execution.Order.Name.Contains("Stop") || execution.Order.OrderType == OrderType.StopMarket)
                    {
                        if (execution.Order.OrderAction == OrderAction.Sell) // Long stop loss
                        {
                            PublishSignal(StrategyAction.LongStopLoss);
                            Print($"AtomSetupV2LiveAeron - Long Stop Loss hit @ {price:F2}");
                        }
                        else if (execution.Order.OrderAction == OrderAction.BuyToCover) // Short stop loss
                        {
                            PublishSignal(StrategyAction.ShortStopLoss);
                            Print($"AtomSetupV2LiveAeron - Short Stop Loss hit @ {price:F2}");
                        }
                    }
                    // Check if this is a profit target order
                    else if (execution.Order.Name.Contains("Target") || execution.Order.Name.Contains("Profit") || execution.Order.OrderType == OrderType.Limit)
                    {
                        PublishSignal(StrategyAction.ProfitTarget);
                        Print($"AtomSetupV2LiveAeron - Profit Target hit @ {price:F2}");
                    }
                }
            }
        }

        private void PublishSignal(StrategyAction action)
        {
            if (PublishMode == AeronPublishMode.None || (ipcPublisher == null && udpPublisher == null))
                return;

            string symbol = Instrument.MasterInstrument.Name;
            if (string.IsNullOrWhiteSpace(symbol))
                return;

            int longSL = 0, shortSL = 0, profitTarget = 0;

            switch (action)
            {
                case StrategyAction.LongEntry1:
                case StrategyAction.LongEntry2:
                    longSL = StopLossTicks;
                    profitTarget = action == StrategyAction.LongEntry2
                        ? StopLossTicks + ProfitOffsetTicks : 0;
                    break;

                case StrategyAction.ShortEntry1:
                case StrategyAction.ShortEntry2:
                    shortSL = StopLossTicks;
                    profitTarget = action == StrategyAction.ShortEntry2
                        ? StopLossTicks + ProfitOffsetTicks : 0;
                    break;

                case StrategyAction.LongExit:
                case StrategyAction.ShortExit:
                case StrategyAction.LongStopLoss:
                case StrategyAction.ShortStopLoss:
                case StrategyAction.ProfitTarget:
                    // Exit and notification signals don't need SL/PT
                    longSL = 0;
                    shortSL = 0;
                    profitTarget = 0;
                    break;
            }

            // Use bar range as simple confidence metric (normalized)
            float confidence = CurrentBar >= 1 ? (float)Math.Min((High[0] - Low[0]) / TickSize, 100) : 50.0f;

            ipcPublisher?.TryPublish(
                symbol,
                Instrument.FullName,
                action,
                longSL,
                shortSL,
                profitTarget,
                UNITS,
                confidence
            );

            udpPublisher?.TryPublish(
                symbol,
                Instrument.FullName,
                action,
                longSL,
                shortSL,
                profitTarget,
                UNITS,
                confidence
            );
        }

        private bool PassesLiveTradingSafetyChecks()
        {
            // Check if it's a new trading day
            DateTime today = DateTime.Today;
            if (today != currentDay)
            {
                // Reset daily counters
                currentDay = today;
                tradesPlacedToday = 0;
                dailyPnL = 0.0;
                Print($"AtomSetupV2LiveAeron - New trading day: {today:yyyy-MM-dd} - Counters reset");
            }

            // Check max trades per day
            if (tradesPlacedToday >= MaxTradesPerDay)
            {
                Print($"AtomSetupV2LiveAeron - Max trades per day ({MaxTradesPerDay}) reached. No more trades today.");
                return false;
            }

            // Check daily loss limit
            if (Math.Abs(dailyPnL) >= MaxDailyLoss && dailyPnL < 0)
            {
                Print($"AtomSetupV2LiveAeron - Daily loss limit (${MaxDailyLoss}) reached. P&L: ${dailyPnL:F2}. No more trades today.");
                return false;
            }

            return true;
        }

        private void IncrementTradeCount()
        {
            tradesPlacedToday++;
            Print($"AtomSetupV2LiveAeron - Trade count: {tradesPlacedToday}/{MaxTradesPerDay}");
        }

        private void UpdateDailyPnL()
        {
            // Simple approximation of daily P&L based on current unrealized P&L
            dailyPnL = Position.GetUnrealizedProfitLoss(PerformanceUnit.Currency, Close[0]);
        }

        private bool ShouldFlattenForEndOfSession()
        {
            TimeSpan currentTime = Time[0].TimeOfDay;
            TimeSpan endTime = new TimeSpan(EndTimeHour, EndTimeMinute, 0);
            TimeSpan flattenTime = endTime.Subtract(TimeSpan.FromMinutes(MinutesBeforeSessionEnd)); // Flatten X minutes before session end

            return currentTime >= flattenTime && currentTime <= endTime;
        }

        private bool IsWithinTradingHours()
        {
            if (UseApiForTradingHours)
            {
                return IsWithinApiTradingHours();
            }
            else
            {
                return IsWithinManualTradingHours();
            }
        }

        private bool IsWithinApiTradingHours()
        {
            string currentDayOfWeek = Times[0][0].DayOfWeek.ToString().ToLower();
            string symbolPrefix = Instrument.MasterInstrument.Name;

            // Handle Sunday evening -> Monday session mapping for futures
            if (currentDayOfWeek == "sunday" && Times[0][0].TimeOfDay.TotalHours >= 17)
            {
                currentDayOfWeek = "monday";
                Print($"🔄 Mapping Sunday evening to Monday trading session");
            }

            // Handle micros
            if (IsMicros && symbolPrefix.Length >= 3)
                symbolPrefix = symbolPrefix.Substring(1, 2);
            else if (symbolPrefix.Length >= 2)
                symbolPrefix = symbolPrefix.Substring(0, 2);

            string dailyCacheKey = $"{symbolPrefix}_{Times[0][0].Date:yyyy-MM-dd}";
            TradingHoursResponse hours = GetTradingHoursFromAPI(symbolPrefix, dailyCacheKey);

            if (hours == null)
            {
                Print($"⚠️ API call failed for {currentDayOfWeek}. Falling back to manual trading hours.");
                return IsWithinManualTradingHours();
            }

            if (hours.weekly_schedule == null || !hours.weekly_schedule.ContainsKey(currentDayOfWeek))
            {
                Print($"🚫 API returned successfully but no trading hours defined for {currentDayOfWeek}. NO TRADING.");
                return false;
            }

            try
            {
                TradingWindow window = hours.weekly_schedule[currentDayOfWeek];
                if (window == null || string.IsNullOrEmpty(window.start) || string.IsNullOrEmpty(window.end))
                {
                    Print($"🚫 API returned successfully but trading window for {currentDayOfWeek} is null/empty. NO TRADING.");
                    return false;
                }

                string[] startParts = window.start.Split(':');
                string[] endParts = window.end.Split(':');

                int startHour = int.Parse(startParts[0]);
                int startMinute = int.Parse(startParts[1]);
                int endHour = int.Parse(endParts[0]);
                int endMinute = int.Parse(endParts[1]);

                TimeSpan timeOfDay = Times[0][0].TimeOfDay;
                TimeSpan startTime = new TimeSpan(startHour, startMinute, 0);
                TimeSpan endTime = new TimeSpan(endHour, endMinute, 0);

                if (startTime <= endTime)
                    return timeOfDay >= startTime && timeOfDay <= endTime;
                else
                    return timeOfDay >= startTime || timeOfDay <= endTime;
            }
            catch (Exception ex)
            {
                Print($"❌ Error parsing API trading hours: {ex.Message}. Falling back to manual trading hours.");
                return IsWithinManualTradingHours();
            }
        }

        private bool IsWithinManualTradingHours()
        {
            TimeSpan currentTime = Time[0].TimeOfDay;

            // Handle normal trading session
            if (cachedStartTime <= cachedEndTime)
            {
                return currentTime >= cachedStartTime && currentTime <= cachedEndTime;
            }
            // Handle overnight trading session
            else
            {
                return currentTime >= cachedStartTime || currentTime <= cachedEndTime;
            }
        }

        private TradingHoursResponse GetTradingHoursFromAPI(string symbolPrefix, string cacheKey)
        {
            if (tradingHoursCache.ContainsKey(cacheKey))
            {
                Print($"✓ Using cached trading hours for {symbolPrefix}");
                return tradingHoursCache[cacheKey];
            }

            try
            {
                string url = $"{ApiBaseUrl}/api/trading-hours?symbol={symbolPrefix}_F";
                Print($"🌐 Attempting to fetch trading hours from: {url}");
                
                System.Net.HttpWebRequest request = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
                request.Method = "GET";
                request.ContentType = "application/json";
                request.Timeout = 5000;

                using (System.Net.WebResponse response = request.GetResponse())
                using (System.IO.Stream dataStream = response.GetResponseStream())
                using (System.IO.StreamReader reader = new System.IO.StreamReader(dataStream))
                {
                    string responseBody = reader.ReadToEnd();
                    Print($"📥 API Response received (length: {responseBody.Length} chars)");
                    
                    TradingHoursResponse result = JsonConvert.DeserializeObject<TradingHoursResponse>(responseBody);

                    if (result != null)
                    {
                        tradingHoursCache[cacheKey] = result;
                        Print($"✅ Successfully parsed trading hours from API for {symbolPrefix}");

                        if (result.weekly_schedule != null)
                        {
                            Print($"📅 Trading Hours for {result.symbol} (Timezone: {result.timezone}):");
                            foreach (var day in result.weekly_schedule)
                            {
                                if (day.Value != null && !string.IsNullOrEmpty(day.Value.start) && !string.IsNullOrEmpty(day.Value.end))
                                {
                                    Print($"  {day.Key.ToUpper()}: {day.Value.start} - {day.Value.end}");
                                }
                            }
                        }
                    }

                    return result;
                }
            }
            catch (System.Net.WebException webEx)
            {
                Print($"❌ Network error fetching trading hours: {webEx.Message}");
                return null;
            }
            catch (JsonException jsonEx)
            {
                Print($"❌ JSON parsing error: {jsonEx.Message}");
                return null;
            }
            catch (Exception ex)
            {
                Print($"❌ Unexpected error fetching trading hours: {ex.GetType().Name} - {ex.Message}");
                return null;
            }
        }

        private void CacheProperties()
        {
            cachedBodyMultiplier = BodyMultiplier;
            cachedExitAfterTD9 = ExitAfterTD9;
            cachedRequirePerfection = RequirePerfection;
            cachedStopLossTicks = StopLossTicks;
            cachedProfitOffsetTicks = ProfitOffsetTicks;
            cachedStartTime = new TimeSpan(StartTimeHour, StartTimeMinute, 0);
            cachedEndTime = new TimeSpan(EndTimeHour, EndTimeMinute, 0);
        }

        #region Properties Override
        public override string DisplayName
        {
            get { return "Atom Setup V2 Live Aeron"; }
        }
        #endregion
    }
}
