# Secret_Eye Strategy - Version 20.8 Release Notes

## Version Information

- **Version**: 20.8 (20.80)
- **Release Date**: February 6, 2026
- **Previous Version**: 20.7
- **File**: Secret_Eye_V20_8_Ver.mq5

---

## 🎯 Release Summary

Version 20.8 represents an **enhanced Aeron publishing architecture** with the introduction of flexible multi-channel support. This release replaces the simple boolean toggle with a comprehensive publish mode system that allows simultaneous IPC and UDP publishing, enabling greater flexibility in signal distribution strategies.

---

## ✨ New Features

### 1. Aeron Multi-Channel Publishing Architecture

**Core Enhancement:**

- Replaced `EnableAeronPublishing` (boolean) with `AeronPublishMode` (enum-based configuration)
- Introduced `ENUM_AERON_PUBLISH_MODE` with four distinct operating modes
- Separate, independent channel configuration for IPC and UDP transports
- Simultaneous dual-channel publishing capability

**Publish Modes:**

```cpp
AERON_PUBLISH_NONE = 0         // No publishing (disabled)
AERON_PUBLISH_IPC_ONLY = 1     // IPC-only mode (shared memory)
AERON_PUBLISH_UDP_ONLY = 2     // UDP-only mode (network)
AERON_PUBLISH_IPC_AND_UDP = 3  // Dual-channel mode (both IPC + UDP)
```

**New Input Parameters:**

```cpp
// V20.8 - Enhanced Aeron Publishing Configuration
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
input string AeronPublishChannelIpc = "aeron:ipc";
input string AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
```

**Replaced V20.7 Parameters:**

```cpp
// V20.7 - Deprecated in V20.8
input bool   EnableAeronPublishing = true;
input string AeronPublishChannel = "aeron:ipc";
```

### 2. Independent Channel Management

**Dual Publisher Support:**

- Independent initialization for IPC and UDP publishers
- Separate error handling and reporting per channel
- Independent success/failure status tracking
- Graceful degradation (one channel can fail without affecting the other)

**Channel-Specific Functions:**

- `AeronBridge_StartPublisherIpcW()` - IPC publisher initialization
- `AeronBridge_StartPublisherUdpW()` - UDP publisher initialization
- `AeronBridge_StopPublisherIpc()` - IPC publisher cleanup
- `AeronBridge_StopPublisherUdp()` - UDP publisher cleanup

### 3. Enhanced Logging and Diagnostics

**Initialization Logging:**

```
=== AERON BINARY PUBLISHING CONFIGURATION ===
Aeron Publishing Mode: AERON_PUBLISH_IPC_AND_UDP
Starting IPC Publisher...
IPC Channel: aeron:ipc
✅ Aeron IPC publisher started successfully
Starting UDP Publisher...
UDP Channel: aeron:udp?endpoint=192.168.2.15:40123
✅ Aeron UDP publisher started successfully
```

**Status Indicators:**

- Clear success (✅) and warning (⚠️) indicators
- Per-channel status reporting
- Combined summary showing active channels

---

## 🔄 Breaking Changes

### Configuration Migration Required

**V20.7 Configuration:**

```cpp
input bool   EnableAeronPublishing = true;
input string AeronPublishChannel = "aeron:ipc";
```

**V20.8 Migration:**

```cpp
// For IPC-only (equivalent to V20.7 with aeron:ipc)
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_ONLY;
input string AeronPublishChannelIpc = "aeron:ipc";

// For UDP-only (equivalent to V20.7 with aeron:udp)
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_UDP_ONLY;
input string AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";

// For dual-channel (new capability in V20.8)
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
input string AeronPublishChannelIpc = "aeron:ipc";
input string AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
```

---

## 📊 Architecture Improvements

### Before (V20.7)

```
┌─────────────────────┐
│  Boolean Toggle     │
│  (On/Off Only)      │
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│  Single Channel     │
│  (IPC or UDP)       │
└─────────────────────┘
```

### After (V20.8)

```
┌─────────────────────────────┐
│   Publish Mode Enum         │
│   (4 modes)                 │
└──────┬──────────────┬───────┘
       │              │
┌──────▼──────┐  ┌───▼─────────┐
│ IPC Channel │  │ UDP Channel │
│ (aeron:ipc) │  │ (network)   │
└─────────────┘  └─────────────┘
```

---

## 🚀 Use Cases

### 1. Local Development (IPC-Only)

