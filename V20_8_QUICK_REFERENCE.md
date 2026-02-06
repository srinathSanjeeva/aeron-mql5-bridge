# Version 20.8 Quick Reference

## What Changed from V20.7 → V20.8?

### Main Enhancement: Multi-Channel Aeron Publishing

**Before (V20.7):**

- Single boolean toggle: `EnableAeronPublishing = true/false`
- Single channel: `AeronPublishChannel = "aeron:ipc"` OR `"aeron:udp..."`
- Either IPC or UDP, but not both

**After (V20.8):**

- Enum-based modes: `AeronPublishMode` with 4 options
- Separate channels: `AeronPublishChannelIpc` AND `AeronPublishChannelUdp`
- Support for simultaneous IPC + UDP publishing

---

## New Configuration Parameters

### Publish Mode (replaces EnableAeronPublishing)

```cpp
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
```

**Options:**

- `AERON_PUBLISH_NONE` → Disabled (no publishing)
- `AERON_PUBLISH_IPC_ONLY` → IPC only (local shared memory)
- `AERON_PUBLISH_UDP_ONLY` → UDP only (network)
- `AERON_PUBLISH_IPC_AND_UDP` → Both simultaneously (recommended)

### Channel Configuration

```cpp
input string AeronPublishChannelIpc = "aeron:ipc";
input string AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
```

---

## Quick Migration

### If you had IPC in V20.7:

```cpp
// V20.7
EnableAeronPublishing = true;
AeronPublishChannel = "aeron:ipc";

// V20.8
AeronPublishMode = AERON_PUBLISH_IPC_ONLY;
AeronPublishChannelIpc = "aeron:ipc";
```

### If you had UDP in V20.7:

```cpp
// V20.7
EnableAeronPublishing = true;
AeronPublishChannel = "aeron:udp?endpoint=192.168.2.15:40123";

// V20.8
AeronPublishMode = AERON_PUBLISH_UDP_ONLY;
AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
```

### NEW in V20.8 - Dual Channel:

```cpp
// Publish to BOTH IPC and UDP simultaneously
AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
AeronPublishChannelIpc = "aeron:ipc";
AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
```

---

## Use Cases

| Scenario                            | Mode          | Why                            |
| ----------------------------------- | ------------- | ------------------------------ |
| Local development/testing           | `IPC_ONLY`    | Lowest latency, simplest setup |
| Production on different machines    | `UDP_ONLY`    | Network distribution           |
| Local monitoring + remote execution | `IPC_AND_UDP` | Best of both worlds            |
| Strategy testing without signals    | `NONE`        | Disable overhead               |

---

## Log Output Changes

### V20.8 shows per-channel status:

```
=== AERON BINARY PUBLISHING CONFIGURATION ===
Aeron Publishing Mode: AERON_PUBLISH_IPC_AND_UDP
Starting IPC Publisher...
IPC Channel: aeron:ipc
✅ Aeron IPC publisher started successfully
Starting UDP Publisher...
UDP Channel: aeron:udp?endpoint=192.168.2.15:40123
✅ Aeron UDP publisher started successfully
Ready to broadcast binary trading signals via Aeron
```

---

## Breaking Changes

⚠️ **V20.7 EA settings files will NOT work with V20.8**

You must reconfigure:

1. Remove `EnableAeronPublishing` setting
2. Remove `AeronPublishChannel` setting
3. Add `AeronPublishMode` setting
4. Add `AeronPublishChannelIpc` setting (if using IPC)
5. Add `AeronPublishChannelUdp` setting (if using UDP)

---

## Benefits Summary

✅ **Flexibility**: Choose IPC, UDP, or both
✅ **Redundancy**: Dual channels for critical systems
✅ **Clarity**: Explicit mode selection vs. ambiguous boolean
✅ **Error Handling**: Per-channel diagnostics
✅ **Performance**: No performance degradation vs. V20.7

---

## Files Modified

- `Secret_Eye_V20_8_Ver.mq5` - Main EA file
- `CHANGELOG_V20_8.md` - Full release notes (this summary)
- `AeronPublisher.mqh` - Added `ENUM_AERON_PUBLISH_MODE` enum

---

## Full Documentation

See [CHANGELOG_V20_8.md](CHANGELOG_V20_8.md) for complete details including:

- Architecture diagrams
- Implementation details
- Error handling improvements
- Performance characteristics
- Complete migration guide

---

**Version 20.8** - February 6, 2026 - Multi-Channel Aeron Publishing
