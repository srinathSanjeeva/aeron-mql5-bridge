# V20.9 FOREX - Quick Start Configuration Guide

## Quick Configuration Templates

### Template 1: USDCHF → 6S (Swiss Franc Futures)

```mql5
//--- Aeron Publishing
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
input string AeronPublishChannelIpc = "aeron:ipc";
input string AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
input int    AeronPublishStreamId = 1001;
input string AeronPublishDir = "C:\\aeron\\standalone";
input string AeronSourceTag = "USDCHF_SecretEye";
input string AeronInstrumentName = "6S";        // Swiss Franc futures

//--- Forex Signal Reversal (V20.9)
input bool   SignalReversal = true;             // ✅ ENABLE for USD-base pairs
input string SignalReversalNote = "Enabled: USDCHF->6S inverse relationship";
```

**Result**:

- MT5 LONG USDCHF → Signal: SHORT 6S ✅
- MT5 SHORT USDCHF → Signal: LONG 6S ✅

---

### Template 2: USDJPY → 6J (Japanese Yen Futures)

```mql5
//--- Aeron Publishing
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
input string AeronPublishChannelIpc = "aeron:ipc";
input string AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
input int    AeronPublishStreamId = 1002;
input string AeronPublishDir = "C:\\aeron\\standalone";
input string AeronSourceTag = "USDJPY_SecretEye";
input string AeronInstrumentName = "6J";        // Japanese Yen futures

//--- Forex Signal Reversal (V20.9)
input bool   SignalReversal = true;             // ✅ ENABLE for USD-base pairs
input string SignalReversalNote = "Enabled: USDJPY->6J inverse relationship";
```

**Result**:

- MT5 LONG USDJPY → Signal: SHORT 6J ✅
- MT5 SHORT USDJPY → Signal: LONG 6J ✅

---

### Template 3: EURUSD → 6E (Euro Futures) - NO REVERSAL

```mql5
//--- Aeron Publishing
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
input string AeronPublishChannelIpc = "aeron:ipc";
input string AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
input int    AeronPublishStreamId = 1003;
input string AeronPublishDir = "C:\\aeron\\standalone";
input string AeronSourceTag = "EURUSD_SecretEye";
input string AeronInstrumentName = "6E";        // Euro futures

//--- Forex Signal Reversal (V20.9)
input bool   SignalReversal = false;            // ❌ DISABLE for USD-quote pairs
input string SignalReversalNote = "Disabled: EURUSD->6E direct relationship";
```

**Result**:

- MT5 LONG EURUSD → Signal: LONG 6E ✅
- MT5 SHORT EURUSD → Signal: SHORT 6E ✅

---

### Template 4: GBPUSD → 6B (British Pound Futures) - NO REVERSAL

```mql5
//--- Aeron Publishing
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
input string AeronPublishChannelIpc = "aeron:ipc";
input string AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
input int    AeronPublishStreamId = 1004;
input string AeronPublishDir = "C:\\aeron\\standalone";
input string AeronSourceTag = "GBPUSD_SecretEye";
input string AeronInstrumentName = "6B";        // British Pound futures

//--- Forex Signal Reversal (V20.9)
input bool   SignalReversal = false;            // ❌ DISABLE for USD-quote pairs
input string SignalReversalNote = "Disabled: GBPUSD->6B direct relationship";
```

**Result**:

- MT5 LONG GBPUSD → Signal: LONG 6B ✅
- MT5 SHORT GBPUSD → Signal: SHORT 6B ✅

---

## Decision Tree: Should I Enable Signal Reversal?

```
Is USD the BASE currency in your forex pair?
│
├─ YES (USDCHF, USDJPY, USDCAD, etc.)
│  │
│  └─ Are you signaling the QUOTE currency futures?
│     │
│     ├─ YES (6S, 6J, 6C, etc.)
│     │  └─ ✅ SignalReversal = true
│     │
│     └─ NO (also trading USD-base)
│        └─ ❌ SignalReversal = false
│
└─ NO (EURUSD, GBPUSD, AUDUSD, etc.)
   │
   └─ Are you signaling the BASE currency futures?
      │
      ├─ YES (6E, 6B, 6A, etc.)
      │  └─ ❌ SignalReversal = false
      │
      └─ NO (trading inversely)
         └─ ✅ SignalReversal = true
```

