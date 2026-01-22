# Multi-Broker Symbol Mapping - Quick Start

## The Problem You're Solving

You have **one signal source** (NinjaTrader publishing "YM MAR 26") but **multiple MT5 brokers** with different symbol names:

- Broker A calls it "DJ30"
- Broker B calls it "US30"
- Broker C calls it something else

**How do you handle this with a single DLL?**

## The Solution

✅ The **DLL supports runtime symbol mapping** - each MT5 terminal registers its own broker-specific mappings at startup.

## Implementation (Choose One)

### Option 1: Quick Setup (Broker Profile)

```mql5
// Just select your broker profile
input ENUM_BROKER_PROFILE BrokerProfile = BROKER_PROFILE_A;
```

**Available Profiles:**

- `BROKER_PROFILE_A`: DJ30, SPX500, NAS100
- `BROKER_PROFILE_B`: US30, US500, USTEC
- `BROKER_PROFILE_C`: Futures-style (YMH25, ESH25)

### Option 2: CSV Configuration File

Create `broker_mappings.csv`:

```csv
FutPrefix,MT5Symbol,TickSize,PointSize
YM,DJ30,1.0,0.1
ES,SPX500,0.25,0.1
NQ,NAS100,0.25,0.1
```

Then in your EA:

```mql5
input string CustomMappingFile = "broker_mappings.csv";
```

### Option 3: Manual Registration

```mql5
int OnInit()
{
   // Register your broker's symbols
   AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1);
   AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1);
   AeronBridge_RegisterInstrumentMapW("NQ", "NAS100", 0.25, 0.1);

   // Start the bridge
   AeronBridge_StartW(AeronDir, AeronChannel, AeronStreamId, AeronTimeoutMs);

   return INIT_SUCCEEDED;
}
```

## Files in This Solution

| File                               | Purpose                                 |
| ---------------------------------- | --------------------------------------- |
| **BROKER_SYMBOL_MAPPING_GUIDE.md** | 📖 Complete guide with all details      |
| **BrokerMappings.mqh**             | 🛠️ Helper functions for symbol mapping  |
| **AeronBridgeMultiBroker.mq5**     | 📝 Example EA with multi-broker support |
| **broker_a_mappings.csv**          | 📄 Example config for Broker A          |
| **broker_b_mappings.csv**          | 📄 Example config for Broker B          |
| **CONFIG_EXAMPLES.md**             | 💡 Usage examples and reference         |
| **ARCHITECTURE_DIAGRAM.md**        | 📊 Visual architecture overview         |

## Quick Test

1. **Copy files to MT5:**

   - `BrokerMappings.mqh` → `MQL5/Include/`
   - `AeronBridgeMultiBroker.mq5` → `MQL5/Experts/`
   - `broker_a_mappings.csv` → `MQL5/Files/`

2. **Configure the EA:**

   ```
   BrokerProfile = BROKER_PROFILE_A (or use CustomMappingFile)
   DryRun = true (for testing)
   AeronChannel = "aeron:udp?endpoint=192.168.2.15:40123"
   ```

3. **Run and check logs:**

   ```
   Loading Broker A symbol mappings...
   Registered: YM -> DJ30 (TickSize=1.00000, PointSize=0.10000)
   Registered: ES -> SPX500 (TickSize=0.25000, PointSize=0.10000)
   ...
   Aeron subscription started successfully
   ```

4. **Send a test signal:**
   - Signal arrives: "YM MAR 26(YM)"
   - EA receives: "mt5_symbol: DJ30" ✅

## How It Works

```
Signal "YM MAR 26"
    ↓
DLL extracts prefix "YM"
    ↓
DLL looks up "YM" in mapping table
    ↓
Terminal 1: "YM" → "DJ30" (Broker A)
Terminal 2: "YM" → "US30" (Broker B)
    ↓
Each EA trades with its broker's symbol
```

## Benefits

✅ **One DLL** for all brokers  
✅ **No code changes** to add new broker support  
✅ **Easy deployment** - just change configuration  
✅ **Type-safe** - automatic tick/point conversion  
✅ **Flexible** - multiple configuration methods

## Next Steps

1. ✅ Read [BROKER_SYMBOL_MAPPING_GUIDE.md](BROKER_SYMBOL_MAPPING_GUIDE.md) for complete details
2. ✅ Check [CONFIG_EXAMPLES.md](CONFIG_EXAMPLES.md) for common mappings
3. ✅ Use [BrokerMappings.mqh](BrokerMappings.mqh) in your EA
4. ✅ Test with [AeronBridgeMultiBroker.mq5](AeronBridgeMultiBroker.mq5)

## Finding Your Broker's Symbols

Open MT5 Market Watch and search for:

- Dow Jones: Look for "DJ30", "US30", "YM", "DOW"
- S&P 500: Look for "SPX500", "US500", "ES", "SP500"
- NASDAQ: Look for "NAS100", "USTEC", "NQ", "NDX"

Then add them to your mapping configuration!

## Questions?

- **Q: Do I need different DLL files for different brokers?**  
  A: No! The same DLL works for all brokers. Just configure the mappings.

- **Q: Can I change mappings without recompiling?**  
  A: Yes! Use CSV files or EA input parameters.

- **Q: What if my broker uses completely different names?**  
  A: Just add your mappings - the system supports any symbol name.

- **Q: Does this work with multiple MT5 terminals on one machine?**  
  A: Yes! Each terminal loads its own DLL instance with independent configuration.

---

**Ready to go?** Start with [BROKER_SYMBOL_MAPPING_GUIDE.md](BROKER_SYMBOL_MAPPING_GUIDE.md) for the full picture! 🚀
