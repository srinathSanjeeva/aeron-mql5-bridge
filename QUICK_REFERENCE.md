# Aeron Binary Protocol Quick Reference

## Strategy Actions (Enum)

```cpp
enum AeronStrategyAction
{
   AERON_LONG_ENTRY1    = 1,  // Long position with stop loss only
   AERON_LONG_ENTRY2    = 2,  // Long position with SL + TP (scalp)
   AERON_SHORT_ENTRY1   = 3,  // Short position with stop loss only
   AERON_SHORT_ENTRY2   = 4,  // Short position with SL + TP (scalp)
   AERON_LONG_EXIT      = 5,  // Manual/session close of long
   AERON_SHORT_EXIT     = 6,  // Manual/session close of short
   AERON_LONG_STOPLOSS  = 7,  // Long stop loss triggered
   AERON_SHORT_STOPLOSS = 8,  // Short stop loss triggered
   AERON_PROFIT_TARGET  = 9   // Profit target hit (scalp)
};
```

## Publishing Function Signature

```mql5
bool AeronPublishSignal(
   string symbol,                    // "ES", "NQ", etc.
   string instrument,                // "ES MAR26", full name
   AeronStrategyAction action,       // Action enum (1-9)
   int longSL,                       // Long stop loss (ticks)
   int shortSL,                      // Short stop loss (ticks)
   int profitTarget,                 // Profit target (ticks)
   int qty,                          // Position quantity
   float confidence,                 // 0-100 confidence score
   string source                     // "SecretEye_V20_5"
)
```

## Common Usage Patterns

### Long Entry (Dual Position)

```mql5
// Entry1: Stop loss only, no TP
AeronPublishSignal(
    "ES", "ES MAR26",
    AERON_LONG_ENTRY1,
    35,    // longSL = 35 ticks
    0,     // shortSL = not used
    0,     // no profit target for entry1
    1,     // qty = 1
    85.0,  // confidence
    "SecretEye_V20_5"
);

// Entry2: Stop loss + profit target (scalp)
AeronPublishSignal(
    "ES", "ES MAR26",
    AERON_LONG_ENTRY2,
    35,    // longSL = 35 ticks
    0,     // shortSL = not used
    65,    // profitTarget = 65 ticks
    1,     // qty = 1
    85.0,  // confidence
    "SecretEye_V20_5"
);
```

### Short Entry (Dual Position)

```mql5
// Entry1: Stop loss only
AeronPublishSignal(
    "NQ", "NQ MAR26",
    AERON_SHORT_ENTRY1,
    0,     // longSL = not used
    50,    // shortSL = 50 ticks
    0,     // no profit target
    1, 85.0, "SecretEye_V20_5"
);

// Entry2: Stop loss + profit target
AeronPublishSignal(
    "NQ", "NQ MAR26",
    AERON_SHORT_ENTRY2,
    0,     // longSL = not used
    50,    // shortSL = 50 ticks
    90,    // profitTarget = 90 ticks
    1, 85.0, "SecretEye_V20_5"
);
```

### Exit Signals

```mql5
// Long stop loss hit
AeronPublishSignal("ES", "ES MAR26", AERON_LONG_STOPLOSS,
                  0, 0, 0, 1, 50.0, "SecretEye_V20_5");

// Short stop loss hit
AeronPublishSignal("ES", "ES MAR26", AERON_SHORT_STOPLOSS,
                  0, 0, 0, 1, 50.0, "SecretEye_V20_5");

// Profit target hit (from scalp position)
AeronPublishSignal("ES", "ES MAR26", AERON_PROFIT_TARGET,
                  0, 0, 0, 1, 50.0, "SecretEye_V20_5");

// Manual long exit
AeronPublishSignal("ES", "ES MAR26", AERON_LONG_EXIT,
                  0, 0, 0, 1, 50.0, "SecretEye_V20_5");

// Manual short exit
AeronPublishSignal("ES", "ES MAR26", AERON_SHORT_EXIT,
                  0, 0, 0, 1, 50.0, "SecretEye_V20_5");
```

## Configuration Inputs

