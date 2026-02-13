# V20.9.1 Trading Hours API Enforcement Hotfix

## Issue Summary

Secret_Eye_V20_9_Forex.mq5 was placing orders **without respecting API trading hours** when `EnableKillSwitch` was set to `false`. V20_8_Ver.mq5 enforced trading hours correctly in all cases.

## Root Cause

Two critical bugs were found in V20.9 Forex edition:

### 1. Early Return Bypass in IsTradingAllowed()

**Location**: Line 1831 of original V20.9 Forex

```mql5
bool IsTradingAllowed()
{
    if(!on) return false;
    if(stopTradingForDay) return false;
    if(stopTradingForProfitProtection) return false;

    if(!EnableKillSwitch) return true;  // ❌ BUG: Bypasses all trading hours validation

    // ... rest of trading hours logic never executed when kill switch disabled
}
```

**Impact**: When `EnableKillSwitch = false` (common configuration), the function would return `true` immediately without checking:

- API trading hours from REST endpoint
- Manual trading hours fallback
- Current EST/EDT time vs configured window

**Result**: Orders placed 24/7 regardless of API configuration.

### 2. Immediate Entry Logic Bypass

**Location**: Lines 646-653 of original V20.9 Forex (OnTick function)

```mql5
// V20.2 - Handle immediate entry
if(immediateEntryPending && !immediateEntryCompleted)
{
    ExecuteImmediateTrade();  // ❌ No IsTradingAllowed() check before execution
    immediateEntryPending = false;
    immediateEntryCompleted = true;
    return;
}

// Regular trading logic from here
if(!IsTradingAllowed())  // ✅ This check comes AFTER immediate entry
{
    CheckKillSwitchPostTimeRecovery();
    return;
}
```

**Impact**: Immediate entry on EA load would execute trades without validating trading hours.

## Fixes Applied

### Fix #1: Refactored IsTradingAllowed() Logic

**Changes**:

- Removed early return when `EnableKillSwitch = false`
- Trading hours validation now **always executes** first
- Kill switch position closing logic moved inside conditional block (only when enabled)
- Added hourly status logging showing:
  - Data source (API vs Manual)
  - Current EST/EDT time
  - Configured trading window
  - Whether currently within trading hours
  - Kill switch enabled/disabled status

**New Logic Flow**:

```mql5
bool IsTradingAllowed()
{
    // 1. Check EA state
    if(!on) return false;
    if(stopTradingForDay) return false;
    if(stopTradingForProfitProtection) return false;

    // 2. Get current time in EST/EDT
    MqlDateTime time;
    TimeCurrent(time);
    int serverToEasternOffset = GetServerToEasternOffset(TimeCurrent());
    int estHour = time.hour + serverToEasternOffset;
    int estMin = time.min;

    // 3. Check for impossible hours (>= 24 means no trading today)
    if(currentStartHour >= 24 || currentEndHour >= 24)
    {
        return false;
    }

    // 4. Calculate if within trading hours (handles normal and overnight windows)
    bool isWithinTradingHours = false;

    if(currentStartHour < currentEndHour)
    {
        // Normal window (e.g., 09:30 - 16:00)
        isWithinTradingHours = (estHour > currentStartHour || (estHour == currentStartHour && estMin >= currentStartMinute)) &&
                               (estHour < currentEndHour || (estHour == currentEndHour && estMin < currentEndMinute));
    }
    else if(currentStartHour > currentEndHour)
    {
        // Overnight window (e.g., 18:00 - 17:00 next day)
        isWithinTradingHours = (estHour > currentStartHour || (estHour == currentStartHour && estMin >= currentStartMinute)) ||
                               (estHour < currentEndHour || (estHour == currentEndHour && estMin < currentEndMinute));
    }
    else
    {
        // Same hour window (e.g., 09:30 - 09:45)
        isWithinTradingHours = (estMin >= currentStartMinute && estMin < currentEndMinute);
    }

    // 5. Execute kill switch logic ONLY if enabled
    if(EnableKillSwitch)
    {
        bool isPastEndTime = (estHour > currentEndHour) || (estHour == currentEndHour && estMin >= currentEndMinute);

        if(isPastEndTime && !killSwitchExecuted)
        {
            // Close all positions and disable trading
            Print("=== KILL SWITCH TRIGGERED ===");
            // ... position closing logic ...
            killSwitchExecuted = true;
            stopTradingForDay = true;
        }
    }

    // 6. Log status hourly
    static datetime lastPrintTime = 0;
    if(TimeCurrent() - lastPrintTime >= 3600)
    {
        string dataSource = UseAPITradingHours && apiDataValid ? "API" : "Manual";
        Print("=== TRADING HOURS STATUS ===");
        Print("Data Source: ", dataSource);
        Print("Within Trading Hours: ", isWithinTradingHours ? "YES" : "NO");
        // ... additional diagnostic info ...
        lastPrintTime = TimeCurrent();
    }

    // 7. Return trading hours validation result (NOT just kill switch status)
    return isWithinTradingHours;
}
```

