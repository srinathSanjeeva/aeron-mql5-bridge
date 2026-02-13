# Secret Eye V20.9 FOREX - Signal Reversal Guide

## Overview

Version 20.9 introduces **Signal Reversal** functionality designed specifically for Forex traders who need to publish inverted signals due to currency pair inversion relationships.

## The Problem

When trading Forex spot pairs and signaling futures contracts, there's an inherent inversion for USD-base pairs:

### Currency Pair Inversion Examples

| Forex Spot (MT5) | Futures Contract         | Relationship                           |
| ---------------- | ------------------------ | -------------------------------------- |
| USDCHF (long)    | 6S_F (Swiss Franc)       | **INVERSE** - Long USD/CHF = Short CHF |
| USDJPY (long)    | 6J_F (Japanese Yen)      | **INVERSE** - Long USD/JPY = Short JPY |
| USDCAD (long)    | 6C_F (Canadian Dollar)   | **INVERSE** - Long USD/CAD = Short CAD |
| EURUSD (long)    | 6E_F (Euro)              | **DIRECT** - Long EUR/USD = Long EUR   |
| GBPUSD (long)    | 6B_F (British Pound)     | **DIRECT** - Long GBP/USD = Long GBP   |
| AUDUSD (long)    | 6A_F (Australian Dollar) | **DIRECT** - Long AUD/USD = Long AUD   |

## The Solution: Signal Reversal

The `SignalReversal` parameter allows you to reverse the direction of published signals while keeping your actual MT5 trades unchanged.

### How It Works

```
SignalReversal = true

Actual MT5 Trade      →    Published Signal
─────────────────────────────────────────────
LONG USDCHF          →    SHORT 6S_F
SHORT USDCHF         →    LONG 6S_F
```

## Configuration

### Input Parameters

```mql5
input group "Forex Signal Reversal (V20.9)"
input bool   SignalReversal = false;         // Reverse signal direction
input string SignalReversalNote = "Enable for: USDCHF->6S, USDJPY->6J, USDCAD->6C";
```

### When to Enable Signal Reversal

Enable `SignalReversal = true` when:

1. **Trading USD-base pairs**: USDCHF, USDJPY, USDCAD, etc.
2. **Signaling futures contracts**: 6S, 6J, 6C, etc.
3. **Need inverse relationship**: Your signal receiver trades the quote currency

### When to Disable Signal Reversal

Keep `SignalReversal = false` when:

1. **Trading USD-quote pairs**: EURUSD, GBPUSD, AUDUSD, etc.
2. **Signaling futures contracts**: 6E, 6B, 6A, etc.
3. **Direct relationship**: Your signal receiver trades the same direction

## Examples

### Example 1: USDCHF → 6S Futures

**Scenario**: You trade USDCHF on MT5, signal NinjaTrader to trade 6S (Swiss Franc) futures.

**Configuration**:

```mql5
input string AeronInstrumentName = "6S";        // Futures symbol
input bool   SignalReversal = true;             // ENABLE reversal
```

**Result**:

- You go **LONG USDCHF** on MT5 (buying USD, selling CHF)
- Signal published: **SHORT 6S** (selling CHF futures)
- ✅ Correct correlation: Both profit if USD strengthens vs CHF

### Example 2: USDJPY → 6J Futures

**Scenario**: You trade USDJPY on MT5, signal to trade 6J (Japanese Yen) futures.

**Configuration**:

```mql5
input string AeronInstrumentName = "6J";        // Futures symbol
input bool   SignalReversal = true;             // ENABLE reversal
```

**Result**:

- You go **SHORT USDJPY** on MT5 (selling USD, buying JPY)
- Signal published: **LONG 6J** (buying JPY futures)
- ✅ Correct correlation: Both profit if JPY strengthens vs USD

### Example 3: EURUSD → 6E Futures (No Reversal Needed)

**Scenario**: You trade EURUSD on MT5, signal to trade 6E (Euro) futures.

**Configuration**:

```mql5
input string AeronInstrumentName = "6E";        // Futures symbol
input bool   SignalReversal = false;            // DISABLE reversal
```

**Result**:

