# Secret Eye V20.9 - Release Summary
**Date:** February 12, 2026  
**Version:** 20.90  
**Base:** V20.8.3 (Secret_Eye_V20_8_Ver.mq5)

---

## What's New in V20.9

### 1. Dual Trading Session Support 🆕
- **Second trading window** for manual time mode
- Independent start/end times per session
- Automatic validation prevents session overlap
- Perfect for multi-market strategies (e.g., London + NY, Asian + European)

### 2. Optional Kill Time Override 🆕
- **Explicit kill time** for position closure independent of session end times
- Set `ManualKillTime` > 0 to close positions at specific time
- If not set, defaults to final session end time (Session 2 if enabled, otherwise Session 1)
- **Separation of concerns**: Session times control new orders, kill time controls position closure

### 3. Input Parameters

#### Second Session (Manual Mode Only)
```
ManualStartTime2 = 0      // Session 2 start hour (0=disabled)
ManualStartMinute2 = 0    // Session 2 start minute
ManualEndTime2 = 0        // Session 2 end hour
ManualEndMinute2 = 0      // Session 2 end minute
```

#### Kill Switch Time (Optional Override)
```
ManualKillTime = 0        // Hour to close positions (0=use session end)
ManualKillMinute = 0      // Minute to close positions
```

---

## Key Features

### ✅ Backward Compatible
- Default configuration (`ManualStartTime2 = 0`) behaves exactly like V20.8.3
- All existing strategies continue to work without changes
- Session 2 is opt-in

### ✅ Automatic Safety Validation
- EA validates that sessions don't overlap at startup
- If overlap detected, session 2 is automatically disabled with warning
- Prevents configuration errors and ambiguous trading behavior

### ✅ Works with All V20.8.3 Features
- Profit/loss protection
- Stochastic indicator logic
- Aeron binary publishing (IPC/UDP)
- JSON telemetry / Kafka REST
- Kill switch
- Exception handling
- All risk management features

### ✅ Flexible Position Closure
- **Option 1:** Explicit kill time for end-of-day closure
- **Option 2:** Automatic closure at end of final session
- Sessions end = no new orders; Kill time = close positions
- Positions can run across session gap if kill time is later

---

## Configuration Examples

### Example 1: London + NY Sessions with Kill Time
```
UseAPITradingHours = false
ManualStartTime = 3        // London open (3:00 AM EST)
ManualStartMinute = 0
ManualEndTime = 7          // London close (7:00 AM EST)
ManualEndMinute = 0

ManualStartTime2 = 9       // NY open (9:30 AM EST)
ManualStartMinute2 = 30
ManualEndTime2 = 12        // NY pause (12:00 PM EST)
ManualEndMinute2 = 0

ManualKillTime = 15        // Close all positions at 3:00 PM EST
ManualKillMinute = 0

EnableKillSwitch = true
```
**Result:** Trade in London (3:00-7:00) and NY (9:30-12:00), but keep positions open until 3:00 PM kill time.

### Example 2: Asian + European Sessions (Overnight)
```
ManualStartTime = 19       // Asian open (7:00 PM EST)
ManualStartMinute = 0
ManualEndTime = 2          // Asian close (2:00 AM EST next day)
ManualEndMinute = 0

ManualStartTime2 = 3       // European open (3:00 AM EST)
ManualStartMinute2 = 0
ManualEndTime2 = 11        // European close (11:00 AM EST)
ManualEndMinute2 = 0

ManualKillTime = 0         // Use Session 2 end time (11:00 AM)
ManualKillMinute = 0

EnableKillSwitch = true
```
**Result:** Trade overnight Asian session, continue into European, close positions at 11:00 AM (Session 2 end).

### Example 3: Morning Only + EOD Kill Time
```
ManualStartTime = 9        // Morning session (9:00 AM EST)
ManualStartMinute = 0
ManualEndTime = 11         // Stop new orders (11:00 AM EST)
ManualEndMinute = 0

ManualStartTime2 = 0       // No second session
ManualStartMinute2 = 0

ManualKillTime = 16        // Close positions at 4:00 PM EST
ManualKillMinute = 0

EnableKillSwitch = true
```
**Result:** Open positions 9-11 AM only, let them run until 4 PM EOD.

### Example 4: Single Session (V20.8.3 Compatible)
```
UseAPITradingHours = false
ManualStartTime = 9
ManualEndTime = 16

ManualStartTime2 = 0       // Session 2 disabled
ManualKillTime = 0         // Use Session 1 end time

EnableKillSwitch = true
```
**Result:** Behaves exactly like V20.8.3 single session.

---

## Use Cases