```mql5
EnableAeronPublishing = true              // Master switch
AeronPublishChannel = "aeron:ipc"         // Local IPC
// OR
AeronPublishChannel = "aeron:udp?endpoint=192.168.1.100:40123"  // Network

AeronPublishStreamId = 2001               // Must differ from subscriber
AeronPublishDir = "C:\\aeron\\standalone"
AeronSourceTag = "SecretEye_V20_5"        // Your strategy name
```

## Initialization Pattern

```mql5
int OnInit()
{
    // ... other init code ...

    if(EnableAeronPublishing)
    {
        int result = AeronBridge_StartPublisherW(
            AeronPublishDir,
            AeronPublishChannel,
            AeronPublishStreamId,
            3000);  // 3-second timeout

        if(result == 0)
        {
            // Error handling
            uchar errBuf[512];
            int errLen = AeronBridge_LastError(errBuf, 512);
            string errMsg = CharArrayToString(errBuf, 0, errLen);
            Print("Aeron publisher failed: ", errMsg);
        }
        else
        {
            Print("Aeron publisher started successfully");
        }
    }

    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(EnableAeronPublishing)
    {
        AeronBridge_StopPublisher();
    }
}
```

## Binary Frame Layout (104 bytes)

```
[0-3]   MAGIC (0xA330BEEF)
[4-5]   VERSION (1)
[6-7]   ACTION (1-9)
[8-15]  TIMESTAMP (nanoseconds)
[16-19] LONG_SL (ticks)
[20-23] SHORT_SL (ticks)
[24-27] PROFIT_TARGET (ticks)
[28-31] QTY
[32-35] CONFIDENCE (float)
[36-51] SYMBOL (16 chars, ASCII, null-padded)
[52-83] INSTRUMENT (32 chars, ASCII, null-padded)
[84-99] SOURCE (16 chars, ASCII, null-padded)
[100-103] (padding to 104 bytes)
```

## Helper Function

```mql5
// Extract symbol prefix from full name
string ExtractSymbolPrefix(string fullName)
{
    int spacePos = StringFind(fullName, " ");
    if(spacePos > 0)
        return StringSubstr(fullName, 0, spacePos);

    int len = StringLen(fullName);
    if(len >= 3) return StringSubstr(fullName, 0, 3);
    if(len >= 2) return StringSubstr(fullName, 0, 2);
    return fullName;
}

// Usage:
string symbol = ExtractSymbolPrefix("ES MAR26");  // Returns "ES"
```

## Testing Subscriber (AeronBridgeInt.mq5)

```mql5
// Set matching configuration
AeronChannel = "aeron:ipc"     // Must match publisher
AeronStreamId = 2001           // Must match publisher
EnableTrading = false          // DryRun mode for testing
DryRun = true

// Expected log output when receiving signals:
[SIGNAL] action=1 qty=1 slPts=35 ptPts=0 conf=85.00 mt5=ES src=SecretEye_V20_5
[SIGNAL] action=2 qty=1 slPts=35 ptPts=65 conf=85.00 mt5=ES src=SecretEye_V20_5
```

## Error Codes

```
0 = Success (publisher returns 1)
AERON_PUBLICATION_NOT_CONNECTED = Not connected to subscribers
AERON_PUBLICATION_BACK_PRESSURED = Subscriber too slow
AERON_PUBLICATION_ADMIN_ACTION = Admin intervention
AERON_PUBLICATION_CLOSED = Publication closed
```

## File Checklist

```
✅ AeronBridge.h (modified)
✅ AeronBridge.cpp (modified)
✅ AeronBridge.mqh (modified)
✅ AeronPublisher.mqh (new)
✅ AeronBridge.dll (rebuild required)
✅ Secret_Eye_V20_5_Ver.mq5 (integrate changes)
```

## Build & Deploy

```
1. Build DLL:    Visual Studio → Release x64 → Build
2. Copy DLL:     → MT5_DATA/MQL5/Libraries/AeronBridge.dll
3. Copy MQH:     → MT5_DATA/MQL5/Include/
4. Compile MQ5:  MetaEditor → F7
5. Test:         Load on chart → Check Expert log
```