- You go **LONG EURUSD** on MT5 (buying EUR, selling USD)
- Signal published: **LONG 6E** (buying EUR futures)
- ✅ Direct correlation: Both profit if EUR strengthens vs USD

## Technical Details

### Signal Modifications

When `SignalReversal = true`, the following signals are reversed:

#### Entry Signals

| MT5 Trade | Normal Signal | Reversed Signal |
| --------- | ------------- | --------------- |
| BUY       | LONG_ENTRY1   | SHORT_ENTRY1    |
| BUY       | LONG_ENTRY2   | SHORT_ENTRY2    |
| SELL      | SHORT_ENTRY1  | LONG_ENTRY1     |
| SELL      | SHORT_ENTRY2  | LONG_ENTRY2     |

#### Exit Signals

| MT5 Exit | Normal Signal  | Reversed Signal |
| -------- | -------------- | --------------- |
| Long SL  | LONG_STOPLOSS  | SHORT_STOPLOSS  |
| Short SL | SHORT_STOPLOSS | LONG_STOPLOSS   |
| Profit   | PROFIT_TARGET  | PROFIT_TARGET   |

**Note**: Profit targets are NOT reversed (they're position exits, not directional).

### Stop Loss and Take Profit Mapping

The signal publisher automatically swaps SL parameters:

```mql5
// Normal mode (SignalReversal = false)
AeronPublishSignalDual(
    symbol, instrument,
    AERON_LONG_ENTRY1,
    longSL: slTicks,    // ← Long position SL
    shortSL: 0,
    profitTarget: 0,
    qty: 1, confidence: 80.0
);

// Reversed mode (SignalReversal = true)
AeronPublishSignalDual(
    symbol, instrument,
    AERON_SHORT_ENTRY1, // ← Direction reversed
    longSL: 0,
    shortSL: slTicks,   // ← SL moved to short side
    profitTarget: 0,
    qty: 1, confidence: 80.0
);
```

## Logging and Monitoring

### Initial EA Load

When signal reversal is enabled, you'll see:

```
=== Secret Eye V20.9 FOREX Initialization ===
Signal Reversal: ENABLED (signals will be inverted)
⚠️  WARNING: Signal reversal is ACTIVE. Long trades will publish SHORT signals, short trades will publish LONG signals.
    This is typically used when trading USD base pairs (USDCHF) but signaling futures (6S_F).
```

### Trade Execution

When opening positions with reversal enabled:

```
BUY Signal Detected. Opening dual positions.
⚠️  SIGNAL REVERSAL ACTIVE: Will publish SHORT signals for this LONG trade
Scalp Buy Opened: #12345
Trend Buy Opened: #12346
[AERON_PUB] ✅ Entry1: 6S SHORT (REVERSED) SL=10 ticks (50 pts) qty=1 conf=82.5
[AERON_PUB] ✅ Entry2: 6S SHORT (REVERSED) SL=10 TP=18 ticks (50/70 pts) qty=1 conf=82.5
⚠️  Signal reversal: Opened LONG position but published SHORT signals
```

### Normal Mode (No Reversal)

For comparison, without signal reversal:

```
BUY Signal Detected. Opening dual positions.
Scalp Buy Opened: #12345
Trend Buy Opened: #12346
[AERON_PUB] ✅ Entry1: 6E LONG SL=10 ticks (50 pts) qty=1 conf=82.5
[AERON_PUB] ✅ Entry2: 6E LONG SL=10 TP=18 ticks (50/70 pts) qty=1 conf=82.5
```

## Quick Reference Table

| Your MT5 Symbol | Futures Symbol | SignalReversal | Why                   |
| --------------- | -------------- | -------------- | --------------------- |
| **USDCHF**      | 6S_F           | **true**       | USD is base (inverse) |
| **USDJPY**      | 6J_F           | **true**       | USD is base (inverse) |
| **USDCAD**      | 6C_F           | **true**       | USD is base (inverse) |
| **EURUSD**      | 6E_F           | **false**      | USD is quote (direct) |
| **GBPUSD**      | 6B_F           | **false**      | USD is quote (direct) |
| **AUDUSD**      | 6A_F           | **false**      | USD is quote (direct) |
| **NZDUSD**      | 6N_F           | **false**      | USD is quote (direct) |

## Common Mistakes to Avoid

### ❌ Wrong: Enabling reversal for EUR/USD → 6E

```mql5
// INCORRECT CONFIGURATION
input string AeronInstrumentName = "6E";
input bool   SignalReversal = true;  // ❌ WRONG! EUR/USD is direct
```

**Result**: Your signals will be backwards. When you buy EURUSD, it will signal SHORT 6E (sell Euro), which is opposite!

**Fix**: Set `SignalReversal = false` for USD-quote pairs.

### ❌ Wrong: Disabling reversal for USD/CHF → 6S

```mql5
// INCORRECT CONFIGURATION
input string AeronInstrumentName = "6S";
input bool   SignalReversal = false;  // ❌ WRONG! USD/CHF is inverse
```

**Result**: When you buy USDCHF (bullish USD), it will signal LONG 6S (buy CHF), which moves opposite to USD!

**Fix**: Set `SignalReversal = true` for USD-base pairs.

## Testing and Verification

### Step 1: Check Initialization Messages

Look for the warning message confirming reversal is active:

```
⚠️  WARNING: Signal reversal is ACTIVE. Long trades will publish SHORT signals...
```

### Step 2: Verify Signal Direction

When you open a trade, check the log:

```
[AERON_PUB] ✅ Entry1: 6S SHORT (REVERSED) SL=10 ticks...
```

The `(REVERSED)` indicator confirms signal reversal is working.

### Step 3: Monitor Signal Receiver

On your NinjaTrader (or other receiver):

- When MT5 goes **LONG** USDCHF, you should see **SHORT** 6S signal
- When MT5 goes **SHORT** USDCHF, you should see **LONG** 6S signal

### Step 4: Verify Correlation

Both positions should profit/loss together:

- If USD strengthens vs CHF → MT5 long USDCHF profits + 6S short profits ✅
- If USD weakens vs CHF → MT5 long USDCHF losses + 6S short losses ✅

## Integration with Existing Features

Signal reversal works seamlessly with all V20.8 features:

- ✅ **Aeron IPC/UDP Publishing**: Reversal applies to all channels
- ✅ **JSON Publishing**: Also reverses JSON signal types
- ✅ **Dual Entry System**: Both Entry1 and Entry2 are reversed
- ✅ **Exit Signals**: Stop loss exits are correctly reversed
- ✅ **Multi-Broker Support**: Works with broker symbol mappings
- ✅ **Exception Handling**: All V20.7+ crash protection remains active

## Performance Impact

Signal reversal has **zero performance impact**:

- No additional calculations required
- Same execution speed (< 1ms)
- No memory overhead
- Simple conditional logic during signal publishing

## Migration from V20.8

If upgrading from V20.8 to V20.9 Forex:

### For Direct Pairs (EUR/USD, GBP/USD, etc.)

No changes needed:

```mql5
input bool SignalReversal = false;  // Default - no reversal
```

### For Inverse Pairs (USD/CHF, USD/JPY, etc.)

Enable the new feature:

```mql5
input bool SignalReversal = true;   // Enable reversal for USD-base pairs
```

## Summary

The V20.9 FOREX Signal Reversal feature provides:

1. **Automatic signal inversion** for USD-base currency pairs
2. **Correct correlation** between spot forex and futures signals
3. **Simple configuration** with single boolean parameter
4. **Clear logging** to verify correct operation
5. **Full compatibility** with existing V20.8 features

Enable `SignalReversal = true` when trading USD-base pairs (USDCHF, USDJPY, USDCAD) and signaling corresponding futures (6S, 6J, 6C).

Keep `SignalReversal = false` when trading USD-quote pairs (EURUSD, GBPUSD, AUDUSD) and signaling corresponding futures (6E, 6B, 6A).

---

**Version**: 20.90  
**Release Date**: February 2026  
**Compatibility**: MT5 Build 3802+, NinjaTrader 8, Aeron 1.42+  
**Author**: Sanjeevas Inc.
