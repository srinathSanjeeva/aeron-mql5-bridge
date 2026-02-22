# Secret Eye V20.10 FOREX Edition - Release Summary

## Overview

Version line in file: `20.91` (inherits V20.9.1 hotfix metadata)  
Feature set: **V20.10 dual-timeframe logic + V20.9 FOREX signal reversal**

This release documents the latest behavior implemented in:

- `MQL5/Secret_Eye_V20_10_Forex.mq5`

## What Changed (Latest)

### 1) Dual Timeframe Strategy (X1 + X2)

The strategy now uses two independent stochastic contexts:

- **X1 (higher timeframe)**: directional bias engine
- **X2 (lower timeframe)**: execution trigger engine

New inputs:

```mql5
input ENUM_TIMEFRAMES TimeframeX1 = PERIOD_D1;
input int             K_Period_X1 = 10;
input int             D_Period_X1 = 10;
input int             Slowing_X1 = 3;

input ENUM_TIMEFRAMES TimeframeX2 = PERIOD_M15;
input int             K_Period_X2 = 10;
input int             D_Period_X2 = 10;
input int             Slowing_X2 = 3;
```

### 2) X1 Bias State Machine

Implemented internal bias states:

- `X1_BIAS_NONE`
- `X1_BIAS_LONG`
- `X1_BIAS_SHORT`

Bias is updated from X1 crossover events and persists until opposite X1 crossover.

### 3) Exit & Flip Rule (Implemented)

The Forex strategy now follows this rule:

- Exit positions **only when X1 bias flips**.
- On opposite bias:
  - close opposite-direction positions,
  - **do not reverse immediately**,
  - wait for X2 trigger in the new X1 direction.

### 4) Entry Rule (X2-Gated)

- If X1 bias is `LONG`, only X2 bullish crossover can open buys.
- If X1 bias is `SHORT`, only X2 bearish crossover can open sells.
- No trades when X1 bias is not ready.

### 5) Immediate Entry Behavior Updated

`ImmediateEntryOnLoad` now aligns with X1/X2 logic:

- with immediate load enabled: startup can seed X1 bias from current X1 direction,
- actual entry still requires valid X2 trigger in active X1 direction.

### 6) Signal Reversal (FOREX) Remains Intact

All V20.9 FOREX signal inversion behavior remains active and compatible:

- `SignalReversal = true` inverts published signal direction,
- MT5 trade direction itself is unchanged,
- JSON and Aeron publishing continue using reversal mapping.

## Effective Trade Flow

```text
1) Read X1 crossover -> set/flip bias
2) If bias flipped -> close opposite positions -> wait
3) Read X2 crossover
4) Enter only if X2 trigger matches active X1 bias
5) Continue until next X1 flip
```

## Key Compatibility Notes

- Existing risk controls (daily loss/profit protection) remain in place.
- Existing trading-hours enforcement and kill-switch path remain in place.
- Existing Aeron + JSON publishing paths remain in place.
- Confidence sampling for publishing now uses X2 stochastic context.

## Recommended Configurations

### A) Swing Bias + Intraday Trigger (FOREX)

```mql5
TimeframeX1 = PERIOD_D1
TimeframeX2 = PERIOD_M15
K_Period_X1 = 10
D_Period_X1 = 10
Slowing_X1  = 3
K_Period_X2 = 10
D_Period_X2 = 10
Slowing_X2  = 3
```

### B) Trend Bias + Fast Trigger (FOREX)

```mql5
TimeframeX1 = PERIOD_H4
TimeframeX2 = PERIOD_M5
K_Period_X1 = 14
D_Period_X1 = 5
Slowing_X1  = 3
K_Period_X2 = 8
D_Period_X2 = 3
Slowing_X2  = 2
```

### C) USD-Base Pair with Reversal

```mql5
AeronInstrumentName = "6S"    // Example for USDCHF
SignalReversal      = true
```

## Validation Checklist

Before running live:

- [ ] X1 flip closes opposite positions
- [ ] No immediate reverse order on X1 flip
- [ ] Re-entry only after X2 confirms new X1 bias direction
- [ ] ImmediateEntryOnLoad follows X1 + X2 alignment
- [ ] SignalReversal behavior remains correct for USD-base pairs
- [ ] Aeron/JSON publish direction is verified in logs

## Related Docs

- `MQL5/V20_9_FOREX_QUICK_START.md`
- `MQL5/V20_9_FOREX_SIGNAL_REVERSAL_GUIDE.md`
- `MQL5/V20_9_FOREX_RELEASE_SUMMARY.md`
- `MQL5/V20_10_RELEASE_SUMMARY.md`
