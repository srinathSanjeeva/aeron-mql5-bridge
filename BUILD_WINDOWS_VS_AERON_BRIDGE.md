# Building `AeronBridge.dll` on Windows (Visual Studio)

This document describes how to **rebuild the Aeron C-based MT5 bridge DLL** (`AeronBridge.dll`) on a **new Windows machine / new Visual Studio project**, using the **Aeron C client**.

The resulting DLL is consumed by **MetaTrader 5 (MT5)** as part of an Aeron-based auto-trading pipeline.

---

## 1. Prerequisites

### Operating System

* Windows 10 / 11 (x64)

### Tools

* **Visual Studio 2022**

  * Workload: **Desktop development with C++**
* **Git**
* **CMake** (already bundled with VS is fine)

---

## 2. Directory Layout (Recommended)

```
C:\projects\
│
├── aeron-primer-c-cpp-stable-version\
│   └── cppbuild\Release\        <-- Aeron build output
│       ├── lib\Release\
│       │   └── aeron_client.lib
│       └── binaries\Release\
│           └── aeron_client_shared.dll
│
└── AeronBridge\
    ├── AeronBridge.sln
    ├── AeronBridge\
    │   ├── AeronBridge.cpp
    │   ├── AeronBridge.h
    │   └── x64\Release\          <-- build output
```

---

## 3. Build Aeron C Client (One-Time)

Clone Aeron:

```bash
git clone https://github.com/real-logic/aeron.git
cd aeron
```

Build with CMake:

```bash
mkdir cppbuild
cd cppbuild
cmake -A x64 ..
cmake --build . --config Release
```

### Verify output exists

You **must** have:

```
cppbuild\Release\lib\Release\aeron_client.lib
cppbuild\Release\binaries\Release\aeron_client_shared.dll
```

If these do not exist, **stop here** — the bridge cannot link without them.

---

## 4. Create Visual Studio Project

1. Open **Visual Studio**
2. **Create new project**
3. Choose:

   * **C++ → Dynamic-Link Library (DLL)**
4. Name:

   * `AeronBridge`
5. Platform:

   * **x64**
6. Configuration:

   * **Release**

---

## 5. Project Configuration (CRITICAL)

Open **Project → Properties**
Set **Configuration = Release**, **Platform = x64**

---

### 5.1 General

```
Configuration Type: Dynamic Library (.dll)
C++ Language Standard: ISO C++17
```

---

### 5.2 C/C++ → General

#### Additional Include Directories

Add the Aeron C headers directory:

```
C:\projects\aeron-primer-c-cpp-stable-version\aeron-client\src\main\c
```

(Adjust path if your Aeron clone is elsewhere.)

---

### 5.3 C/C++ → Preprocessor

Add:

```
WIN32
_WINDOWS
AERON_DLL_EXPORT
```

---

### 5.4 Linker → General

#### Additional Library Directories

Add:

```
C:\projects\aeron-primer-c-cpp-stable-version\cppbuild\Release\lib\Release
```

---

### 5.5 Linker → Input

#### Additional Dependencies

Add **exactly**:

```
aeron_client.lib
Ws2_32.lib
Advapi32.lib
```

> `Ws2_32.lib` is required for sockets
> `Advapi32.lib` is required by Aeron on Windows

---

## 6. Source Files

### Required Includes (C API only)

```cpp
#include <aeron_client.h>
#include <aeronc.h>
#include <aeron_context.h>
#include <aeron_subscription.h>
```

❌ **Do NOT include**

* `aeron/Aeron.h`
* Any C++ Aeron headers

This project **uses only the C API**.

---

## 7. Export Rules (ABI Safety)

Every exported function **must**:

* Use `extern "C"`
* Use `__declspec(dllexport)`
* Use **plain C types** (`int`, `char*`, `wchar_t*`)

Example:

```cpp
extern "C" __declspec(dllexport)
int AeronBridge_StartW(
    const char* aeronDir,
    const char* channel,
    int streamId,
    int timeoutMs
);
```

This is **mandatory** for MT5 compatibility.

---

## 8. Runtime Dependencies (VERY IMPORTANT)

After building, copy these **next to `AeronBridge.dll`**:

```
aeron_client_shared.dll
```

Final MT5 layout:

```
MQL5\Libraries\
├── AeronBridge.dll
└── aeron_client_shared.dll
```

If this DLL is missing:

* MT5 will load the EA
* But Aeron will silently fail

---

## 9. Build Output Verification

After a successful build, you should see:

```
AeronBridge\x64\Release\
├── AeronBridge.dll
├── AeronBridge.pdb (optional)
├── aeron_client_shared.dll
```

---

## 10. MT5 Compatibility Checklist

Before running in MetaTrader:

* [ ] Built **x64 Release**
* [ ] `AeronBridge.mqh` signatures match `AeronBridge.h`
* [ ] DLL copied into `MQL5\Libraries`
* [ ] `aeron_client_shared.dll` present
* [ ] MT5 **fully restarted**
* [ ] EA recompiled

---

## 11. Common Failure Modes (and Fixes)

### ❌ `Invalid Aeron channel: 'a'`

➡ ABI mismatch
✔ Fix `.mqh` to exactly match `.h`

---

### ❌ `aeron_start failed: CnC file not created`

➡ Media Driver not running or wrong `aeronDir`

✔ Ensure:

```
C:\aeron\standalone\cnc.dat
```

---

### ❌ MT5 loads EA but no messages arrive

➡ Missing `aeron_client_shared.dll`

✔ Copy DLL next to `AeronBridge.dll`

---

## 12. Final Notes

* This bridge is **transport + conversion only**
* Trading logic belongs in the MT5 EA
* Do not add JSON parsing or STL containers to the ABI surface
* Keep the DLL **boring and deterministic**

---

## 13. Recommended Commit Files

Commit these to Git:

```
BUILD_WINDOWS_VS_AERON_BRIDGE.md
AeronBridge.cpp
AeronBridge.h
```

Do **not** commit:

* `.vs/`
* `x64/`
* `.obj / .pdb`

---

### ✅ Result

Following this guide, you can rebuild `AeronBridge.dll` on **any Windows machine** and plug it directly into MT5 with **zero trial-and-error**.