**Key Improvement**: The function now **always** returns `isWithinTradingHours` which is calculated from API data (via `currentStartHour`, `currentEndHour` populated by `SetTradingHoursForToday()`), not just the kill switch configuration.

### Fix #2: Gate Immediate Entry on Trading Hours

**Changes**:

- Moved `IsTradingAllowed()` check BEFORE immediate entry execution
- Added comprehensive condition validation:
  - `IsTradingAllowed()` - Trading hours validation
  - `IsInitialDelayOver()` - Respects delay configuration
  - `!stopTradingForDay` - Daily loss limit check
  - `!stopTradingForProfitProtection` - Profit protection check
- Added diagnostic logging when immediate entry is waiting (every 30 seconds)

**New Logic Flow** (OnTick):

```mql5
// V20 - Check and update daily trading hours
CheckAndUpdateDailyTradingHours();

// V20.1 - Check daily loss limit and profit protection
if(!CheckDailyLossLimit())
{
    return;  // Stop trading for today
}

CheckDailyProfitProtection();
if(stopTradingForProfitProtection)
{
    return;  // Stop trading but keep EA running
}

// Regular trading logic from here - TRADING HOURS CHECK FIRST
if(!IsTradingAllowed())
{
    CheckKillSwitchPostTimeRecovery();
    return;
}

// V20.2 - Handle immediate entry (AFTER trading hours check)
if(immediateEntryPending && !immediateEntryCompleted)
{
    if(IsTradingAllowed() && IsInitialDelayOver() && !stopTradingForDay && !stopTradingForProfitProtection)
    {
        Print("=== EXECUTING PENDING IMMEDIATE ENTRY ===");
        ExecuteImmediateTrade();
        immediateEntryPending = false;
        immediateEntryCompleted = true;
    }
    else
    {
        // Log diagnostic info every 30 seconds
        static datetime lastImmediateEntryLog = 0;
        if(TimeCurrent() - lastImmediateEntryLog > 30)
        {
            Print("=== IMMEDIATE ENTRY WAITING ===");
            Print("Trading allowed: ", IsTradingAllowed() ? "YES" : "NO");
            Print("Initial delay over: ", IsInitialDelayOver() ? "YES" : "NO");
            Print("Stop trading for day: ", stopTradingForDay ? "YES" : "NO");
            Print("Stop for profit protection: ", stopTradingForProfitProtection ? "YES" : "NO");
            lastImmediateEntryLog = TimeCurrent();
        }
    }
    return;
}

// Continue with regular signal processing (buy/sell conditions)
// This code only executes if IsTradingAllowed() passed above
```

### Fix #3: ExecuteImmediateTrade() Defense-in-Depth

**Note**: This function already had a redundant `IsTradingAllowed()` check at line 1363, providing defense-in-depth. This check remains in place:

