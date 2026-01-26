//+------------------------------------------------------------------+
//| Secret_Eye_V20_5_Aeron_Integration.txt |
//| Integration Guide for Adding Aeron Binary Publisher |
//+------------------------------------------------------------------+

# STEP 1: Add Aeron inputs to Secret_Eye_V20_5_Ver.mq5

Add after the existing "JSON Publishing" group (around line 144):

input group "Aeron Publishing"
input bool EnableAeronPublishing = true; // Enable Aeron binary signal publishing
input string AeronPublishChannel = "aeron:ipc"; // Aeron publish channel
input int AeronPublishStreamId = 2001; // Aeron publish stream ID
input string AeronPublishDir = "C:\\aeron\\standalone"; // Aeron directory
input string AeronSourceTag = "SecretEye_V20_5"; // Source strategy identifier

# STEP 2: Include the necessary headers

Add at the top of Secret_Eye_V20_5_Ver.mq5 (after #include <Trade/Trade.mqh>):

#include "AeronBridge.mqh"
#include "AeronPublisher.mqh"

# STEP 3: Modify OnInit() function

Add this code BEFORE the "return(INIT_SUCCEEDED);" line in OnInit() (around line 940):

    // ===============================
    // V20.5 - Aeron Publishing Setup
    // ===============================
    if(EnableAeronPublishing)
    {
        Print("=== AERON BINARY PUBLISHING CONFIGURATION ===");
        Print("Aeron Publishing Enabled: YES");
        Print("Aeron Directory: ", AeronPublishDir);
        Print("Publish Channel: ", AeronPublishChannel);
        Print("Stream ID: ", AeronPublishStreamId);
        Print("Source Tag: ", AeronSourceTag);

        int result = AeronBridge_StartPublisherW(
            AeronPublishDir,
            AeronPublishChannel,
            AeronPublishStreamId,
            3000);

        if(result == 0)
        {
            uchar errBuf[512];
            int errLen = AeronBridge_LastError(errBuf, ArraySize(errBuf));
            string errMsg = (errLen > 0) ? CharArrayToString(errBuf, 0, errLen) : "Unknown error";

            PrintFormat("ERROR: Failed to start Aeron publisher: %s", errMsg);
            if(ShowAlerts)
            {
                Alert("⚠️ ERROR: Failed to start Aeron publisher: ", errMsg);
            }
            // Continue anyway - don't fail initialization
        }
        else
        {
            Print("Aeron publisher started successfully");
            Print("Ready to broadcast binary trading signals via Aeron");
            if(ShowAlerts)
            {
                Alert("✅ Aeron Publisher: Started successfully on ", AeronPublishChannel);
            }
        }
    }
    else
    {
        Print("Aeron Binary Publishing is DISABLED (EnableAeronPublishing=false)");
    }

# STEP 4: Modify OnDeinit() function

Add this code in OnDeinit(), AFTER "IndicatorRelease(stochHandle);":

    // V20.5 - Cleanup Aeron publisher
    if(EnableAeronPublishing)
    {
        AeronBridge_StopPublisher();
        Print("Aeron publisher stopped and cleaned up");
    }

# STEP 5: Add Aeron publishing to OpenBuyPositions()

Add this code AFTER the existing "PublishToKafka" block (around line 1850):

    // V20.5 - Aeron binary signal publishing
    if(EnableAeronPublishing)
    {
        string symbol = ExtractSymbolPrefix(_Symbol);
        string instrument = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : _Symbol;
        float confidence = 80.0; // Can be calculated based on stochastic values

        // Publish LongEntry1 (stop loss only)
        bool pub1 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_LONG_ENTRY1,
            SL,              // longSL
            0,               // shortSL
            0,               // profitTarget (entry1 has no TP)
            1,               // qty
            confidence,
            AeronSourceTag
        );

        if(pub1)
        {
            PrintFormat("[AERON_PUB] LongEntry1: %s SL=%d qty=1", symbol, SL);
        }

        // Publish LongEntry2 (stop loss + profit target)
        int profitOffset = (int)(TP * 0.4);
        bool pub2 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_LONG_ENTRY2,
            SL,                        // longSL
            0,                         // shortSL
            SL + profitOffset,         // profitTarget
            1,                         // qty
            confidence,
            AeronSourceTag
        );

        if(pub2)
        {
            PrintFormat("[AERON_PUB] LongEntry2: %s SL=%d TP=%d qty=1", symbol, SL, SL + profitOffset);
        }
    }

# STEP 6: Add Aeron publishing to OpenSellPositions()

Add this code AFTER the existing "PublishToKafka" block in OpenSellPositions():

    // V20.5 - Aeron binary signal publishing
    if(EnableAeronPublishing)
    {
        string symbol = ExtractSymbolPrefix(_Symbol);
        string instrument = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : _Symbol;
        float confidence = 80.0;

        // Publish ShortEntry1 (stop loss only)
        bool pub1 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_SHORT_ENTRY1,
            0,               // longSL
            SL,              // shortSL
            0,               // profitTarget
            1,               // qty
            confidence,
            AeronSourceTag
        );

        if(pub1)
        {
            PrintFormat("[AERON_PUB] ShortEntry1: %s SL=%d qty=1", symbol, SL);
        }

        // Publish ShortEntry2 (stop loss + profit target)
        int profitOffset = (int)(TP * 0.4);
        bool pub2 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_SHORT_ENTRY2,
            0,                         // longSL
            SL,                        // shortSL
            SL + profitOffset,         // profitTarget
            1,                         // qty
            confidence,
            AeronSourceTag
        );

        if(pub2)
        {
            PrintFormat("[AERON_PUB] ShortEntry2: %s SL=%d TP=%d qty=1", symbol, SL, SL + profitOffset);
        }
    }

