# Aeron MQL5 Bridge - Multi-Broker Configuration Examples

This directory contains example configuration files for different broker symbol conventions.

## Quick Start

### Example 1: Using Predefined Broker Profiles

```mql5
// In your EA settings:
BrokerProfile = BROKER_PROFILE_A;  // For brokers using DJ30, SPX500, NAS100
```

### Example 2: Using CSV Configuration Files

```mql5
// In your EA settings:
CustomMappingFile = "broker_a_mappings.csv";
```

### Example 3: Manual Registration

```mql5
int OnInit()
{
   // Manually register mappings for your specific broker
   AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1);
   AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1);
   AeronBridge_RegisterInstrumentMapW("NQ", "NAS100", 0.25, 0.1);

   // Start the bridge
   AeronBridge_StartW(AeronDir, AeronChannel, AeronStreamId, AeronTimeoutMs);

   return INIT_SUCCEEDED;
}
```

## Broker Profiles

### Broker Profile A

**Symbols:** DJ30, SPX500, NAS100, US2000
**File:** `broker_a_mappings.csv`
**Common Brokers:** [List your broker names here]

### Broker Profile B

**Symbols:** US30, US500, USTEC, RUSSELL
**File:** `broker_b_mappings.csv`
**Common Brokers:** [List your broker names here]

### Broker Profile C

**Symbols:** Futures-style (YMH25, ESH25, etc.)
**Common Brokers:** [List your broker names here]

## CSV File Format

```csv
FutPrefix,MT5Symbol,TickSize,PointSize
YM,DJ30,1.0,0.1
ES,SPX500,0.25,0.1
```

**Fields:**

- **FutPrefix**: Futures symbol prefix (ES, NQ, YM, RTY, etc.)
- **MT5Symbol**: Your broker's MT5 symbol name
- **TickSize**: Futures tick size (ES=0.25, YM=1.0, etc.)
- **PointSize**: Your broker's point size (typically 0.1 for indices, 0.01 for treasuries)

## Common Symbol Mappings

| Futures | Description    | Broker A | Broker B | Broker C |
| ------- | -------------- | -------- | -------- | -------- |
| YM      | Dow Jones Mini | DJ30     | US30     | YMH25    |
| ES      | E-mini S&P 500 | SPX500   | US500    | ESH25    |
| NQ      | E-mini NASDAQ  | NAS100   | USTEC    | NQH25    |
| RTY     | Russell 2000   | US2000   | RUSSELL  | RTYH25   |
| ZB      | 30-Year T-Bond | US10Y    | BOND     | ZBH25    |
| GC      | Gold Futures   | GOLD     | XAUUSD   | GCJ25    |
| CL      | Crude Oil      | CRUDEOIL | XTIUSD   | CLG25    |
| SI      | Silver Futures | SILVER   | XAGUSD   | SIH25    |
| NG      | Natural Gas    | NATGAS   | XNGUSD   | NGG25    |

## Tick Sizes Reference

| Futures | Tick Size | Tick Value |
| ------- | --------- | ---------- |
| YM      | 1.00      | $5.00      |
| ES      | 0.25      | $12.50     |
| NQ      | 0.25      | $5.00      |
| RTY     | 0.10      | $5.00      |
| ZB      | 0.03125   | $31.25     |
| GC      | 0.10      | $10.00     |
| CL      | 0.01      | $10.00     |
| SI      | 0.005     | $25.00     |
| NG      | 0.001     | $10.00     |

## Finding Your Broker's Point Size

```mql5
double pointSize = SymbolInfoDouble("DJ30", SYMBOL_POINT);
Print("Point size for DJ30: ", pointSize);
```

Common values:

- **Indices**: 0.1 or 0.01
- **Forex**: 0.00001 (5 digits) or 0.0001 (4 digits)
- **Metals**: 0.01
- **Energies**: 0.01

## Troubleshooting

### Problem: Signals not appearing

**Solution:** Check that your futures prefix is registered:

```mql5
AeronBridge_RegisterInstrumentMapW("YM", "YOUR_BROKER_SYMBOL", 1.0, 0.1);
```

### Problem: Wrong SL/TP distances

**Solution:** Verify your tick size and point size:

1. Check futures contract specifications for tick size
2. Check `SymbolInfoDouble(_Symbol, SYMBOL_POINT)` for point size

### Problem: Symbol not found on broker

**Solution:** Check Market Watch in MT5 for the exact symbol name your broker uses

## Creating Your Own CSV

1. Open Market Watch in MT5
2. Find the symbols you want to trade
3. Note the exact symbol names
4. Create a CSV file with the mappings
5. Save to `MQL5/Files/` directory
6. Set `CustomMappingFile` input parameter

Example:

```
FutPrefix,MT5Symbol,TickSize,PointSize
YM,US30.cash,1.0,0.01
ES,SP500.cash,0.25,0.01
```

## Signal Flow Example

1. **Publisher sends:** "YM MAR 26(YM)" signal
2. **DLL extracts:** Prefix "YM"
3. **DLL maps:** "YM" → "DJ30" (Broker A) or "US30" (Broker B)
4. **MT5 receives:** Signal with broker-specific symbol
5. **EA trades:** On the correct broker symbol

## Support

For questions or issues:

1. Check the logs in MT5 Expert tab
2. Verify symbol mappings are loaded (look for "Registered: YM -> DJ30" messages)
3. Test with DryRun=true first
4. Review [BROKER_SYMBOL_MAPPING_GUIDE.md](BROKER_SYMBOL_MAPPING_GUIDE.md) for detailed explanation