## Common Pair Configurations

### USD-Base Pairs (ENABLE Reversal)

| Forex Pair | Futures | AeronInstrumentName | SignalReversal |
| ---------- | ------- | ------------------- | -------------- |
| USDCHF     | 6S_F    | "6S"                | **true** ✅    |
| USDJPY     | 6J_F    | "6J"                | **true** ✅    |
| USDCAD     | 6C_F    | "6C"                | **true** ✅    |

### USD-Quote Pairs (DISABLE Reversal)

| Forex Pair | Futures | AeronInstrumentName | SignalReversal |
| ---------- | ------- | ------------------- | -------------- |
| EURUSD     | 6E_F    | "6E"                | **false** ❌   |
| GBPUSD     | 6B_F    | "6B"                | **false** ❌   |
| AUDUSD     | 6A_F    | "6A"                | **false** ❌   |
| NZDUSD     | 6N_F    | "6N"                | **false** ❌   |

## Verification Checklist

After configuring, verify the following:

### 1. Initialization Messages

```
✅ "Signal Reversal: ENABLED (signals will be inverted)"  - for USD-base pairs
✅ "Signal Reversal: DISABLED (normal signal direction)"  - for USD-quote pairs
```

### 2. Trade Execution Messages

For USD-base pairs (reversal enabled):

```
✅ "⚠️  SIGNAL REVERSAL ACTIVE: Will publish SHORT signals for this LONG trade"
✅ "[AERON_PUB] ✅ Entry1: 6S SHORT (REVERSED) SL=10 ticks..."
```

For USD-quote pairs (reversal disabled):

```
✅ "[AERON_PUB] ✅ Entry1: 6E LONG SL=10 ticks..."  (no reversal notice)
```

### 3. Signal Receiver Confirmation

- Check NinjaTrader/receiving platform shows correct direction
- Verify positions move in same direction (both profit or both loss together)

## Troubleshooting

### Issue: Signals are opposite to what I expected

**Check**: Is your pair USD-base or USD-quote?

**Fix**:

- USD-base (USDCHF, USDJPY): Set `SignalReversal = true`
- USD-quote (EURUSD, GBPUSD): Set `SignalReversal = false`

### Issue: Don't see "(REVERSED)" in logs

**Check**: Is `SignalReversal = true` in your inputs?

**Fix**:

1. Open EA properties in MT5
2. Go to "Inputs" tab
3. Find "Forex Signal Reversal (V20.9)" section
4. Set `SignalReversal = true`
5. Click OK and restart EA

### Issue: Positions don't correlate (one profits, other loses)

**Symptom**: When spot forex profits, futures loses (or vice versa)

**Diagnosis**: Signal reversal setting is WRONG

**Fix**:

- If currently `true`, change to `false`
- If currently `false`, change to `true`
- Restart EA and monitor

## Multi-Instance Setup Example

### Scenario: Trade 3 Forex pairs simultaneously

**EA Instance 1 - USDCHF → 6S**

```mql5
input string AeronInstrumentName = "6S";
input int    AeronPublishStreamId = 1001;
input string AeronSourceTag = "SecretEye_USDCHF";
input bool   SignalReversal = true;  // USD-base
```

**EA Instance 2 - EURUSD → 6E**

```mql5
input string AeronInstrumentName = "6E";
input int    AeronPublishStreamId = 1002;
input string AeronSourceTag = "SecretEye_EURUSD";
input bool   SignalReversal = false; // USD-quote
```

**EA Instance 3 - USDJPY → 6J**

```mql5
input string AeronInstrumentName = "6J";
input int    AeronPublishStreamId = 1003;
input string AeronSourceTag = "SecretEye_USDJPY";
input bool   SignalReversal = true;  // USD-base
```

**Key Points**:

