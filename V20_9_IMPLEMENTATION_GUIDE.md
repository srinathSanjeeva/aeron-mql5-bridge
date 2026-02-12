# Secret Eye V20.9 - Technical Implementation Guide

## Overview
Version 20.9 adds **dual trading session support** with an **optional kill time override** for manual trading hours mode. This allows the EA to trade in two separate time windows (e.g., London session + NY session) with independent control over when new orders can be placed vs when existing positions must be closed.

---

## 1. Feature Summary

### Core Capabilities
- ✅ **Two independent trading sessions** in manual mode
- ✅ **Automatic session overlap validation** prevents configuration conflicts
- ✅ **Optional kill time** for position closure independent of session end times
- ✅ **Separation of concerns**: Session times control new orders, kill time controls position closure
- ✅ **Backward compatible**: Session 2 disabled by default (ManualStartTime2 = 0)
- ✅ **Works with all V20.8.3 features**: Aeron publishing, API mode, kill switch, etc.

---

## 2. New Input Parameters

### Session 2 Parameters (Manual Mode Only)
```mql5
input group             "V20.9 - Second Trading Session (Manual Mode Only)"
input int               ManualStartTime2 = 0;           // Session 2: Start time (hour, 0=disabled)
input int               ManualStartMinute2 = 0;         // Session 2: Start time (minute)
input int               ManualEndTime2 = 0;             // Session 2: End time (hour)
input int               ManualEndMinute2 = 0;           // Session 2: End time (minute)
```

### Kill Switch Time Parameters (Optional Override)
```mql5
input group             "V20.9 - Kill Switch Time (Optional Override)"
input int               ManualKillTime = 0;             // Kill time: Hour to close positions (0=use session end)
input int               ManualKillMinute = 0;           // Kill time: Minute to close positions
```

**Activation:** Session 2 is enabled when `ManualStartTime2 > 0` in manual mode (`UseAPITradingHours = false`).
**Kill Time:** When `ManualKillTime > 0`, positions close at this time instead of session end times.

---

## 3. New Global Variables

```mql5
// V20.9 - Second Session Variables (Manual Mode Only)
static int          currentStartHour2 = 0;
static int          currentStartMinute2 = 0;
static int          currentEndHour2 = 0;
static int          currentEndMinute2 = 0;
static bool         session2Enabled = false;           // Track if session 2 is active

// V20.9 - Kill Switch Time Variables
static int          killSwitchHour = 0;                // Effective kill switch hour
static int          killSwitchMinute = 0;              // Effective kill switch minute
static bool         useExplicitKillTime = false;       // True if ManualKillTime > 0
```

---

## 4. Session Overlap Validation

### Function: `ValidateSessionsNonOverlapping()`

**Purpose:** Prevents session 1 and session 2 from overlapping, which would cause ambiguous trading behavior.

**Logic:**
1. Converts all session times to minutes since midnight for comparison
2. Handles **same-day sessions**: `start1 < end1` and `start2 < end2`
3. Handles **overnight sessions**: When end < start (crosses midnight)
4. Handles **both-overnight**: Both sessions cross midnight

**Validation Rules:**
- Session 2 start must NOT be within session 1
- Session 2 end must NOT be within session 1
- Session 1 start must NOT be within session 2
- Session 1 end must NOT be within session 2

**Returns:** `true` if sessions are valid (non-overlapping), `false` if overlap detected

**Example:**
```mql5
// Valid: London AM + NY PM
Session 1: 03:00 to 07:00
Session 2: 09:30 to 16:00  ✅ No overlap

// Invalid: Overlapping sessions
Session 1: 08:00 to 12:00
Session 2: 10:00 to 14:00  ❌ Overlap detected (10:00-12:00)
```

---

## 5. Enhanced Trading Hours Logic

### Function: `IsTradingAllowed()` (Enhanced)

**Original behavior:** Checked if current time is within session 1 window.

**V20.9 enhancement:** Now checks if current time is within **either** session 1 OR session 2 window.

**Key Logic:**
```mql5
bool withinSession1 = IsTimeInSession(estHour, time.min, 
                                      currentStartHour, currentStartMinute,
                                      currentEndHour, currentEndMinute);

bool withinSession2 = false;
if(session2Enabled)
{
    withinSession2 = IsTimeInSession(estHour, time.min,
                                     currentStartHour2, currentStartMinute2,
                                     currentEndHour2, currentEndMinute2);
}

// Allow trading if within EITHER session
if(!withinSession1 && !withinSession2)
{
    // Outside all trading sessions
    return false;
}
```

**Result:** EA can open new positions during either session 1 OR session 2.

---

## 6. Kill Switch Enhancement

### Position Closure Logic
The kill switch has been enhanced to work with dual sessions:

1. **Explicit Kill Time**: If `ManualKillTime > 0`, positions close at this specific time
2. **Session End Time**: If kill time not set, positions close at the end of the **final active session**:
   - If Session 2 enabled: Uses Session 2 end time
   - If Session 2 disabled: Uses Session 1 end time

### Trading vs Position Closure
- **Session End Times**: Control when NEW orders can be placed (via `IsTradingAllowed()`)
- **Kill Time**: Controls when EXISTING positions are closed
- Sessions can end without closing positions if kill time is set later

### Configuration
```mql5
// Kill switch configuration in OnInit()
if(ManualKillTime > 0)
{
    killSwitchHour = ManualKillTime;
    killSwitchMinute = ManualKillMinute;
    useExplicitKillTime = true;
}
else
{
    // Use end time of final active session
    if(session2Enabled)
    {
        killSwitchHour = currentEndHour2;
        killSwitchMinute = currentEndMinute2;
    }
    else
    {
        killSwitchHour = currentEndHour;
        killSwitchMinute = currentEndMinute;
    }
    useExplicitKillTime = false;
}
```

