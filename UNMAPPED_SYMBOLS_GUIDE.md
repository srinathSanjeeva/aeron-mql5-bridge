# Handling Unmapped Symbols

## The Issue

**By design**, the DLL **silently drops signals** for unmapped instrument prefixes (see [AeronBridge.cpp](AeronBridge.cpp#L248-L252)):

```cpp
if (it == g_map.end())
{
    // Unknown instrument prefix - DROP SIGNAL
    return;
}
```

### Why This Happens

When a signal arrives for "YM MAR 26(YM)", the DLL:

1. Extracts prefix: "YM"
2. Looks up "YM" in the mapping table
3. **If not found → Signal is dropped** ❌

## Solutions

### ✅ Solution 1: Error Logging (Already Added)

The DLL now **logs to `AeronBridge_LastError()`** when dropping signals:

```mql5
void OnTimer()
{
   AeronBridge_Poll();

   // Check for errors (including dropped signals)
   uchar errBuf[512];
   int errLen = AeronBridge_LastError(errBuf, ArraySize(errBuf));
   if(errLen > 0)
   {
      string err = CharArrayToString(errBuf, 0, errLen);
      if(StringFind(err, "DROPPED SIGNAL") >= 0)
      {
         Print("WARNING: ", err);
         // Alert or take action
      }
   }
}
```

**Error message format:**

```
DROPPED SIGNAL: Unknown instrument prefix 'YM' from instrument 'YM MAR 26'.
Register mapping via AeronBridge_RegisterInstrumentMapW() or enable pass-through
with AeronBridge_SetUnmappedBehaviorW()
```

### ✅ Solution 2: Pass-Through Mode (New Feature)

Allow unmapped symbols to pass through using the prefix as the MT5 symbol:

```mql5
int OnInit()
{
   // Option A: Register known mappings only
   AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1);
   AeronBridge_RegisterInstrumentMapW("NQ", "NAS100", 0.25, 0.1);

   // Option B: Enable pass-through for unmapped symbols
   // Parameters: (allowUnmapped, defaultTickSize, defaultPointSize)
   AeronBridge_SetUnmappedBehaviorW(1, 0.01, 0.01);

   // Now signals like "YM" will pass through as "YM" with defaults

   AeronBridge_StartW(AeronDir, AeronChannel, AeronStreamId, AeronTimeoutMs);

   return INIT_SUCCEEDED;
}
```

**How it works:**

- **Mapped symbols** (ES, NQ): Use registered mappings ✅
- **Unmapped symbols** (YM, RTY): Use prefix as symbol with default tick/point sizes ✅

**Example:**

```
Signal: "YM MAR 26(YM)"
  → Prefix: "YM"
  → Not mapped, but pass-through enabled
  → Output: mt5_symbol="YM", tickSize=0.01, pointSize=0.01
```

### ✅ Solution 3: Comprehensive Mapping (Safest)

Register **all** instruments you expect to receive:

```mql5
int OnInit()
{
   // Register EVERY instrument you might receive
   AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1);
   AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1);
   AeronBridge_RegisterInstrumentMapW("NQ", "NAS100", 0.25, 0.1);
   AeronBridge_RegisterInstrumentMapW("RTY", "US2000", 0.10, 0.1);
   AeronBridge_RegisterInstrumentMapW("ZB", "US10Y", 0.03125, 0.01);
   AeronBridge_RegisterInstrumentMapW("GC", "GOLD", 0.10, 0.01);
   AeronBridge_RegisterInstrumentMapW("CL", "CRUDEOIL", 0.01, 0.01);

   // Or use CSV file / broker profiles (see BrokerMappings.mqh)
   RegisterBrokerMappings(BROKER_PROFILE_A);

   AeronBridge_StartW(...);
   return INIT_SUCCEEDED;
}
```

## Comparison

| Approach                  | Pros                              | Cons                           | Best For                                  |
| ------------------------- | --------------------------------- | ------------------------------ | ----------------------------------------- |
| **Error Logging Only**    | Safe, explicit control            | Requires monitoring logs       | Production systems with known instruments |
| **Pass-Through Mode**     | Flexible, handles new instruments | May use wrong tick/point sizes | Development, testing, catch-all           |
| **Comprehensive Mapping** | Most accurate, type-safe          | Requires upfront configuration | Production with full instrument list      |

## Recommended Strategy

### For Development/Testing

```mql5
// Be lenient during development
AeronBridge_SetUnmappedBehaviorW(1, 0.01, 0.01);  // Pass-through
```

### For Production

```mql5
// Be strict in production
RegisterBrokerMappings(BROKER_PROFILE_A);  // Register all expected instruments

// Monitor for unexpected instruments
void OnTimer()
{
   AeronBridge_Poll();

   uchar errBuf[512];
   if(AeronBridge_LastError(errBuf, ArraySize(errBuf)) > 0)
   {
      string err = CharArrayToString(errBuf);
      if(StringFind(err, "DROPPED SIGNAL") >= 0)
      {
         SendNotification("Unmapped instrument detected: " + err);
      }
   }
}
```

## Configuration Examples

### Example 1: Strict Mode (Drop Unmapped)

```mql5
int OnInit()
{
   // Only allow mapped symbols
   AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1);
   AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1);

   // Pass-through disabled by default
   // Unknown instruments will be dropped

   AeronBridge_StartW(...);
   return INIT_SUCCEEDED;
}
```

### Example 2: Lenient Mode (Pass-Through)

```mql5
int OnInit()
{
   // Map common instruments explicitly
   AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1);
   AeronBridge_RegisterInstrumentMapW("NQ", "NAS100", 0.25, 0.1);

   // Allow pass-through for others
   AeronBridge_SetUnmappedBehaviorW(1, 0.01, 0.01);

   // Now YM, RTY, GC etc. will pass through as-is

   AeronBridge_StartW(...);
   return INIT_SUCCEEDED;
}
```

### Example 3: Hybrid Mode

```mql5
int OnInit()
{
   // Critical instruments: explicit mappings
   AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1);
   AeronBridge_RegisterInstrumentMapW("NQ", "NAS100", 0.25, 0.1);
   AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1);

   // Enable pass-through for testing new instruments
   AeronBridge_SetUnmappedBehaviorW(1, 0.01, 0.01);

   AeronBridge_StartW(...);
   return INIT_SUCCEEDED;
}
```

## Error Monitoring Code

```mql5
string g_lastReportedError = "";

void OnTimer()
{
   int pollCount = AeronBridge_Poll();

   // Check for new errors
   uchar errBuf[512];
   int errLen = AeronBridge_LastError(errBuf, ArraySize(errBuf));

   if(errLen > 0)
   {
      string err = CharArrayToString(errBuf, 0, errLen);

      // Only report new errors (avoid spam)
      if(err != g_lastReportedError)
      {
         if(StringFind(err, "DROPPED SIGNAL") >= 0)
         {
            Print("⚠️ ", err);

            // Optional: send alert
            if(EnableAlerts)
            {
               Alert("Unmapped instrument detected - check logs");
            }

            // Optional: send notification
            if(EnableNotifications)
            {
               SendNotification(err);
            }
         }

         g_lastReportedError = err;
      }
   }

   // Process signals as normal
   while(AeronBridge_HasSignal())
   {
      // ...
   }
}
```

## API Reference

### AeronBridge_SetUnmappedBehaviorW()

```cpp
int AeronBridge_SetUnmappedBehaviorW(
    int allowUnmapped,       // 1 = allow pass-through, 0 = drop (default)
    double defaultTickSize,  // Tick size for unmapped instruments (e.g. 0.01)
    double defaultPointSize  // Point size for unmapped instruments (e.g. 0.01)
)
```

**Returns:** 1 on success, 0 on error (invalid tick/point sizes)

**When to call:** Before `AeronBridge_StartW()`

**Example:**

```mql5
// Allow pass-through with conservative defaults
AeronBridge_SetUnmappedBehaviorW(1, 0.01, 0.01);
```

## Troubleshooting

### Problem: Signals Not Appearing

**Check 1: Is the instrument mapped?**

```mql5
// Make sure you registered it
AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1);
```

**Check 2: Check error logs**

```mql5
uchar errBuf[512];
int errLen = AeronBridge_LastError(errBuf, ArraySize(errBuf));
if(errLen > 0)
{
   Print("Error: ", CharArrayToString(errBuf, 0, errLen));
}
```

**Check 3: Enable pass-through temporarily**

```mql5
AeronBridge_SetUnmappedBehaviorW(1, 0.01, 0.01);  // See what comes through
```

### Problem: Wrong SL/TP Distances with Pass-Through

Pass-through mode uses generic defaults. For accurate conversion:

1. Determine actual tick size from futures specs
2. Determine actual point size from broker
3. Register explicit mapping

```mql5
// Wrong (pass-through with defaults)
AeronBridge_SetUnmappedBehaviorW(1, 0.01, 0.01);  // YM uses wrong sizes

// Right (explicit mapping)
AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1);  // Correct sizes
```

## Summary

✅ **Default behavior**: Drop unmapped signals (safe)  
✅ **New behavior**: Log errors when dropping signals  
✅ **Optional behavior**: Pass-through with defaults

**Best practice:**

1. **Development**: Use pass-through to discover which instruments you're receiving
2. **Testing**: Register all known instruments, monitor logs for unknowns
3. **Production**: Strict mode with comprehensive mappings

The DLL is now **much more informative** about what it's doing with your signals! 🎯