| Scenario | Session 1 | Session 2 | Kill Time | Benefit |
|----------|-----------|-----------|-----------|---------|
| London + NY | 03:00-07:00 | 09:30-16:00 | 16:00 | Capture both market opens |
| Overnight Asian-European | 19:00-02:00 | 03:00-11:00 | 11:00 | Continuous overnight trading |
| Morning + Afternoon | 09:00-12:00 | 14:00-16:00 | 16:00 | Avoid lunch volatility |
| Morning entries, EOD close | 09:00-11:00 | Disabled | 16:00 | Take entries early, hold until close |
| Frankfurt + London | 02:00-04:00 | 03:00-07:00 ❌ | - | **INVALID** - overlap detected |

---

## Testing Checklist

### Before Live Trading
- [ ] Verify session times in EA logs at startup
- [ ] Confirm "Dual session mode enabled successfully" message (if using session 2)
- [ ] Check kill switch time configuration in logs
- [ ] Test in Strategy Tester with historical data
- [ ] Verify no overlap warnings

### During Testing
- [ ] Confirm new positions open during session 1
- [ ] Confirm no positions open between sessions (gap period)
- [ ] Confirm new positions open during session 2
- [ ] Verify positions close at correct kill time
- [ ] Check Aeron/JSON publishing still works

### Edge Cases to Test
- [ ] Overnight session 1 (e.g., 22:00 to 02:00)
- [ ] Overnight session 2
- [ ] Both sessions overnight (rare configuration)
- [ ] Kill switch with EnableKillSwitch = false (should not close)
- [ ] Kill switch at explicit time vs session end time

---

## Upgrade Instructions

### From V20.8.3 to V20.9

#### Option A: Keep Single Session (No Changes)
1. Copy existing V20.8.3 configuration
2. Compile V20.9
3. Continue using - works identically

#### Option B: Enable Dual Session
1. Set `UseAPITradingHours = false`
2. Configure session 1 times
3. Set `ManualStartTime2 = <hour>` (enables session 2)
4. Configure session 2 times
5. (Optional) Set explicit kill time
6. Verify no overlap error at startup
7. Test in Strategy Tester first

---

## Technical Changes

### New Code
- `ValidateSessionsNonOverlapping()` - Detects session overlap
- Enhanced `IsTradingAllowed()` - Checks both sessions
- Kill time configuration logic in `OnInit()`
- Enhanced kill switch logic with dual session support

### Modified Code
- `OnInit()` - Initializes session 2, validates overlaps, configures kill time
- Kill switch logic - Now uses kill time or final session end

### New Variables
- `currentStartHour2`, `currentStartMinute2`, `currentEndHour2`, `currentEndMinute2`
- `session2Enabled` - Tracks if session 2 is active
- `killSwitchHour`, `killSwitchMinute` - Effective kill time
- `useExplicitKillTime` - True if ManualKillTime > 0

### Version Metadata
- **Version:** 20.90
- **AeronSourceTag:** `SecretEye_V20_9`
- **Changelog:** Added to version history

---

## Important Notes

### ⚠️ Manual Mode Only
Session 2 only works when `UseAPITradingHours = false`. API mode already provides dynamic scheduling via REST API.

### ⚠️ EST/EDT Timezone
All session times are in **Eastern Time** (EST/EDT). The EA automatically handles DST transitions.

### ⚠️ Session Overlap = Disabled
If sessions overlap, the EA will:
1. Log a warning
2. Disable session 2
3. Continue with session 1 only
4. Alert user if `ShowAlerts = true`

### ⚠️ Kill Time Behavior
- **Session end times**: Prevent NEW orders via `IsTradingAllowed()`
- **Kill time**: Closes EXISTING positions when reached
- These are independent controls for maximum flexibility

### ⚠️ Kill Switch Must Be Enabled
Set `EnableKillSwitch = true` for automatic position closure at kill time. If `false`, positions remain open.

---

## Support & Documentation

### Files Included
- `Secret_Eye_V20_9_Complete.mq5` - Main EA file
- `V20_9_IMPLEMENTATION_GUIDE.md` - Technical details for developers
- `V20_9_RELEASE_SUMMARY.md` - This file (user guide)

### Related Documentation
- `V20_8_IMPLEMENTATION_SUMMARY.md` - V20.8 features
- `AERON_INTEGRATION_GUIDE.md` - Aeron publishing setup
- `BROKER_SYMBOL_MAPPING_GUIDE.md` - Multi-broker support
- `PROFIT_LOSS_PROTECTION.md` - Risk management features

### Need Help?
- Review log messages at EA startup
- Check for validation warnings
- Test in Strategy Tester before live
- Verify session times don't overlap
- Ensure `UseAPITradingHours = false` for dual sessions

---

## Version History

### V20.9 (February 12, 2026)
- ✅ Dual trading session support
- ✅ Optional kill time override
- ✅ Session overlap validation
- ✅ Enhanced kill switch logic
- ✅ Backward compatible with V20.8.3

### V20.8.3 (Previous)
- Fixed restart persistence issues
- Enhanced exception handling
- EA restart gap fix

### V20.8 (Previous)
- Kill switch functionality
- Enhanced error handling
- Profit/loss protection

---

## End of Release Summary
**Ready to deploy?** Test in Strategy Tester first! ✅
