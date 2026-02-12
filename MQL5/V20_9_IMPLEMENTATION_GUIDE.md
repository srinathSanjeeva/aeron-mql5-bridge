# Secret Eye V20.9 - Dual Session Trading Hours Implementation Guide

## Overview

Version 20.9 adds support for dual trading sessions when using manual time mode (UseAPITradingHours = false). This allows traders to specify two independent time windows for trading within a single day.

## Key Features

### 1. New Input Parameters (Added to "V20.9 - Second Trading Session" group)

```mql5
input group             "V20.9 - Second Trading Session (Manual Mode Only)"
input int               ManualStartTime2 = 0;           // Session 2: Start time (hour, 0=disabled)
input int               ManualStartMinute2 = 0;         // Session 2: Start time (minute)
input int               ManualEndTime2 = 0;             // Session 2: End time (hour)
input int               ManualEndMinute2 = 0;           // Session 2: End time (minute)
```

### 2. New Global Variables (Added after existing session variables)

```mql5
// V20.9 - Second Session Variables (Manual Mode Only)
static int          currentStartHour2 = 0;
static int          currentStartMinute2 = 0;
static int          currentEndHour2 = 0;
static int          currentEndMinute2 = 0;
static bool         session2Enabled = false;           // Track if session 2 is active
```

### 3. Session Overlap Validation Function

```mql5
bool ValidateSessionsNonOverlapping()
{
    if(!session2Enabled) return true;

    int session1Start = currentStartHour * 60 + currentStartMinute;
    int session1End = currentEndHour * 60 + currentEndMinute;
    int session2Start = currentStartHour2 * 60 + currentStartMinute2;
    int session2End = currentEndHour2 * 60 + currentEndMinute2;

    bool session1_overnight = (session1End < session1Start);
    bool session2_overnight = (session2End < session2Start);
    bool overlap = false;

    if(!session1_overnight && !session2_overnight)
    {
        overlap = (session1Start < session2End) && (session2Start < session1End);
    }
    else if(session1_overnight && !session2_overnight)
    {
        overlap = (session2Start >= session1Start) || (session2End <= session1End);
    }
    else if(!session1_overnight && session2_overnight)
    {
        overlap = (session1Start >= session2Start) || (session1End <= session2End);
    }
    else
    {
        overlap = true; // Both overnight sessions always overlap
    }

    if(overlap)
    {
        Print("❌ SESSION OVERLAP DETECTED");
        session2Enabled = false;
        if(ShowAlerts)
        {
            Alert("⚠️ SESSION OVERLAP ERROR - Session 2 disabled");
        }
        return false;
    }

    return true;
}
```

### 4. Modified IsTradingAllowed() Function

The IsTradingAllowed() function has been enhanced to check both sessions:

```mql5
bool IsTradingAllowed()
{
    MqlDateTime time;
    TimeCurrent(time);

    int serverToEasternOffset = GetServerToEasternOffset(TimeCurrent());
    int estHour = time.hour + serverToEasternOffset;
    if(estHour < 0) estHour += 24;
    if(estHour >= 24) estHour -= 24;
    int estMinutes = estHour * 60 + time.min;

    // Check Session 1
    int startMinutes1 = currentStartHour * 60 + currentStartMinute;
    int endMinutes1 = currentEndHour * 60 + currentEndMinute;

    bool withinSession1 = false;
    if(startMinutes1 < endMinutes1)
    {
        withinSession1 = (estMinutes >= startMinutes1 && estMinutes < endMinutes1);
    }
    else if(startMinutes1 > endMinutes1)
    {
        withinSession1 = (estMinutes >= startMinutes1 || estMinutes < endMinutes1);
    }

    // Check Session 2 (if enabled)
    bool withinSession2 = false;
    if(session2Enabled)
    {
        int startMinutes2 = currentStartHour2 * 60 + currentStartMinute2;
        int endMinutes2 = currentEndHour2 * 60 + currentEndMinute2;

        if(startMinutes2 < endMinutes2)
        {
            withinSession2 = (estMinutes >= startMinutes2 && estMinutes < endMinutes2);
        }
        else if(startMinutes2 > endMinutes2)
        {
            withinSession2 = (estMinutes >= startMinutes2 || estMinutes < endMinutes2);
        }
    }

    // Trading allowed if within either session
    bool withinHours = withinSession1 || withinSession2;

    // Logging
    static bool lastStatus = false;
    if(withinHours != lastStatus)
    {
        if(withinSession1 && withinSession2)
            Print("Trading hours status changed: ALLOWED (both sessions active!)");
        else if(withinSession1)
            Print("Trading hours status changed: ALLOWED (session 1)");
        else if(withinSession2)
            Print("Trading hours status changed: ALLOWED (session 2)");
        else
            Print("Trading hours status changed: NOT ALLOWED");
        lastStatus = withinHours;
    }

    return withinHours;
}
```

