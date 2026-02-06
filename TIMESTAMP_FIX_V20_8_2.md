# V20.8.2 - Timestamp UTC Fix

## 🚨 Issue: Signal Rejection Due to Timestamp Mismatch

### **Symptom:**

```
[AeronV3] Rejected signal - Age: -7200.1s, Symbol: 6A_F
```

The signal was rejected because it appeared to be **2 hours in the future** (-7200 seconds = -2 hours).

---

## 🔍 Root Cause

### **MQL5 (Secret_Eye):**

```cpp
// BEFORE FIX
datetime now = TimeCurrent();  // ❌ Broker server time (UTC+2 or broker's timezone)
```

### **NinjaTrader (AtomSetup):**

```csharp
// Always uses UTC
DateTime.UtcNow  // ✅ UTC time
```

### **The Problem:**

- MQL5 was sending timestamps in **broker server timezone** (e.g., EET = UTC+2)
- NinjaTrader was expecting timestamps in **UTC**
- Result: 2-hour offset causing rejection

---

## ✅ The Fix

**File:** `AeronPublisher.mqh` Line 150

```cpp
// AFTER FIX
datetime now = TimeGMT();  // ✅ UTC time to match NinjaTrader
```

### **Change:**

```diff
- datetime now = TimeCurrent();  // Broker server time
+ datetime now = TimeGMT();      // UTC time
```

---

## 📊 Impact

### Before Fix:

- ❌ Signals rejected with "Age: -7200.1s" (2 hours in future)
- ❌ No cross-platform signal compatibility
- ❌ Timezone-dependent behavior

### After Fix:

- ✅ Signals accepted immediately
- ✅ UTC timestamps match NinjaTrader exactly
- ✅ Timezone-independent operation
- ✅ Cross-platform compatibility

---

## 🧪 Testing

### Verify the Fix:

1. **Check MT5 timestamps:**

   ```cpp
   Print("Server Time: ", TimeCurrent());
   Print("UTC Time: ", TimeGMT());
   Print("Difference: ", (TimeCurrent() - TimeGMT()), " seconds");
   ```

2. **Monitor NinjaTrader logs:**
   Look for signal acceptance instead of rejection:

   ```
   [AeronV3] ✅ Signal accepted - Age: 0.2s, Symbol: 6A_F
   ```

3. **Expected behavior:**
   - Signal age should be close to 0 seconds (latency only)
   - No "future" timestamps (-7200s)
   - Clean signal flow between platforms

---

## 📝 Files Modified

### AeronPublisher.mqh

- **Line 150:** Changed `TimeCurrent()` → `TimeGMT()`
- **Impact:** All Aeron signal timestamps now use UTC

### Secret_Eye_V20_8_Ver.mq5

- **Version:** 20.81 → 20.82
- **Description:** Added "Timestamp Fix: UTC time for Aeron signals"
- **Init message:** Updated to reflect timestamp fix

---

## 🔧 Related Functions

All these functions now use UTC time:

- `GetTimestampNanos()` - Used by IPC and UDP publishers
- `AeronPublishSignal()` - Generic publisher
- `AeronPublishSignalIpc()` - IPC-specific publisher
- `AeronPublishSignalUdp()` - UDP-specific publisher
- `AeronPublishSignalDual()` - Dual-channel publisher

---

## 📖 Technical Details

### MQL5 Time Functions:

| Function        | Returns            | Use Case                        |
| --------------- | ------------------ | ------------------------------- |
| `TimeCurrent()` | Broker server time | Local trading decisions         |
| `TimeLocal()`   | PC local time      | UI display                      |
| `TimeGMT()`     | UTC time           | **Cross-platform messaging** ✅ |

### Timestamp Format:

Both platforms use **nanoseconds since Unix epoch (1970-01-01 00:00:00 UTC)**:

**MQL5:**

```cpp
datetime unixEpoch = D'1970.01.01';
datetime now = TimeGMT();  // UTC
long seconds = (long)(now - unixEpoch);
long nanos = seconds * 1000000000LL;
```

**C#:**

```csharp
DateTime UnixEpochUtc = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
long nanos = (DateTime.UtcNow - UnixEpochUtc).Ticks * 100;
```

Now both calculate from the same UTC reference point!

---

## 🎯 Version History

| Version | Date       | Issue            | Fix                          |
| ------- | ---------- | ---------------- | ---------------------------- |
| 20.8.2  | 2026-02-06 | Timestamp offset | Changed to UTC (`TimeGMT()`) |
| 20.8.1  | 2026-02-06 | Crash loops      | Added exception handling     |
| 20.8    | 2026-02-06 | N/A              | Multi-channel architecture   |

---

## ⚡ Quick Summary

**Problem:** MQL5 sent broker time, NinjaTrader expected UTC → 2-hour offset  
**Solution:** Use `TimeGMT()` instead of `TimeCurrent()` in MQL5  
**Result:** Perfect timestamp alignment across platforms

**Status:** ✅ FIXED - Version 20.8.2

---

## 🚀 Deployment

1. **Recompile EA** in MetaEditor
2. **Reload EA** on all charts
3. **Verify logs** show "V20.8.2" and "Timestamp Fix (UTC)"
4. **Check NinjaTrader** for signal acceptance (not rejection)

No configuration changes needed - the fix is automatic!
