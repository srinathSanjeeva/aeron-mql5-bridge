# Secret Eye V20.9 - Quick Reference Card

## Configuration Quick Start

### Dual Session Setup (3 Steps)
```mql5
// Step 1: Enable manual mode
UseAPITradingHours = false

// Step 2: Configure sessions
ManualStartTime = 3        // Session 1 start (hour)
ManualEndTime = 7          // Session 1 end (hour)
ManualStartTime2 = 9       // Session 2 start (hour, 0=disabled)
ManualEndTime2 = 16        // Session 2 end (hour)

// Step 3: (Optional) Set kill time
ManualKillTime = 16        // Close positions at this hour (0=use session end)
ManualKillMinute = 0       // Close positions at this minute
```

---

## Key Concepts

### Session End vs Kill Time
| Control | Purpose | When It Activates |
|---------|---------|-------------------|
| **Session End Time** | Stops NEW orders | At end of each session |
| **Kill Time** | Closes EXISTING positions | Once per day at specified time |

**Example:**
- Session 1: 09:00-11:00 (stop new orders at 11:00)
- Session 2: 14:00-16:00 (stop new orders at 16:00)
- Kill Time: 17:00 (close all positions at 17:00)
- **Result:** Positions opened at 10:00 AM stay open until 5:00 PM

---

## Input Parameters Summary

### Session 1 (Always Active in Manual Mode)
```
ManualStartTime = 9         // Hour (0-23 EST)
ManualStartMinute = 0       // Minute (0-59)
ManualEndTime = 16          // Hour (0-23 EST)
ManualEndMinute = 0         // Minute (0-59)
```

### Session 2 (Optional)
```
ManualStartTime2 = 0        // Hour (0=disabled, 1-23=enabled)
ManualStartMinute2 = 0      // Minute (0-59)
ManualEndTime2 = 0          // Hour (0-23 EST)
ManualEndMinute2 = 0        // Minute (0-59)
```

### Kill Time (Optional Override)
```
ManualKillTime = 0          // Hour to close positions (0=use session end)
ManualKillMinute = 0        // Minute to close positions
```

### Kill Switch Control
```
EnableKillSwitch = true     // Must be true for automatic closure
```

---

## Common Configurations

### 1️⃣ Single Session (V20.8 Compatible)
```mql5
ManualStartTime = 9
ManualEndTime = 16
ManualStartTime2 = 0        // Disabled
ManualKillTime = 0          // Use session 1 end
EnableKillSwitch = true
```
**Trading:** 9 AM - 4 PM  
**Closure:** 4 PM  
**Behavior:** Classic single session

---

### 2️⃣ Dual Session, Auto Close at Final Session
```mql5
ManualStartTime = 3         // London
ManualEndTime = 7
ManualStartTime2 = 9        // NY
ManualEndTime2 = 16
ManualKillTime = 0          // Use session 2 end (16:00)
EnableKillSwitch = true
```
**Trading:** 3-7 AM, 9 AM-4 PM  
**Closure:** 4 PM (Session 2 end)  
**Behavior:** Trade two sessions, close at end

---

### 3️⃣ Dual Session, Explicit Kill Time
```mql5
ManualStartTime = 9
ManualEndTime = 11
ManualStartTime2 = 14
ManualEndTime2 = 16
ManualKillTime = 17         // Override: 5 PM close
ManualKillMinute = 0
EnableKillSwitch = true
```
**Trading:** 9-11 AM, 2-4 PM  
**Closure:** 5 PM (explicit)  
**Behavior:** Trade two sessions, hold positions until EOD

---

### 4️⃣ Morning Entries Only, EOD Close
```mql5
ManualStartTime = 9
ManualEndTime = 11
ManualStartTime2 = 0        // No second session
ManualKillTime = 16         // Close at 4 PM
ManualKillMinute = 0
EnableKillSwitch = true
```
**Trading:** 9-11 AM only  
**Closure:** 4 PM  
**Behavior:** Take early entries, let them run

