# V20.8.3 Hotfix - Aeron Publisher Restart Fix

## Issue Description

**Problem:** EA fails intermittently during restart with error: "Failed to start Aeron publisher"

**Symptoms:**

- Random restart failures (not consistent)
- Works sometimes, fails other times
- More common after EA crashes or forced termination
- Error messages indicating MediaDriver or channel issues

## Root Causes

### 1. Missing State Tracking

- No global variables to track if publishers are already running
- Multiple restart attempts could try to start publishers twice
- DLL doesn't validate if publisher already exists

### 2. Resource Leak on Abnormal Shutdown

- If EA crashes, `OnDeinit()` is not called
- Publishers remain active in DLL memory
- Next restart attempt fails because resources are still locked

### 3. Race Condition During Cleanup

- `OnDeinit()` calls stop functions
- New `OnInit()` starts immediately after
- DLL may not have fully released resources yet
- Timing-dependent failure (intermittent)

### 4. No Cleanup Verification

- No checks if previous instance left orphaned publishers
- No forced cleanup before starting fresh
- Assumes clean slate at startup (incorrect assumption)

## Solution Implementation

### 1. Global State Tracking (Lines 179-182)

```mql5
// V20.8.3 - Aeron Publisher State Tracking (Restart Fix)
static bool         g_AeronIpcStarted = false;  // Track IPC publisher state
static bool         g_AeronUdpStarted = false;  // Track UDP publisher state
static datetime     g_LastPublisherCleanup = 0; // Track last cleanup time
```

**Purpose:**

- Track exact state of each publisher
- Prevent double-start attempts
- Record cleanup timestamps for debugging

### 2. Forced Cleanup Function (Lines 940-981)

```mql5
void CleanupAeronPublishersForce()
{
    // Unconditionally stop any orphaned publishers
    // Wait 200ms for DLL resource release
    // Reset all state flags
}
```

**Features:**

- Runs at start of `OnInit()` before anything else
- Unconditional cleanup (doesn't check state first)
- 200ms delay ensures DLL has time to release resources
- Prevents duplicate cleanup within 2 seconds
- Handles both IPC and UDP channels

### 3. Enhanced OnInit() - Startup Protection (Lines 1271-1292, 1306-1327)

**IPC Publisher Start:**

```mql5
// Check if already started
if(g_AeronIpcStarted)
{
    Print("WARNING: IPC publisher already marked as started - forcing cleanup");
    AeronBridge_StopPublisherIpc();
    Sleep(100); // Allow time for cleanup
    g_AeronIpcStarted = false;
}

// Start publisher
int resultIpc = AeronBridge_StartPublisherIpcW(...);

// Update state on success
if(resultIpc != 0)
{
    g_AeronIpcStarted = true;
}
```

**Benefits:**

- Double-check before starting
- Force cleanup if state mismatch detected
- Update state flags immediately on success/failure
- Better error messages with troubleshooting hints

### 4. Enhanced OnDeinit() - Cleanup Protection (Lines 1425-1459)

**Changes:**

```mql5
// Only cleanup if publisher is actually running (check state flag)
if(g_AeronIpcStarted)
{
    AeronBridge_StopPublisherIpc();
    g_AeronIpcStarted = false;
}

// Record cleanup timestamp
g_LastPublisherCleanup = TimeCurrent();
```

**Benefits:**

- Avoids unnecessary cleanup calls
- Records cleanup time for debugging
- Only stops publishers that were actually started
- Prevents double-cleanup errors

## Testing Recommendations

### Test Scenario 1: Normal Restart

1. Start EA normally
2. Stop EA using chart removal
3. Restart EA immediately
4. **Expected:** Clean startup, no errors

### Test Scenario 2: Rapid Restart

1. Start EA
2. Stop and restart 5 times quickly (within 10 seconds)
3. **Expected:** Emergency brake activates after 3rd restart (crash-loop protection)

### Test Scenario 3: Crash Recovery

1. Start EA
2. Force-terminate MT5 process (simulates crash)
3. Restart MT5 and EA
4. **Expected:** Force cleanup detects orphaned publishers, cleans up, starts fresh

### Test Scenario 4: Parameter Change

1. Start EA with IPC+UDP mode
2. Change to IPC_ONLY mode (parameter change triggers restart)
3. **Expected:** Clean shutdown of both, restart with only IPC

### Test Scenario 5: Long-Running Stability

1. Start EA
2. Run for 24 hours with multiple chart timeframe changes
3. **Expected:** No accumulated resource leaks, clean restarts after each change

## Monitoring & Diagnostics

### Startup Log Pattern (Normal)

```
=== FORCED AERON CLEANUP ===
Attempting to stop any orphaned IPC publishers...
Attempting to stop any orphaned UDP publishers...
Force cleanup complete - ready for fresh start
============================
Initializing Stochastic Algo V20.8.3
```

### Startup Log Pattern (Recovery from Orphaned Publishers)

```
=== FORCED AERON CLEANUP ===
Attempting to stop any orphaned IPC publishers...
IPC cleanup error (expected if not running): 0
Attempting to stop any orphaned UDP publishers...
UDP cleanup error (expected if not running): 0
Force cleanup complete - ready for fresh start
```

### Error Log Pattern (If Still Failing)

```
ERROR: Failed to start Aeron IPC publisher: [specific error]
Possible causes:
  - MediaDriver not running
  - Incorrect Aeron directory path
  - Invalid IPC channel format
  - Previous instance not fully cleaned up (retry in 5 seconds)
```

## Performance Impact

- **Startup delay:** +200ms (one-time cleanup wait)
- **Memory:** +24 bytes (3 static variables)
- **CPU:** Negligible (cleanup only at init/deinit)
- **Runtime:** Zero impact (no changes to OnTick)

## Compatibility

- **Backwards Compatible:** Yes
- **Configuration Required:** No (automatic)
- **DLL Changes Required:** No
- **Breaking Changes:** None

## Version History

- **V20.8.3** (Current) - Restart fix with state tracking
- **V20.8.2** - UTC timestamp fix
- **V20.8.1** - Crash prevention fixes
- **V20.8.0** - Multi-channel Aeron architecture

## Known Limitations

1. **MediaDriver Dependency:** If MediaDriver is not running, publishers will still fail (expected behavior)
2. **Cleanup Timeout:** 200ms may not be sufficient on very slow systems (increase if needed)
3. **State Persistence:** State flags reset on MT5 restart (by design)

## Future Enhancements

1. **DLL Enhancement:** Add `IsPublisherRunning()` query function for verification
2. **Exponential Backoff:** Implement retry with increasing delays if cleanup fails
3. **Health Check:** Add periodic publisher health check in OnTick
4. **Metrics:** Log startup/cleanup timing statistics

## Support

If restart failures persist after this fix:

1. Verify MediaDriver is running (`tasklist | findstr MediaDriver`)
2. Check Aeron directory permissions (should be readable/writable)
3. Review Windows Event Viewer for DLL errors
4. Increase cleanup delay to 500ms in `CleanupAeronPublishersForce()`
5. Enable DLL debugging: Add `Print()` statements in AeronBridge.cpp

## Contact

For issues or questions:

- Email: support@sanjeevas.com
- Documentation: See AERON_INTEGRATION_GUIDE.md
