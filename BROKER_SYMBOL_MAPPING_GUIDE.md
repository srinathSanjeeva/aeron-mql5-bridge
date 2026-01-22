# Multi-Broker Symbol Mapping Guide

## Problem Statement

A single signal publisher sends futures signals (e.g., "YM MAR 26") but different MT5 brokers use different symbol names:

- **Broker A**: YM → `DJ30`
- **Broker B**: YM → `US30`
- **Broker C**: YM → `YM=H25` (different naming convention)

## Solution Architecture

The `AeronBridge.dll` uses a **runtime symbol mapping** system where each MT5 terminal registers its broker-specific symbol mappings during initialization.

### How It Works

1. **Signal arrives** with instrument "YM MAR 26(YM)"
2. **DLL extracts prefix** "YM" from instrument string
3. **DLL looks up** "YM" in the registered mapping table
4. **DLL converts** to broker-specific symbol (e.g., "DJ30" or "US30")
5. **DLL outputs** signal with the mapped symbol

## Implementation

### Step 1: Register Mappings in Each MT5 Terminal

Each broker's EA must call `AeronBridge_RegisterInstrumentMapW()` **before** calling `AeronBridge_StartW()`.

#### Example: Broker A (uses DJ30 for Dow Jones)

```mql5
int OnInit()
{
   // Register broker-specific mappings
   AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1);
   AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1);
   AeronBridge_RegisterInstrumentMapW("NQ", "NAS100", 0.25, 0.1);

   // Start Aeron subscription
   int result = AeronBridge_StartW(
       AeronDir,
       AeronChannel,
       AeronStreamId,
       AeronTimeoutMs
   );

   if(result == 0)
   {
      Print("Failed to start Aeron bridge");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}
```

#### Example: Broker B (uses US30 for Dow Jones)

```mql5
int OnInit()
{
   // Same code, different symbol mappings
   AeronBridge_RegisterInstrumentMapW("YM", "US30", 1.0, 0.1);  // Different!
   AeronBridge_RegisterInstrumentMapW("ES", "US500", 0.25, 0.1);
   AeronBridge_RegisterInstrumentMapW("NQ", "USTEC", 0.25, 0.1);

   int result = AeronBridge_StartW(
       AeronDir,
       AeronChannel,
       AeronStreamId,
       AeronTimeoutMs
   );

   return (result == 1) ? INIT_SUCCEEDED : INIT_FAILED;
}
```

### Step 2: Parameters Explained

```mql5
AeronBridge_RegisterInstrumentMapW(
    string futPrefix,      // Futures prefix: "YM", "ES", "NQ", etc.
    string mt5Symbol,      // Broker-specific MT5 symbol: "DJ30", "US30", etc.
    double futTickSize,    // Futures tick size: YM=1.0, ES=0.25, NQ=0.25
    double mt5PointSize    // Broker's point size: typically 0.1 for indices
)
```

### Step 3: Create Broker-Specific Configuration Files

To make deployment easier, create separate EA files or use input parameters:

#### Option A: Separate EA Files

```
AeronBridgeInt_BrokerA.mq5  // Hardcoded for Broker A symbols
AeronBridgeInt_BrokerB.mq5  // Hardcoded for Broker B symbols
```

#### Option B: Configuration Input (Recommended)

```mql5
// Add to inputs section
input string BrokerProfile = "BrokerA";  // "BrokerA", "BrokerB", "BrokerC"

void RegisterBrokerMappings()
{
   if(BrokerProfile == "BrokerA")
   {
      // Broker A: uses DJ30, SPX500, NAS100
      AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1);
      AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1);
      AeronBridge_RegisterInstrumentMapW("NQ", "NAS100", 0.25, 0.1);
   }
   else if(BrokerProfile == "BrokerB")
   {
      // Broker B: uses US30, US500, USTEC
      AeronBridge_RegisterInstrumentMapW("YM", "US30", 1.0, 0.1);
      AeronBridge_RegisterInstrumentMapW("ES", "US500", 0.25, 0.1);
      AeronBridge_RegisterInstrumentMapW("NQ", "USTEC", 0.25, 0.1);
   }
   else if(BrokerProfile == "BrokerC")
   {
      // Broker C: uses different convention
      AeronBridge_RegisterInstrumentMapW("YM", "YM=H25", 1.0, 0.01);
      AeronBridge_RegisterInstrumentMapW("ES", "ES=H25", 0.25, 0.01);
      AeronBridge_RegisterInstrumentMapW("NQ", "NQ=H25", 0.25, 0.01);
   }
   else
   {
      Print("Unknown broker profile: ", BrokerProfile);
      // Use defaults or fail
   }
}

int OnInit()
{
   RegisterBrokerMappings();

   int result = AeronBridge_StartW(
       AeronDir,
       AeronChannel,
       AeronStreamId,
       AeronTimeoutMs
   );

   return (result == 1) ? INIT_SUCCEEDED : INIT_FAILED;
}
```

