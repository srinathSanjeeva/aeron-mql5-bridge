# Multi-Broker Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Signal Publisher (NinjaTrader)                   │
│                                                                     │
│  Publishes: "YM MAR 26(YM)" signal with action, SL, TP, etc.       │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                │ Aeron UDP Multicast
                                │ (aeron:udp?endpoint=...)
                                │
                ┌───────────────┴───────────────┐
                │                               │
                ▼                               ▼
┌───────────────────────────────┐   ┌───────────────────────────────┐
│   MT5 Terminal #1 (Broker A)  │   │   MT5 Terminal #2 (Broker B)  │
│                               │   │                               │
│  ┌─────────────────────────┐  │   │  ┌─────────────────────────┐  │
│  │ AeronBridge.dll (same)  │  │   │  │ AeronBridge.dll (same)  │  │
│  └──────────┬──────────────┘  │   │  └──────────┬──────────────┘  │
│             │                 │   │             │                 │
│  ┌──────────▼──────────────┐  │   │  ┌──────────▼──────────────┐  │
│  │ Runtime Mapping Table   │  │   │  │ Runtime Mapping Table   │  │
│  ├─────────────────────────┤  │   │  ├─────────────────────────┤  │
│  │ "YM" → "DJ30"           │  │   │  │ "YM" → "US30"           │  │
│  │ "ES" → "SPX500"         │  │   │  │ "ES" → "US500"          │  │
│  │ "NQ" → "NAS100"         │  │   │  │ "NQ" → "USTEC"          │  │
│  └─────────────────────────┘  │   │  └─────────────────────────┘  │
│             │                 │   │             │                 │
│  Signal:    │                 │   │  Signal:    │                 │
│  "YM" → "DJ30"                │   │  "YM" → "US30"                │
│             │                 │   │             │                 │
│  ┌──────────▼──────────────┐  │   │  ┌──────────▼──────────────┐  │
│  │   EA (AeronBridgeInt)   │  │   │  │   EA (AeronBridgeInt)   │  │
│  │   Trades on "DJ30"      │  │   │  │   Trades on "US30"      │  │
│  └─────────────────────────┘  │   │  └─────────────────────────┘  │
└───────────────────────────────┘   └───────────────────────────────┘
```

## Configuration Methods

### Method 1: Hardcoded in EA

```mql5
int OnInit()
{
   // Broker A setup
   AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1);
   AeronBridge_StartW(...);
}
```

### Method 2: Broker Profile Selection

```mql5
input ENUM_BROKER_PROFILE BrokerProfile = BROKER_PROFILE_A;

int OnInit()
{
   RegisterBrokerMappings(BrokerProfile);
   AeronBridge_StartW(...);
}
```

### Method 3: CSV Configuration File

```mql5
input string CustomMappingFile = "broker_a_mappings.csv";

int OnInit()
{
   LoadMappingsFromCSV(CustomMappingFile);
   AeronBridge_StartW(...);
}
```

### Method 4: Auto-Detection

```mql5
input bool AutoDetectBroker = true;

int OnInit()
{
   ENUM_BROKER_PROFILE profile = DetectBrokerProfile();
   RegisterBrokerMappings(profile);
   AeronBridge_StartW(...);
}
```

## Key Points

✅ **Single DLL** serves all brokers
✅ **Per-terminal configuration** - each MT5 instance has independent mappings
✅ **No recompilation needed** - change mappings at runtime
✅ **Multiple methods** - choose what works best for your deployment
✅ **Signal transformation** happens inside the DLL before reaching the EA

## Data Flow Example

```
Publisher Signal:
┌──────────────────────────────────────────────────┐
│ Instrument: "YM MAR 26(YM)"                      │
│ Action: 1 (Long)                                 │
│ SL: 10 ticks                                     │
│ PT: 20 ticks                                     │
└──────────────────────────────────────────────────┘
                    │
                    ▼
DLL Processing (Broker A):
┌──────────────────────────────────────────────────┐
│ 1. Extract prefix: "YM"                          │
│ 2. Lookup mapping: "YM" → "DJ30"                 │
│ 3. Convert ticks: 10 ticks * 1.0 / 0.1 = 100pts │
│ 4. Output CSV with "DJ30"                        │
└──────────────────────────────────────────────────┘
                    │
                    ▼
EA Receives:
┌──────────────────────────────────────────────────┐
│ mt5_symbol: "DJ30"                               │
│ action: 1                                        │
│ sl_points: 100                                   │
│ pt_points: 200                                   │
└──────────────────────────────────────────────────┘
                    │
                    ▼
                Places order on "DJ30"
```

## Deployment Scenarios

### Scenario 1: Single Broker, Multiple Accounts

- Same symbol mappings for all terminals
- Copy same configuration to all accounts

### Scenario 2: Multiple Brokers

- Different symbol mappings per broker
- Use broker profiles or CSV files
- Each terminal gets appropriate configuration

### Scenario 3: Mixed Environment

- Some accounts use Profile A
- Some accounts use Profile B
- Some accounts use custom CSV
- All subscribe to same Aeron stream

## Benefits

1. **Centralized Signal Source** - One publisher serves all brokers
2. **Broker Independence** - No publisher changes needed for new brokers
3. **Easy Deployment** - Just update configuration file or EA input
4. **Type Safety** - Tick/point conversion handled automatically
5. **Maintainability** - Symbol mappings managed in one place per terminal
