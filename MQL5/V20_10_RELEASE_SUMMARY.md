# Secret Eye V20.10 - X1/X2 Dual Timeframe Bias-Trigger - COMPLETE

## Summary

Secret Eye V20.10 is now implemented with a dual-timeframe stochastic architecture:

- **X1 (higher timeframe)** sets directional bias.
- **X2 (lower timeframe)** triggers entries only in X1 bias direction.
- **Exit/Flip behavior** updated to close positions only on X1 bias flip, then wait for X2 confirmation before re-entry.

## Files Updated

### 1. Secret_Eye_V20_10_Ver.mq5 ✅

**Location:** `/workspaces/aeron-mql5-bridge/MQL5/Secret_Eye_V20_10_Ver.mq5`

**Status:** COMPLETE - Updated and validated

## Key Changes in V20.10

### 1. New Input Parameters (Dual Timeframe)

```mql5
input ENUM_TIMEFRAMES   TimeframeX1 = PERIOD_D1;   // Higher timeframe bias
input int               K_Period_X1 = 10;
input int               D_Period_X1 = 10;
input int               Slowing_X1 = 3;

input ENUM_TIMEFRAMES   TimeframeX2 = PERIOD_M15;  // Lower timeframe trigger
input int               K_Period_X2 = 10;
input int               D_Period_X2 = 10;
input int               Slowing_X2 = 3;
```

### 2. Dual Stochastic Handles

- Added independent indicator handles:
  - `stochHandleX1` for bias detection
  - `stochHandleX2` for entry trigger and confidence calculation
- Added safe init/deinit handling for both handles.

### 3. X1 Bias State Machine

Added explicit bias states:

- `X1_BIAS_NONE`
- `X1_BIAS_LONG`
- `X1_BIAS_SHORT`

Behavior:

- X1 crossover updates bias.
- Bias persists until opposite X1 crossover.
- Startup gating uses `ImmediateEntryOnLoad` behavior.

### 4. Entry Logic (X2 Trigger Only)

- If X1 is **LONG**, only X2 bullish cross can trigger buy entries.
- If X1 is **SHORT**, only X2 bearish cross can trigger sell entries.
- No entry when X1 bias is not ready.

### 5. Exit & Flip Logic (Implemented Rule)

- **Exit only when X1 flips bias**.
- On X1 opposite bias:
  - Close existing opposite-direction positions.
  - **Do not reverse immediately**.
  - Wait for X2 crossover in new bias direction before opening new positions.

### 6. Immediate Entry Behavior

- Immediate entry now requires:
  - valid X1 bias
  - matching X2 crossover trigger
- Prevents immediate entries that are not aligned with higher timeframe bias.

### 7. Metadata Updated

- Header updated to V20.10.
- `#property version` updated to `20.10`.
- Top changelog now includes V20.10 architecture notes.

## Operational Flow

```text
1) Read X1 crossover state -> set/flip bias
2) If bias flipped -> close opposite positions -> wait
3) Read X2 crossover state
4) Enter only when X2 trigger matches active X1 bias
```

## Suggested Configuration Examples

### Example A: Swing Bias + Intraday Trigger

```mql5
TimeframeX1 = PERIOD_D1
TimeframeX2 = PERIOD_M15
K_Period_X1 = 10
D_Period_X1 = 10
Slowing_X1 = 3
K_Period_X2 = 10
D_Period_X2 = 10
Slowing_X2 = 3
```

### Example B: Trend Bias + Fast Trigger

```mql5
TimeframeX1 = PERIOD_H4
TimeframeX2 = PERIOD_M5
K_Period_X1 = 14
D_Period_X1 = 5
Slowing_X1 = 3
K_Period_X2 = 8
D_Period_X2 = 3
Slowing_X2 = 2
```

## Validation Checklist

Before live deployment:

- [ ] X1 flips close opposite positions correctly
- [ ] No instant reverse trade on X1 flip
- [ ] New trade opens only after valid X2 trigger in X1 direction
- [ ] Immediate entry respects X1 + X2 alignment
- [ ] Session filters, kill switch, and risk controls still behave as expected
- [ ] Aeron publishing confidence still updates and publishes correctly

## Version History

### V20.10 (Current)

- ✅ Dual timeframe architecture (X1 bias + X2 trigger)
- ✅ X1-flip close-and-wait behavior
- ✅ Immediate entry aligned to X1/X2

### V20.9 (Base)

- Dual session manual trading windows
- Optional explicit kill switch time
- Aeron multi-channel publishing and risk controls