## Complete Mapping Table Example

| Futures | Broker A | Broker B | Broker C | Tick Size | Point Size |
| ------- | -------- | -------- | -------- | --------- | ---------- |
| YM      | DJ30     | US30     | YM=H25   | 1.0       | 0.1 / 0.01 |
| ES      | SPX500   | US500    | ES=H25   | 0.25      | 0.1 / 0.01 |
| NQ      | NAS100   | USTEC    | NQ=H25   | 0.25      | 0.1 / 0.01 |
| RTY     | US2000   | RUSSELL  | RTY=H25  | 0.10      | 0.1 / 0.01 |
| ZB      | US10Y    | BOND     | ZB=H25   | 0.03125   | 0.01       |

## Advanced: Configuration File Approach

For even more flexibility, load mappings from a CSV/INI file:

### broker_mappings.csv

```csv
FutPrefix,MT5Symbol,TickSize,PointSize
YM,DJ30,1.0,0.1
ES,SPX500,0.25,0.1
NQ,NAS100,0.25,0.1
RTY,US2000,0.10,0.1
```

### Load in OnInit()

```mql5
void LoadMappingsFromFile(string filename)
{
   int handle = FileOpen(filename, FILE_READ|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
   {
      Print("Failed to open mapping file: ", filename);
      return;
   }

   // Skip header
   string dummy = FileReadString(handle);

   while(!FileIsEnding(handle))
   {
      string futPrefix = FileReadString(handle);
      string mt5Symbol = FileReadString(handle);
      double tickSize = FileReadNumber(handle);
      double pointSize = FileReadNumber(handle);

      AeronBridge_RegisterInstrumentMapW(futPrefix, mt5Symbol, tickSize, pointSize);
   }

   FileClose(handle);
}

int OnInit()
{
   LoadMappingsFromFile("broker_mappings.csv");

   int result = AeronBridge_StartW(
       AeronDir,
       AeronChannel,
       AeronStreamId,
       AeronTimeoutMs
   );

   return (result == 1) ? INIT_SUCCEEDED : INIT_FAILED;
}
```

## Key Points

1. **Single DLL, Multiple Configurations**: One DLL serves all brokers; each MT5 terminal registers its own mappings
2. **Register Before Start**: Always call `RegisterInstrumentMapW` before `StartW`
3. **Override Defaults**: The DLL has defaults (ES→SPX500, NQ→TECH100), but you can override them
4. **Per-Terminal State**: Each MT5 terminal has its own DLL instance with independent mapping state
5. **No Code Changes Needed**: The DLL doesn't need recompilation for new broker support

## Troubleshooting

### Unmapped Symbols

If a signal arrives for an unmapped symbol, the DLL **silently drops it** (see line 248 in AeronBridge.cpp).

**Solution**: Ensure all expected futures prefixes are registered.

### Wrong Point Conversion

If stop-loss/profit-target values are incorrect:

1. Verify `futTickSize` matches the futures contract specification
2. Verify `mt5PointSize` matches your broker's point size (check with `SymbolInfoDouble(_Symbol, SYMBOL_POINT)`)

### Multiple MT5 on Same Machine

Each MT5 terminal loads its own copy of the DLL. They are **independent** - no shared state between terminals.

## Summary

The answer to your question: **Each MT5 terminal registers its own broker-specific mappings at startup**. The single DLL handles all brokers by allowing runtime configuration through `AeronBridge_RegisterInstrumentMapW()`.

**For "YM MAR 26(YM)" signal:**

- Broker A terminal: Registers "YM"→"DJ30", receives signal as "DJ30"
- Broker B terminal: Registers "YM"→"US30", receives signal as "US30"
- Same DLL, different runtime configuration per terminal ✅
