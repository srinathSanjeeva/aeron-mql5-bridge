# Profit/Loss Protection System

## Overview

The profit/loss protection system has been implemented in `AeronBridgeInt.mq5` to automatically monitor account balance and take protective actions when daily limits are reached.

## Features

### 1. Daily Loss Protection

- **Parameter**: `MAX_DAILY_LOSS_PERCENTAGE` (default: 2.5%)
- **Behavior**:
  - Tracks starting balance at the beginning of each trading day
  - Monitors current balance against starting balance
  - When loss exceeds the configured percentage:
    - Closes all open positions immediately
    - Stops accepting new trading signals for the rest of the day
    - Logs the event with loss amount and percentage

### 2. Daily Profit Protection

- **Parameter**: `EnableProfitProtection` (default: true)
- **Behavior**:
  - Tracks the maximum balance achieved during the day
  - Activates protection when profit exceeds `MAX_DAILY_LOSS_PERCENTAGE`
  - Once activated, monitors for drawdown from the peak balance
  - When drawdown exceeds `MAX_DAILY_LOSS_PERCENTAGE`:
    - Closes all open positions immediately
    - Stops accepting new trading signals for the rest of the day
    - Logs the event with drawdown amount and percentage

## Configuration

### Input Parameters

```mql5
input group             "Profit/Loss Protection"
input double MAX_DAILY_LOSS_PERCENTAGE = 2.5;    // Daily loss percentage limit
input bool   EnableProfitProtection    = true;   // Enable automatic profit protection
```

### Examples

**Example 1: Loss Protection**

- Starting balance: $10,000
- MAX_DAILY_LOSS_PERCENTAGE: 2.5%
- Loss limit: $250
- If balance drops to $9,750 or below, all positions close and trading stops

**Example 2: Profit Protection**

- Starting balance: $10,000
- MAX_DAILY_LOSS_PERCENTAGE: 2.5%
- Balance reaches $10,500 (+5% profit) → Protection activates
- Monitors for 2.5% drawdown from $10,500 = $262.50
- If balance drops to $10,237.50, all positions close and trading stops

## Implementation Details

### Global Variables

```mql5
static double todayStartingBalance = 0;              // Balance at start of day
bool          stopTradingForDay = false;             // Loss limit flag
static double dailyMaxProfitBalance = 0;             // Peak balance today
static bool   profitProtectionActive = false;        // Profit protection status
static bool   stopTradingForProfitProtection = false; // Profit protection flag
```

### Key Functions

#### `CheckDailyLossLimit()`

- Called every timer tick
- Detects new trading day and resets starting balance
- Calculates loss percentage
- Triggers protection when limit exceeded

#### `CheckDailyProfitProtection()`

- Called every timer tick
- Detects new trading day and resets tracking variables
- Tracks peak balance
- Activates protection when profit exceeds threshold
- Monitors drawdown from peak

#### `CloseAllPositions()`

- Iterates through all open positions
- Closes each position individually
- Respects `DryRun` mode (logs without closing)
- Logs success/failure for each closure

### Integration Points

1. **OnTimer()**: Protection checks run at the start of each timer cycle
2. **ExecuteSignal()**: Checks protection flags before processing any signal
3. **Daily Reset**: Automatic detection of new trading day resets all counters

## Logging

The system provides detailed logging for monitoring:

```
[PROFIT_PROTECTION] New day detected. Starting balance: 10000.00
[PROFIT_PROTECTION] Profit protection activated at 5.00% profit (500.00). Monitoring for 2.50% drawdown.
[LOSS_LIMIT_HIT] Daily loss limit reached! Loss: 2.50% (250.00). Closing all positions and stopping trading.
[PROFIT_PROTECTION_HIT] Drawdown from peak reached 2.50% (262.50). Closing all positions and stopping trading.
[DROP] Daily loss limit reached. Trading stopped for the day.
[DROP] Profit protection activated. Trading stopped for the day.
```

## Usage Notes

1. **DryRun Mode**: Protection system respects `DryRun` mode - positions won't actually close, but protection logic still triggers and logs actions

2. **Daily Reset**: Protection resets automatically at midnight (server time)

3. **Disable Profit Protection**: Set `EnableProfitProtection = false` to use only loss protection

4. **Adjust Threshold**: Modify `MAX_DAILY_LOSS_PERCENTAGE` to set your risk tolerance (e.g., 1.0 for 1%, 5.0 for 5%)

5. **Signal Rejection**: Once protection triggers, all incoming signals are rejected with logged messages until the next trading day

## Testing Recommendations

1. Test in `DryRun = true` mode first to verify logic
2. Monitor logs to ensure proper detection of day changes
3. Verify balance calculations match your broker's reporting
4. Test with small `MAX_DAILY_LOSS_PERCENTAGE` values initially (e.g., 0.5%)
5. Confirm position closures execute properly when limits are reached