```cpp
AeronPublishMode = AERON_PUBLISH_IPC_ONLY;
AeronPublishChannelIpc = "aeron:ipc";
```

- **Benefit**: Lowest latency via shared memory
- **Use Case**: MT5 and consumer on same machine

### 2. Production Network (UDP-Only)

```cpp
AeronPublishMode = AERON_PUBLISH_UDP_ONLY;
AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
```

- **Benefit**: Network distribution to remote consumers
- **Use Case**: MT5 on trading machine, consumers on different hosts

### 3. Hybrid Architecture (IPC + UDP)

```cpp
AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
AeronPublishChannelIpc = "aeron:ipc";
AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
```

- **Benefit**: Local AND remote consumers simultaneously
- **Use Case**: Local monitoring + distributed execution systems

### 4. Disabled (Testing/Debugging)

```cpp
AeronPublishMode = AERON_PUBLISH_NONE;
```

- **Benefit**: No Aeron overhead during testing
- **Use Case**: Strategy testing without signal distribution

---

## 📝 Implementation Details

### OnInit() Changes

**V20.8 Dual-Publisher Initialization:**

```cpp
bool ipcStarted = false;
bool udpStarted = false;

// Start IPC publisher if needed
if(AeronPublishMode == AERON_PUBLISH_IPC_ONLY ||
   AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
{
    int resultIpc = AeronBridge_StartPublisherIpcW(...);
    if(resultIpc == 0)
    {
        // Error handling
    }
    else
    {
        ipcStarted = true;
        Print("✅ Aeron IPC publisher started successfully");
    }
}

// Start UDP publisher if needed
if(AeronPublishMode == AERON_PUBLISH_UDP_ONLY ||
   AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
{
    int resultUdp = AeronBridge_StartPublisherUdpW(...);
    if(resultUdp == 0)
    {
        // Error handling
    }
    else
    {
        udpStarted = true;
        Print("✅ Aeron UDP publisher started successfully");
    }
}
```

### OnDeinit() Changes

**V20.8 Dual-Publisher Cleanup:**

```cpp
if(AeronPublishMode == AERON_PUBLISH_IPC_ONLY ||
   AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
{
    AeronBridge_StopPublisherIpc();
    Print("✅ Aeron IPC publisher stopped");
}

if(AeronPublishMode == AERON_PUBLISH_UDP_ONLY ||
   AeronPublishMode == AERON_PUBLISH_IPC_AND_UDP)
{
    AeronBridge_StopPublisherUdp();
    Print("✅ Aeron UDP publisher stopped");
}
```

### Signal Publishing Logic

**Unchanged - Mode Transparent:**

```cpp
// Publishing logic remains the same
if(AeronPublishMode != AERON_PUBLISH_NONE)
{
    PublishAeronSignal(..., AeronSourceTag, AeronPublishMode);
}
```

The `PublishAeronSignal()` function now internally handles multi-channel publishing based on the mode.

---

## 🔍 Error Handling Improvements

### Per-Channel Error Reporting

**V20.8 provides detailed error context per channel:**

```
ERROR: Failed to start Aeron IPC publisher: MediaDriver not running
Possible causes:
  - MediaDriver not running
  - Incorrect Aeron directory path
  - Invalid IPC channel format

ERROR: Failed to start Aeron UDP publisher: Invalid endpoint
Possible causes:
  - MediaDriver not running
  - Incorrect Aeron directory path
  - Invalid UDP channel format or endpoint
  - Firewall blocking UDP port
```

---

## 📈 Performance Characteristics

### Latency Profiles

| Mode         | Typical Latency | Use Case                             |
| ------------ | --------------- | ------------------------------------ |
| **IPC-Only** | 50-200 μs       | Local consumers, lowest latency      |
| **UDP-Only** | 200-800 μs      | Network consumers, LAN distribution  |
| **IPC+UDP**  | Max of both     | Hybrid environments, slight overhead |
| **None**     | N/A             | No publishing, zero overhead         |

### Resource Utilization

- **IPC-Only**: ~1-2 MB shared memory
- **UDP-Only**: Network bandwidth dependent (~10-50 KB/s typical)
- **IPC+UDP**: Combination of both (minimal CPU overhead)

---

## 🛠️ Compatibility

### AeronPublisher.mqh Integration

The `ENUM_AERON_PUBLISH_MODE` enum is defined in `AeronPublisher.mqh` (lines 9-15):

