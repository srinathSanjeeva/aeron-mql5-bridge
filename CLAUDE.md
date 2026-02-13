# CLAUDE.md — Aeron MQL5 Bridge

## Project Overview

**aeron-mql5-bridge** is a high-performance trading signal bridge connecting MetaTrader 5 (MT5) with external platforms (primarily NinjaTrader) via Aeron messaging. It enables ultra-low-latency binary signal publishing and subscription for algorithmic trading.

## Architecture

```
NinjaTrader / External → Aeron (IPC/UDP) → C++ DLL → MQL5 EA → MT5 Broker
MT5 Strategy → MQL5 Publisher → C++ DLL → Aeron (IPC/UDP) → Subscribers
```

Three layers:
1. **C++ DLL** (`AeronBridge.cpp/.h`) — Aeron C client wrapper, binary protocol encoding/decoding, symbol mapping
2. **MQL5 Library Layer** (`AeronBridge.mqh`, `AeronPublisher.mqh`, `BrokerMappings.mqh`) — DLL imports, signal encoding, broker symbol mapping
3. **Expert Advisors** (`AeronBridgeInt.mq5`, `Secret_Eye_V20_*.mq5`) — Trading strategies and signal subscriber

## Key Files

| File | Purpose |
|------|---------|
| `AeronBridge.cpp` | C++ DLL — Aeron pub/sub, symbol mapping, tick conversion |
| `AeronBridge.h` | DLL API declarations (exported functions) |
| `AeronBridge.mqh` | MQL5 DLL import declarations |
| `AeronPublisher.mqh` | Binary signal encoding (104-byte protocol) |
| `BrokerMappings.mqh` | Multi-broker symbol mapping profiles |
| `AeronBridgeInt.mq5` | Signal subscriber EA (receives & executes trades) |
| `MQL5/Secret_Eye_V20_9_Complete.mq5` | Full trading strategy (latest version, 4200+ lines) |
| `MQL5/Secret_Eye_V20_9_Forex.mq5` | Forex edition with signal reversal |
| `broker_a_mappings.csv` | Audacity Capital symbol mappings |
| `broker_b_mappings.csv` | Alternate broker symbol mappings |

## Binary Protocol (104 bytes, little-endian)

```
Offset  Size  Field
0       4     Magic (0xA330BEEF)
4       2     Version (1)
6       2     Action (1-9)
8       8     Timestamp (nanoseconds)
16      4     Long SL (ticks)
20      4     Short SL (ticks)
24      4     Profit Target (ticks)
28      4     Quantity
32      4     Confidence (float32)
36      16    Symbol (ASCII, null-padded)
52      32    Instrument (ASCII, null-padded)
84      16    Source (ASCII, null-padded)
100     4     Padding
```

Action codes: 1=LongEntry(SL), 2=LongEntry(SL+TP), 3=ShortEntry(SL), 4=ShortEntry(SL+TP), 5=LongExit, 6=ShortExit, 7=LongSL, 8=ShortSL, 9=ProfitTarget

## Build System

- **IDE**: Visual Studio 2022, x64 Release, C++17, toolset v143
- **Aeron dependency**: Built from source at `C:\projects\quant\aeron-primer-c-cpp-stable-version\`
  - Include: `aeron-client\src\main\c`
  - Lib: `cppbuild\Release\lib\Release` → `aeron_client.lib`
- **Link deps**: `aeron_client.lib`, `Ws2_32.lib`, `Advapi32.lib`
- **Runtime**: `AeronBridge.dll` + `aeron_client_shared.dll` → deploy to MT5 `MQL5\Libraries\`
- **Build guide**: See `BUILD_WINDOWS_VS_AERON_BRIDGE.md`

### Build steps
1. Build Aeron C client from source (CMake)
2. Open `AeronBridge.sln` in Visual Studio
3. Build Release x64
4. Copy output DLLs to each MT5 terminal's `MQL5\Libraries\`

## Broker-Specific Deployments

Compiled DLLs are deployed per broker in subdirectories:
- `Audacity/` — Audacity Capital prop firm
- `Darwinex/` — Darwinex broker
- `forex.com/` — Forex.com broker

Each contains copies of `AeronBridge.dll` + `aeron_client_shared.dll`.

## Multi-Broker Symbol Mapping

Different brokers use different symbol names. The DLL maps futures symbols to broker-specific MT5 symbols at runtime:

```
ES → SPX500 (Audacity) / US500 (other)
NQ → TECH100 / NAS100
YM → DJ30 / WS30 / US30
```

Configured via: broker profiles in `BrokerMappings.mqh`, CSV files, or `AeronBridge_RegisterInstrumentMapW()`.

## Strategy Versions (Secret Eye)

Active development line — each version adds features:
- **V20.5**: Aeron binary publisher
- **V20.6**: Full integration
- **V20.7**: Futures tick conversion + exception handling
- **V20.8**: Multi-channel publishing (IPC + UDP simultaneously)
- **V20.9**: Dual session trading + signal reversal (current)

## Conventions

- **Language**: C++ (DLL) and MQL5 (EAs/libraries). MQL5 is similar to C++ but runs in MT5.
- **Encoding**: MQL5 uses UTF-16 (wide strings). The DLL converts to UTF-8 internally. Functions with `W` suffix accept wide strings.
- **Commit style**: `feat: <description>` for features, `fix: <description>` for fixes
- **No test framework**: Testing is manual via MT5 Strategy Tester and live trading. Validate by compiling MQ5 in MetaEditor and DLL in Visual Studio.
- **Documentation**: Extensive markdown docs in repo root. Version-specific docs use `V20_X_` prefix.

## Important Patterns

- **DLL functions** exported with `extern "C" __declspec(dllexport)` for MQL5 compatibility
- **Signal queue** in DLL: max 100 signals, FIFO, poll-based consumption
- **Aeron Media Driver** must be running externally (standalone mode, default dir `C:\aeron\standalone`)
- **Safety features**: dry-run mode, kill switch, daily loss/profit limits, trade rate limiting, cooldown per symbol, max positions per symbol
- **Position recovery**: EAs re-attach to existing positions after restart
- **Crash prevention**: Exception handling wraps all critical operations (V20.7+)

## When Modifying Code

- The binary protocol is a fixed 104-byte struct. Changes require updating both `AeronBridge.cpp` and `AeronPublisher.mqh` in sync.
- Symbol mapping changes need updates in both `AeronBridge.cpp` (default mappings) and `BrokerMappings.mqh` (MQL5 profiles).
- MQL5 files in both root and `MQL5/` directory — the `MQL5/` folder contains the latest strategy versions.
- DLL API changes require updating `AeronBridge.h`, `AeronBridge.cpp`, and `AeronBridge.mqh` (MQL5 imports) together.
- The `.mq5` files use MQL5 syntax (MetaQuotes Language 5). It is very similar to C++ but has platform-specific types (`string`, `datetime`, `color`) and functions (`OrderSend`, `SymbolInfoDouble`, etc.).