### 5. OnInit() Additions

Add this code in OnInit() after the primary session initialization (after line ~1225 in V20.8.3):

```mql5
// V20.9 - Second Session Initialization (Manual Mode Only)
if(!UseAPITradingHours)
{
    if(ManualStartTime2 > 0)
    {
        Print("=== SECOND SESSION CONFIGURATION ===");
        currentStartHour2 = ManualStartTime2;
        currentStartMinute2 = ManualStartMinute2;
        currentEndHour2 = ManualEndTime2;
        currentEndMinute2 = ManualEndMinute2;
        session2Enabled = true;

        Print("Session 2 Time: ", StringFormat("%02d:%02d", currentStartHour2, currentStartMinute2),
              " to ", StringFormat("%02d:%02d", currentEndHour2, currentEndMinute2));

        if(!ValidateSessionsNonOverlapping())
        {
            Print("⚠️ WARNING: Session validation failed - disabling session 2");
            session2Enabled = false;
        }
        else
        {
            Print("✅ Dual session mode enabled successfully");
            if(ShowAlerts)
            {
                Alert("✅ DUAL SESSION: Trading in two time windows");
                Alert("Session 1: ", StringFormat("%02d:%02d-%02d:%02d",
                      currentStartHour, currentStartMinute, currentEndHour, currentEndMinute));
                Alert("Session 2: ", StringFormat("%02d:%02d-%02d:%02d",
                      currentStartHour2, currentStartMinute2, currentEndHour2, currentEndMinute2));
            }
        }
    }
    else
    {
        Print("Second session disabled (ManualStartTime2 = 0)");
        session2Enabled = false;
    }
}
else
{
    Print("Second session is only available in manual mode (UseAPITradingHours=false)");
    session2Enabled = false;
}
```

## Use Cases

### Example 1: London + New York Sessions

```
UseAPITradingHours = false
ManualStartTime = 3
ManualStartMinute = 0
ManualEndTime = 12
ManualEndMinute = 0

ManualStartTime2 = 14
ManualStartMinute2 = 30
ManualEndTime2 = 21
ManualEndMinute2 = 0
```

Result: Trades 03:00-12:00 and 14:30-21:00 EST

### Example 2: Asian + European Sessions

```
ManualStartTime = 19
ManualStartMinute = 0
ManualEndTime = 23
ManualEndMinute = 59

ManualStartTime2 = 2
ManualStartMinute2 = 0
ManualEndTime2 = 11
ManualEndMinute2 = 0
```

Result: Trades 19:00-23:59 and 02:00-11:00 EST (first session overnight)

### Example 3: Single Session (Backward Compatible)

```
ManualStartTime = 9
ManualStartMinute = 30
ManualEndTime = 16
ManualEndMinute = 0

ManualStartTime2 = 0  // Disabled
```

Result: Trades only 09:30-16:00 EST (V20.8 behavior)

## Backward Compatibility

V20.9 is fully backward compatible with V20.8.3 configurations:

- If `ManualStartTime2 = 0`, only session 1 is used
- If `UseAPITradingHours = true`, session 2 is ignored
- All V20.8.3 features remain unchanged

## Implementation Steps

To create the complete V20.9 file:

1. Start with Secret_Eye_V20_8_Ver.mq5
2. Update version number to "20.90"
3. Add changelog notes at the top
4. Add new input parameters in the "API Trading Hours" section
5. Add new global variables after existing session variables
6. Add `ValidateSessionsNonOverlapping()` function before OnInit
7. Modify `IsTradingAllowed()` function with dual session logic
8. Add session 2 initialization code in OnInit()
9. Update `AeronSourceTag` default to "SecretEye_V20_9"
10. Compile and test with dual sessions

## Testing Checklist

- [ ] Single session mode (session 2 disabled)
- [ ] Dual sessions with no overlap (same day)
- [ ] Dual sessions with overnight session 1
- [ ] Dual sessions with overnight session 2
- [ ] Overlap detection and prevention
- [ ] API mode disables session 2
- [ ] Trading hours logging shows both sessions
- [ ] Alert notifications for dual sessions
- [ ] Kill switch works with dual sessions
- [ ] Position recovery after restart

## Notes

- Second session only works when `UseAPITradingHours = false`
- Sessions are validated to prevent overlaps
- Overnight sessions are supported (end time < start time)
- If overlap detected, session 2 is automatically disabled
- Both sessions use the same server time offset and DST settings
- Trading is allowed if current time is within EITHER session