```mql5
void ExecuteImmediateTrade()
{
    Print("=== EXECUTING IMMEDIATE TRADE ===");
    UpdateAllPositionStatus();

    if(!IsTradingAllowed())  // ✅ Secondary check (already present)
    {
        Print("Immediate Entry: Trading is not allowed at this time.");
        Print("Current trading hours: ", StringFormat("%02d:%02d", currentStartHour, currentStartMinute),
              " to ", StringFormat("%02d:%02d", currentEndHour, currentEndMinute));
        return;
    }

    // ... proceed with trade execution
}
```

## Testing Recommendations

### 1. Verify API Hours Integration

**Setup**:

```mql5
input bool              UseAPITradingHours = true;
input string            API_Symbol = "ES";
input string            HOST_URI = "http://your-api-endpoint.com";
```

**Test**:

1. Enable API trading hours with valid endpoint
2. Check logs for successful API fetch on EA initialization
3. Verify hourly status logs show "Data Source: API"
4. Confirm orders only placed within API-configured hours

**Expected Output**:

```
=== API TRADING HOURS INITIALIZATION ===
Fetching trading hours for: ES
API Response received: 450 characters
Successfully parsed trading hours for symbol: ES
Trading hours set for Monday: 18:00 - 17:00
=== TRADING HOURS STATUS ===
Data Source: API | Symbol: ES
Within Trading Hours: YES
```

### 2. Test Kill Switch Independence

**Setup**:

```mql5
input bool              UseAPITradingHours = true;
input bool              EnableKillSwitch = false;  // ← Test with disabled
```

**Test**:

1. Disable kill switch
2. Verify trading hours from API still enforced
3. Check that orders placed only within configured window

**Expected Behavior**:

- Trading hours: ✅ ENFORCED (from API)
- Kill switch position closing: ❌ DISABLED

### 3. Test Outside Trading Hours

**Test**:

1. Wait until current time is OUTSIDE API trading hours
2. Monitor EA behavior

**Expected Output**:

```
=== TRADING HOURS STATUS ===
Data Source: API | Symbol: ES
Current Eastern Time (EDT): 17:30
Trading Hours: 18:00 - 17:00
Within Trading Hours: NO
```

**Expected Behavior**:

- No orders placed (buy/sell signals ignored)
- IsTradingAllowed() returns `false`
- No immediate entry execution

### 4. Test Immediate Entry Gating

**Setup**:

```mql5
input bool              ImmediateEntryOnLoad = true;
```

**Test Scenario A** (Within Trading Hours):

1. Load EA during API trading hours
2. Verify immediate entry executes

**Expected Output**:

```
=== EXECUTING PENDING IMMEDIATE ENTRY ===
Conditions met: Trading allowed + Initial delay over
=== EXECUTING IMMEDIATE TRADE ===
Immediate entry condition: BUY (Main > Signal).
✅ Immediate entry BUY positions opened successfully
```

**Test Scenario B** (Outside Trading Hours):

1. Load EA OUTSIDE API trading hours
2. Verify immediate entry waits

**Expected Output**:

```
=== IMMEDIATE ENTRY WAITING ===
Trading allowed: NO
Initial delay over: YES
Stop trading for day: NO
Stop for profit protection: NO
```

### 5. Compare with V20.8 Behavior

**Test**:

1. Run identical configuration on V20.8 and V20.9.1
2. Verify both respect API hours identically

**Expected**: Both versions should:

- Fetch API hours successfully
- Log hourly status
- Only place orders within configured window
- Handle kill switch independently of trading hours

## Configuration Examples

### Example 1: API Hours + Kill Switch Enabled

```mql5
input bool              UseAPITradingHours = true;
input string            API_Symbol = "ES";
input string            HOST_URI = "http://trading-hours-api.com";
input bool              EnableKillSwitch = true;
input int               ManualStartTime = 9;
input int               ManualStartMinute = 30;
input int               ManualEndTime = 16;
input int               ManualEndMinute = 0;
```

**Behavior**:

- Trading hours: ✅ From API (ES futures hours)
- Manual hours: Fallback if API fails
- Kill switch: ✅ Closes positions at end time

### Example 2: API Hours + Kill Switch Disabled

```mql5
input bool              UseAPITradingHours = true;
input string            API_Symbol = "NQ";
input bool              EnableKillSwitch = false;  // ← Positions stay open
```