```cpp
enum ENUM_AERON_PUBLISH_MODE
{
   AERON_PUBLISH_NONE = 0,
   AERON_PUBLISH_IPC_ONLY = 1,
   AERON_PUBLISH_UDP_ONLY = 2,
   AERON_PUBLISH_IPC_AND_UDP = 3
};
```

**Requirements:**

- AeronPublisher.mqh (latest version with enum support)
- AeronBridge.mqh (no changes required)
- AeronBridge.dll (supports both IPC and UDP publishers)

---

## 📚 Related Documentation

- **AeronPublisher.mqh**: Defines publishing modes and binary protocol
- **AeronBridge.mqh**: C++ bridge function declarations
- **AERON_INTEGRATION_GUIDE.md**: General Aeron setup
- **CONFIG_EXAMPLES.md**: Configuration examples

---

## 🔄 Retained Features from V20.7

All V20.7 features remain fully functional:

- ✅ Futures symbol mapping and tick conversion
- ✅ Exception handling and crash prevention
- ✅ Binary protocol (104-byte frame)
- ✅ Signal types (LongEntry1/2, ShortEntry1/2, StopLoss, ProfitTarget)
- ✅ JSON publishing (runs in parallel with Aeron)
- ✅ All V20.0-V20.6 features (API trading hours, FOK orders, etc.)

---

## 🎓 Migration Guide

### Step 1: Update Input Parameters

Replace:

```cpp
input bool   EnableAeronPublishing = true;
input string AeronPublishChannel = "aeron:ipc";
```

With:

```cpp
input ENUM_AERON_PUBLISH_MODE AeronPublishMode = AERON_PUBLISH_IPC_AND_UDP;
input string AeronPublishChannelIpc = "aeron:ipc";
input string AeronPublishChannelUdp = "aeron:udp?endpoint=YOUR_IP:40123";
```

### Step 2: Choose Your Mode

- **Same machine**: `AERON_PUBLISH_IPC_ONLY`
- **Network only**: `AERON_PUBLISH_UDP_ONLY`
- **Both simultaneously**: `AERON_PUBLISH_IPC_AND_UDP`
- **Disable**: `AERON_PUBLISH_NONE`

### Step 3: Configure Channels

**IPC Channel** (always the same):

```cpp
AeronPublishChannelIpc = "aeron:ipc";
```

**UDP Channel** (customize IP:Port):

```cpp
AeronPublishChannelUdp = "aeron:udp?endpoint=192.168.2.15:40123";
```

### Step 4: Test and Verify

1. Check initialization logs for success indicators
2. Verify consumers can connect to configured channels
3. Confirm signal reception on all active channels

---

## ⚠️ Known Limitations

1. **Channel Configuration**: IPC channel must always be `"aeron:ipc"` (Aeron standard)
2. **UDP Endpoint**: Must specify valid IP:Port combination
3. **Firewall**: UDP mode requires firewall rules for the specified port
4. **MediaDriver**: Must be running before EA initialization

---

## 🐛 Bug Fixes

None - this is an enhancement release building on V20.7's stable foundation.

---

## 📞 Support

For issues or questions regarding V20.8:

- Review error messages in the Experts log
- Verify MediaDriver is running
- Check channel configuration syntax
- Ensure firewall allows UDP port (if using UDP mode)

---

## 🏆 Version 20.8 Benefits Summary

| Aspect              | V20.7             | V20.8                      | Improvement                 |
| ------------------- | ----------------- | -------------------------- | --------------------------- |
| **Configuration**   | Boolean toggle    | Enum-based modes           | ✅ More flexible            |
| **Channel Support** | Single channel    | Dual independent channels  | ✅ IPC + UDP simultaneously |
| **Error Reporting** | Single error path | Per-channel diagnostics    | ✅ Better debugging         |
| **Scalability**     | Limited           | Multiple deployment models | ✅ Local + Network          |
| **Backward Compat** | N/A               | Migration required         | ⚠️ Breaking change          |
| **Performance**     | Baseline          | Negligible overhead        | ✅ Maintained               |

---

## 📅 Release History

- **V20.8** (Feb 6, 2026): Multi-channel Aeron publishing architecture
- **V20.7** (Jan 30, 2026): Futures tick conversion + exception handling
- **V20.6** (Jan 25, 2026): Aeron binary publisher integration
- **V20.5** (Jan 20, 2026): Aeron initial implementation
- **V20.4** (Jan 15, 2026): JSON trade publisher

---

**End of V20.8 Release Notes**