# STEP 7: Add Aeron publishing to OnTradeTransaction() for exit signals

In the OnTradeTransaction() function, add this code in the appropriate sections:

For Long Stop Loss (when a long position is closed by stop loss):
if(EnableAeronPublishing)
{
string symbol = ExtractSymbolPrefix(\_Symbol);
string instrument = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : \_Symbol;

        AeronPublishSignal(
            symbol, instrument,
            AERON_LONG_STOPLOSS,
            0, 0, 0, 1, 50.0,
            AeronSourceTag
        );
        PrintFormat("[AERON_PUB] LongStopLoss: %s", symbol);
    }

For Short Stop Loss (when a short position is closed by stop loss):
if(EnableAeronPublishing)
{
string symbol = ExtractSymbolPrefix(\_Symbol);
string instrument = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : \_Symbol;

        AeronPublishSignal(
            symbol, instrument,
            AERON_SHORT_STOPLOSS,
            0, 0, 0, 1, 50.0,
            AeronSourceTag
        );
        PrintFormat("[AERON_PUB] ShortStopLoss: %s", symbol);
    }

For Profit Target (when scalp position takes profit):
if(EnableAeronPublishing)
{
string symbol = ExtractSymbolPrefix(\_Symbol);
string instrument = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : \_Symbol;

        AeronPublishSignal(
            symbol, instrument,
            AERON_PROFIT_TARGET,
            0, 0, 0, 1, 50.0,
            AeronSourceTag
        );
        PrintFormat("[AERON_PUB] ProfitTarget: %s", symbol);
    }

For Long Exit (manual or session close):
if(EnableAeronPublishing)
{
string symbol = ExtractSymbolPrefix(\_Symbol);
string instrument = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : \_Symbol;

        AeronPublishSignal(
            symbol, instrument,
            AERON_LONG_EXIT,
            0, 0, 0, 1, 50.0,
            AeronSourceTag
        );
        PrintFormat("[AERON_PUB] LongExit: %s", symbol);
    }

For Short Exit (manual or session close):
if(EnableAeronPublishing)
{
string symbol = ExtractSymbolPrefix(\_Symbol);
string instrument = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : \_Symbol;

        AeronPublishSignal(
            symbol, instrument,
            AERON_SHORT_EXIT,
            0, 0, 0, 1, 50.0,
            AeronSourceTag
        );
        PrintFormat("[AERON_PUB] ShortExit: %s", symbol);
    }

# STEP 8: Rebuild the AeronBridge.dll

1. Open AeronBridge.sln in Visual Studio
2. Ensure you have the updated AeronBridge.h and AeronBridge.cpp files
3. Set configuration to Release / x64
4. Build solution (Ctrl+Shift+B)
5. Copy the built AeronBridge.dll to MT5's Libraries folder:
   MT5_DATA_FOLDER\MQL5\Libraries\

6. Also copy to:
   - c:\projects\quant\vs-repos\aeron-mql5-bridge\x64\Release\
   - Any broker-specific folders (Audacity, forex.com, etc.)

# STEP 9: Copy files to MT5

Copy these files to your MT5 data folder:

1. AeronBridge.mqh → MQL5\Include\
2. AeronPublisher.mqh → MQL5\Include\
3. AeronBridge.dll → MQL5\Libraries\
4. Secret_Eye_V20_5_Ver.mq5 → MQL5\Experts\ (after modifications)

# STEP 10: Compile and Test

1. Open Secret_Eye_V20_5_Ver.mq5 in MetaEditor
2. Compile (F7)
3. Fix any compilation errors
4. Load onto a chart
5. Check Experts log for:

   - "Aeron publisher started successfully"
   - "[AERON_PUB]" messages when signals are generated

6. Verify the receiving end (e.g., AeronBridgeInt.mq5) can receive the signals

# TESTING CHECKLIST:

□ DLL compiles without errors
□ MQ5 compiles without errors  
□ Aeron publisher starts successfully in OnInit
□ Long entry signals publish correctly (Entry1 and Entry2)
□ Short entry signals publish correctly (Entry1 and Entry2)
□ Exit signals publish correctly (StopLoss, ProfitTarget, Exit)
□ Subscriber EA receives and decodes signals correctly
□ No memory leaks or crashes during extended testing
□ Binary protocol matches exactly (104 bytes)

# TROUBLESHOOTING:

1. If "Failed to start Aeron publisher":

   - Check that MediaDriver is running
   - Verify Aeron directory path is correct
   - Check channel format (aeron:ipc or aeron:udp?endpoint=...)
   - Review DLL logs

2. If signals not received:

   - Verify stream IDs match between publisher and subscriber
   - Check that channels match
   - Ensure both are using same Aeron directory
   - Use Aeron tools to monitor streams

3. If compilation errors:
   - Ensure all .mqh files are in Include folder
   - Ensure DLL is in Libraries folder
   - Check that imports match function signatures
   - Rebuild DLL if you modified C++ code