**Behavior**:

- Trading hours: ✅ From API (NQ futures hours)
- Kill switch: ❌ Does NOT close positions
- **NEW**: Trading hours still enforced (FIXED in V20.9.1)

### Example 3: Manual Hours Only

```mql5
input bool              UseAPITradingHours = false;
input int               ManualStartTime = 9;
input int               ManualStartMinute = 30;
input int               ManualEndTime = 16;
input int               ManualEndMinute = 0;
input bool              EnableKillSwitch = true;
```

**Behavior**:

- Trading hours: ✅ Manual (09:30 - 16:00 EST)
- Kill switch: ✅ Closes positions at 16:00 EST

## Version Information

**File**: `MQL5/Secret_Eye_V20_9_Forex.mq5`  
**Version**: 20.91  
**Released**: February 13, 2026  
**Compatibility**: Requires MQL5 build 3650+ and Aeron C client

## Migration from V20.9 to V20.9.1

**No configuration changes required** - this is a drop-in bugfix replacement.

### Steps:

1. Backup existing `Secret_Eye_V20_9_Forex.mq5`
2. Replace with V20.9.1 version
3. Recompile in MetaEditor
4. Restart EA instances
5. Monitor logs for trading hours status

### Verification:

```
Check logs for:
✅ "=== TRADING HOURS STATUS ===" every hour
✅ "Data Source: API" (if UseAPITradingHours = true)
✅ "Within Trading Hours: YES/NO" reflects actual hours
✅ No orders placed when "Within Trading Hours: NO"
```

## Related Files

- `Secret_Eye_V20_8_Ver.mq5` - Reference implementation (correct behavior)
- `Secret_Eye_V20_9_Complete.mq5` - May also need this fix
- `CLAUDE.md` - Project documentation

## API Trading Hours Integration

The fix ensures the EA correctly uses trading hours from the REST API endpoint configured via:

- `UseAPITradingHours` - Enable/disable API integration
- `API_Symbol` - Symbol to query (e.g., "ES", "NQ", "YM")
- `HOST_URI` - API endpoint URL

**API Response Format** (example):

```json
{
  "symbol": "ES",
  "timezone": "America/New_York",
  "weekly_schedule": {
    "sunday": { "start": "18:00", "end": "17:00" },
    "monday": { "start": "18:00", "end": "17:00" },
    "tuesday": { "start": "18:00", "end": "17:00" },
    "wednesday": { "start": "18:00", "end": "17:00" },
    "thursday": { "start": "18:00", "end": "17:00" },
    "friday": { "start": "18:00", "end": "16:00" },
    "saturday": null
  }
}
```

The `ParseTradingHoursJSON()` and `SetTradingHoursForToday()` functions extract and apply these hours to `currentStartHour`, `currentStartMinute`, `currentEndHour`, `currentEndMinute` which are then validated by `IsTradingAllowed()`.

## Commit Message

```
fix: enforce trading hours API in V20.9 Forex regardless of kill switch

The IsTradingAllowed() function was returning true immediately when
EnableKillSwitch=false, bypassing all trading hours validation from the
API. This caused orders to be placed 24/7 even when outside configured
trading windows.

Changes:
- Remove early return when kill switch disabled in IsTradingAllowed()
- Always calculate and return isWithinTradingHours from API/manual config
- Move kill switch position closing into conditional block
- Gate immediate entry execution on IsTradingAllowed() check
- Add hourly status logging showing data source and hours compliance
- Add diagnostic logging for waiting immediate entry

Fixes trading hours enforcement to match V20.8 behavior.

Version: 20.91
```

## References

- [V20_8_IMPLEMENTATION_SUMMARY.md](../V20_8_IMPLEMENTATION_SUMMARY.md)
- [V20_9_IMPLEMENTATION_GUIDE.md](V20_9_IMPLEMENTATION_GUIDE.md)
- [V20_9_RELEASE_SUMMARY.md](V20_9_RELEASE_SUMMARY.md)