- Each EA has unique `AeronPublishStreamId`
- Each EA has unique `AeronSourceTag`
- Signal reversal set correctly per pair

## API Trading Hours Configuration

For all configurations, also set appropriate trading hours:

```mql5
//--- API Trading Hours
input bool   UseAPITradingHours = true;
input string HOST_URI = "192.168.2.17:8000";
input string API_Symbol = "6S_F";          // Match your futures symbol
input int    ManualStartTime = 0;
input int    ManualStartMinute = 0;
input int    ManualEndTime = 23;
input int    ManualEndMinute = 0;
```

**Note**: Set `API_Symbol` to match the futures contract you're signaling, not the forex pair.

## Complete Example Configuration

Here's a full configuration for USDCHF → 6S with all relevant parameters:

```mql5
//+------------------------------------------------------------------+
//| Complete Configuration: USDCHF → 6S Swiss Franc Futures         |
//+------------------------------------------------------------------+

//--- Strategy Settings
input int    K_Period = 10;
input int    D_Period = 10;
input int    slowing = 3;
input ENUM_TIMEFRAMES timeFrame = PERIOD_M15;

//--- Trade Management
input double lot = 0.02;
input int    SL = 50;
input int    TP = 100;
input double scalpLotMultiplier = 0.5;
input double trendLotMultiplier = 0.5;

//--- EA Settings
input bool   on = true;
input bool   ShowAlerts = true;
input bool   EnableKillSwitch = true;
input bool   AutoDST = true;
input double MAX_DAILY_LOSS_PERCENTAGE = 2.5;

//--- API Trading Hours
input bool   UseAPITradingHours = true;
input string HOST_URI = "192.168.2.17:8000";
input string API_Symbol = "6S_F";          // ← Swiss Franc futures

//--- Aeron Publishing
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
input string AeronPublishChannelIpc = "aeron:ipc";
input string AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
input int    AeronPublishStreamId = 1001;
input string AeronPublishDir = "C:\\aeron\\standalone";
input string AeronSourceTag = "SecretEye_USDCHF";
input string AeronInstrumentName = "6S";   // ← Swiss Franc symbol

//--- ⚠️ CRITICAL: Signal Reversal for USD-Base Pairs
input bool   SignalReversal = true;        // ← ENABLED for USDCHF → 6S
input string SignalReversalNote = "Enabled: USDCHF->6S (USD-base inverse relationship)";
```

## Expected Log Output

### Initialization (Correct Configuration)

```
=== Secret Eye V20.9 FOREX Initialization ===
Signal Reversal: ENABLED (signals will be inverted)
⚠️  WARNING: Signal reversal is ACTIVE. Long trades will publish SHORT signals, short trades will publish LONG signals.
    This is typically used when trading USD base pairs (USDCHF) but signaling futures (6S_F).
Aeron symbol mapping: MT5=USDCHF -> Futures=6S (6S Futures)
✅ IPC Aeron publisher started successfully
✅ UDP Aeron publisher started successfully
Mode: IPC_AND_UDP | Status: ✅ FULLY OPERATIONAL (Both channels active)
=== Initialization Complete ===
```

### Trade Execution (Correct Behavior)

```
BUY Signal Detected. Opening dual positions.
⚠️  SIGNAL REVERSAL ACTIVE: Will publish SHORT signals for this LONG trade
Scalp Buy Opened: #123456
Trend Buy Opened: #123457
[AERON_PUB] ✅ Entry1: 6S SHORT (REVERSED) SL=10 ticks (50 pts) qty=1 conf=82.3
[AERON_PUB] ✅ Entry2: 6S SHORT (REVERSED) SL=10 TP=18 ticks (50/70 pts) qty=1 conf=82.3
⚠️  Signal reversal: Opened LONG position but published SHORT signals
```

---

**Quick Start Complete!**

Refer to [V20_9_FOREX_SIGNAL_REVERSAL_GUIDE.md](V20_9_FOREX_SIGNAL_REVERSAL_GUIDE.md) for detailed technical documentation.
