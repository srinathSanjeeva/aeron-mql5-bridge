# V20.9.1 - Quick Reference

## What Was Fixed

Secret_Eye_V20_9_Forex.mq5 was **ignoring API trading hours** when `EnableKillSwitch = false`.

## Root Cause

```mql5
// ❌ BUG (V20.9 original):
bool IsTradingAllowed()
{
    if(!EnableKillSwitch) return true;  // Bypass ALL hours checks!
    // ... trading hours validation never executes
}
```

## The Fix

```mql5
// ✅ FIXED (V20.9.1):
bool IsTradingAllowed()
{
    // Always calculate trading hours compliance
    bool isWithinTradingHours = /* calculate from API hours */;

    // Kill switch only affects position closing, not hours validation
    if(EnableKillSwitch) { /* close positions at end time */ }

    return isWithinTradingHours;  // Always enforced
}
```

## Key Changes

1. **IsTradingAllowed()** - Removed early return, always validates hours
2. **OnTick()** - Immediate entry now gated on `IsTradingAllowed()`
3. **Logging** - Hourly status shows API data source and compliance

## Verification

Check your MT5 Expert log for:

```
=== TRADING HOURS STATUS ===
Data Source: API | Symbol: ES
Current Eastern Time (EDT): 14:30
Trading Hours: 18:00 - 17:00
Within Trading Hours: YES
Kill Switch: DISABLED
```

## Migration

No config changes needed - just replace the file and recompile.

## Version

- **Before**: 20.90
- **After**: 20.91
- **File**: `MQL5/Secret_Eye_V20_9_Forex.mq5`

## Testing Checklist

- [ ] API hours fetch successfully on init
- [ ] Hourly logs show "Data Source: API"
- [ ] Orders only placed within configured hours
- [ ] Kill switch disabled still respects hours
- [ ] Immediate entry waits for trading hours

## Configuration That Was Broken

```mql5
input bool UseAPITradingHours = true;   // Using API
input bool EnableKillSwitch = false;     // ❌ This broke hours checking
```

## Now Works Correctly

```mql5
input bool UseAPITradingHours = true;   // ✅ Hours enforced from API
input bool EnableKillSwitch = false;     // ✅ Kill switch independent
```

## Documentation

See [V20_9_1_TRADING_HOURS_HOTFIX.md](V20_9_1_TRADING_HOURS_HOTFIX.md) for full details.