---

### 5️⃣ Overnight Asian + European
```mql5
ManualStartTime = 19        // 7 PM EST (Asian)
ManualEndTime = 2           // 2 AM EST (crosses midnight)
ManualStartTime2 = 3        // 3 AM EST (European)
ManualEndTime2 = 11         // 11 AM EST
ManualKillTime = 0          // Use session 2 end
EnableKillSwitch = true
```
**Trading:** 7 PM-2 AM, 3-11 AM  
**Closure:** 11 AM (Session 2 end)  
**Behavior:** Continuous overnight trading

---

## Validation Rules

### ✅ Valid Configurations
- Session 1 only (ManualStartTime2 = 0)
- Two sessions with time gap between them
- Overnight sessions (end < start)
- Kill time after final session end
- Kill time = 0 (uses session end)

### ❌ Invalid Configurations (EA Will Disable Session 2)
- Sessions overlap in time
- Session 2 start within session 1
- Session 1 end within session 2
- Both sessions cover same time range

---

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| "Session validation failed" | Sessions overlap | Adjust times to remove overlap |
| Session 2 not trading | ManualStartTime2 = 0 | Set ManualStartTime2 > 0 |
| No kill switch activation | EnableKillSwitch = false | Set to true |
| Positions not closing | Wrong kill time | Check OnInit() logs for effective kill time |
| "Only available in manual mode" | UseAPITradingHours = true | Set to false |

---

## Log Messages to Check

### At Startup
```
=== TRADING HOURS CONFIGURATION (MANUAL MODE) ===
Current Trading Window: 09:00 to 16:00

=== SECOND SESSION CONFIGURATION ===
Session 2 Time: 14:00 to 18:00
✅ Dual session mode enabled successfully

=== KILL SWITCH TIME CONFIGURATION ===
Explicit kill time set: 17:00 EST/EDT
Positions will close at this time regardless of session end times
```

### During Trading
```
=== KILL SWITCH ACTIVATED ===
Closing positions at explicit kill time: 17:00 EST/EDT
Current EST Time: 17:00
Kill switch executed successfully. Positions closed.
```

---

## Feature Matrix

| Feature | Single Session | Dual Session | Explicit Kill Time |
|---------|----------------|--------------|-------------------|
| Trade in session 1 | ✅ | ✅ | ✅ |
| Trade in session 2 | ❌ | ✅ | ✅ |
| Auto close at session 1 end | ✅ (if no S2) | ❌ | ❌ |
| Auto close at session 2 end | ❌ | ✅ (default) | ❌ |
| Close at custom time | ❌ | ❌ | ✅ |
| Hold positions across gap | ❌ | ✅ (if kill time later) | ✅ |
| Backward compatible | ✅ | ✅ | ✅ |

---

## Testing Checklist

### Before Live
- [ ] Review session times in logs
- [ ] Confirm "Dual session mode enabled" (if using)
- [ ] Check kill switch time configuration
- [ ] Test in Strategy Tester first
- [ ] Verify no overlap warnings

### During Testing
- [ ] Positions open in session 1 ✓
- [ ] No positions during gap ✓
- [ ] Positions open in session 2 ✓
- [ ] Positions close at kill time ✓

---

## Need More Help?

📄 **Detailed Docs:**
- `V20_9_IMPLEMENTATION_GUIDE.md` - Technical details
- `V20_9_RELEASE_SUMMARY.md` - Feature overview

🔍 **Check Logs:**
- OnInit() section shows all configuration
- Look for validation messages
- Review kill switch activation logs

⚠️ **Common Mistakes:**
- Forgot to set `UseAPITradingHours = false`
- Sessions overlap (auto-disabled)
- `EnableKillSwitch = false` (no closure)
- Timezone confusion (all times are EST/EDT)

---

**Version:** 20.90  
**Date:** February 12, 2026  
**Status:** Production Ready ✅