---

## 7. Key Design Decisions

### 1. Manual Mode Only
Session 2 only works in manual mode (`UseAPITradingHours = false`). API mode already provides dynamic scheduling.

### 2. Zero-Value Disables Session 2
Setting `ManualStartTime2 = 0` disables session 2 entirely, maintaining backward compatibility.

### 3. Session Overlap Prevention
The EA will NOT start if sessions overlap. This prevents ambiguous behavior and configuration errors.

### 4. Session-Aware Kill Time
- Kill time defaults to final session end (Session 2 if enabled)
- Explicit kill time can override session end times
- Positions can continue running after session end if kill time is later

### 5. All V20.8.3 Features Preserved
Dual sessions work with:
- Profit/loss protection
- Stochastic indicator logic
- Aeron binary publishing
- JSON telemetry
- Exception handling
- All existing inputs

---

## 8. Use Cases

### Use Case 1: Multi-Market Trading
**Scenario:** Trade London open (3 AM - 7 AM EST) + NY open (9:30 AM - 12 PM EST)
```
ManualStartTime = 3, ManualEndTime = 7
ManualStartTime2 = 9, ManualEndTime2 = 12
ManualKillTime = 15, ManualKillMinute = 0
```
**Behavior:** Open positions in London and NY sessions, close at 3 PM.

### Use Case 2: Overnight + Day Session
**Scenario:** Trade Asian session (7 PM - 2 AM) + European session (3 AM - 11 AM)
```
ManualStartTime = 19, ManualEndTime = 2
ManualStartTime2 = 3, ManualEndTime2 = 11
ManualKillTime = 0  // Use Session 2 end
```
**Behavior:** Continuous trading overnight into morning, close at 11 AM.

### Use Case 3: Separate Day Sessions
**Scenario:** Morning session (9 AM - 12 PM) + Afternoon session (2 PM - 4 PM)
```
ManualStartTime = 9, ManualEndTime = 12
ManualStartTime2 = 14, ManualEndTime2 = 16
ManualKillTime = 0  // Use Session 2 end
```
**Behavior:** Independent morning and afternoon sessions, close at 4 PM.

### Use Case 4: Independent Kill Time
**Scenario:** Trade in morning, but allow positions to run until EOD
```
ManualStartTime = 9, ManualEndTime = 11
ManualStartTime2 = 0  // No second session
ManualKillTime = 16, ManualKillMinute = 0
```
**Behavior:** Open positions 9-11 AM only, close at 4 PM.

---

## 9. Testing Checklist

### Basic Functionality
- [ ] Session 2 disabled when `ManualStartTime2 = 0`
- [ ] Session 2 logs show correct times when enabled
- [ ] EA refuses to start with overlapping sessions
- [ ] Trading occurs during both sessions
- [ ] Kill time logs show correct final session or explicit time

### Session Transitions
- [ ] No new positions opened between sessions
- [ ] Existing positions remain open between sessions (if kill time not reached)
- [ ] New positions can open when session 2 starts
- [ ] Kill switch activates at correct time

### Edge Cases
- [ ] Overnight session 1 works (e.g., 22:00 to 02:00)
- [ ] Overnight session 2 works
- [ ] Both sessions overnight (rare but valid)
- [ ] Same-day sessions separated by gap
- [ ] Explicit kill time different from session ends

### Backward Compatibility
- [ ] V20.8.3 configs work unchanged (ManualStartTime2 = 0)
- [ ] Single-session mode behaves identically to V20.8.3
- [ ] All error messages/alerts still functional

---

## 10. API Reference

### New Functions

#### `ValidateSessionsNonOverlapping()`
```mql5
bool ValidateSessionsNonOverlapping()
```
**Returns:** `true` if sessions are valid, `false` if overlap detected
**Side effects:** Logs validation results, alerts user if overlap found

### Modified Functions

#### `IsTradingAllowed()`
```mql5
bool IsTradingAllowed()
```
**Enhancement:** Now checks both session 1 and session 2 windows
**Returns:** `true` if within either session window

#### `OnInit()`
**Enhancement:** Initializes session 2 variables, validates overlaps, configures kill time
**New validation:** Calls `ValidateSessionsNonOverlapping()` before enabling session 2

---

## 11. Migration from V20.8.3

### For Existing Users
**No changes required!** V20.9 is fully backward compatible:
- Leave `ManualStartTime2 = 0` (default)
- EA behaves exactly like V20.8.3

### To Enable Dual Sessions
1. Set `UseAPITradingHours = false`
2. Configure session 1: `ManualStartTime`, `ManualEndTime`
3. Configure session 2: `ManualStartTime2 = <hour>`, `ManualEndTime2 = <hour>`
4. (Optional) Set kill time: `ManualKillTime = <hour>`
5. Verify no overlap in EA logs at startup

---

## 12. Troubleshooting

### "Session validation failed - disabling session 2"
**Cause:** Sessions overlap in time
**Fix:** Adjust session times to remove overlap
**Example:** If session 1 ends at 12:00, session 2 must start at 12:01 or later

### "Second session is only available in manual mode"
**Cause:** `UseAPITradingHours = true`
**Fix:** Set `UseAPITradingHours = false` to use manual sessions

### Positions not closing at expected time
**Cause:** Kill time may be using session end instead of explicit time
**Check:** Review OnInit() logs for "Kill switch will use..." message
**Fix:** Set `ManualKillTime` explicitly if needed

### Trading not occurring in session 2
**Cause:** Session 2 may be disabled due to validation failure or ManualStartTime2 = 0
**Check:** Look for "Dual session mode enabled successfully" in logs
**Fix:** Verify session 2 inputs are correct and sessions don't overlap

---

## End of Implementation Guide
