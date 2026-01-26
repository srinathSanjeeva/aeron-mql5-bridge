//+------------------------------------------------------------------+
//| Secret_Eye_V20_5_Aeron_Example.mq5                              |
//| Example code snippets showing Aeron integration                  |
//| NOT A COMPLETE FILE - Use these as reference for integration    |
//+------------------------------------------------------------------+

//==================================================================
// SECTION 1: Add at the top of Secret_Eye_V20_5_Ver.mq5
//==================================================================

#property strict
#include <Trade\Trade.mqh>

// V20.5 - Add Aeron includes
#include "AeronBridge.mqh"
#include "AeronPublisher.mqh"

//==================================================================
// SECTION 2: Add after existing input groups (around line 144)
//==================================================================

input group             "Aeron Publishing"
input bool              EnableAeronPublishing = true;      // Enable Aeron binary signal publishing
input string            AeronPublishChannel = "aeron:ipc"; // Aeron publish channel (or aeron:udp?endpoint=127.0.0.1:40123)
input int               AeronPublishStreamId = 2001;       // Aeron publish stream ID (different from subscriber stream)
input string            AeronPublishDir = "C:\\aeron\\standalone"; // Aeron directory path
input string            AeronSourceTag = "SecretEye_V20_5"; // Source strategy identifier for signal attribution

//==================================================================
// SECTION 3: Modify OnInit() - Add BEFORE "return(INIT_SUCCEEDED);"
//==================================================================

int OnInit()
{
    // ... existing initialization code ...
    
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
        Print("Binary Protocol: 104-byte frame (matches NinjaTrader AeronSignalPublisher)");
        
        int result = AeronBridge_StartPublisherW(
            AeronPublishDir,
            AeronPublishChannel,
            AeronPublishStreamId,
            3000);  // 3-second timeout
        
        if(result == 0)
        {
            uchar errBuf[512];
            int errLen = AeronBridge_LastError(errBuf, ArraySize(errBuf));
            string errMsg = (errLen > 0) ? CharArrayToString(errBuf, 0, errLen) : "Unknown error";
            
            PrintFormat("ERROR: Failed to start Aeron publisher: %s", errMsg);
            PrintFormat("Possible causes:");
            PrintFormat("  - MediaDriver not running");
            PrintFormat("  - Incorrect Aeron directory path");
            PrintFormat("  - Invalid channel format");
            PrintFormat("  - Port already in use (UDP mode)");
            
            if(ShowAlerts)
            {
                Alert("⚠️ ERROR: Failed to start Aeron publisher: ", errMsg);
                Alert("Check that MediaDriver is running and Aeron directory is correct");
            }
            // Continue anyway - don't fail initialization completely
        }
        else
        {
            Print("✅ Aeron publisher started successfully");
            Print("Ready to broadcast binary trading signals via Aeron");
            Print("Signal consumers can subscribe on channel: ", AeronPublishChannel);
            Print("Stream ID: ", AeronPublishStreamId);
            
            if(ShowAlerts)
            {
                Alert("✅ Aeron Publisher: Started successfully");
                Alert("Broadcasting on ", AeronPublishChannel, " stream ", AeronPublishStreamId);
            }
        }
    }
    else
    {
        Print("Aeron Binary Publishing is DISABLED (EnableAeronPublishing=false)");
        Print("To enable: Set EnableAeronPublishing=true in EA inputs");
    }
    
    return(INIT_SUCCEEDED);
}

//==================================================================
// SECTION 4: Modify OnDeinit() - Add AFTER IndicatorRelease()
//==================================================================

void OnDeinit(const int reason)
{
    IndicatorRelease(stochHandle);
    
    // V20.5 - Cleanup Aeron publisher
    if(EnableAeronPublishing)
    {
        AeronBridge_StopPublisher();
        Print("Aeron publisher stopped and cleaned up");
        Print("Binary signal broadcasting terminated");
    }
    
    Print("Terminating Stochastic Algo V20.5. Reason: ", reason);
}

//==================================================================
// SECTION 5: Modify OpenBuyPositions() - Add AFTER JSON publishing
//==================================================================

void OpenBuyPositions()
{
    Print("BUY Signal Detected. Opening dual positions.");
    
    // V20.4 - Generate signal ID and publish JSON signals
    string signalId = StringFormat("%lld-%d", GetTickCount64(), MathRand());
    
    if(PublishToKafka && !(publishFlags & PUBLISH_FLAG_SIGNAL))
    {
        // ... existing JSON publishing code ...
        // (keep all the existing JSON publishing logic here)
    }
    
    // ===============================================
    // V20.5 - Aeron Binary Signal Publishing
    // ===============================================
    if(EnableAeronPublishing)
    {
        string symbol = ExtractSymbolPrefix(_Symbol);
        string instrument = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : _Symbol;
        
        // Calculate confidence based on stochastic values (optional enhancement)
        double mainBuffer[], signalBuffer[];
        ArraySetAsSeries(mainBuffer, true);
        ArraySetAsSeries(signalBuffer, true);
        
        float confidence = 80.0; // Default confidence
        if(CopyBuffer(stochHandle, 0, 0, 3, mainBuffer) > 0 && 
           CopyBuffer(stochHandle, 1, 0, 3, signalBuffer) > 0)
        {
            double K = mainBuffer[0];
            double D = signalBuffer[0];
            // Higher confidence if K and D are more separated (stronger signal)
            confidence = (float)MathMin(50.0 + MathAbs(K - D), 95.0);
        }
        
        // Publish LongEntry1 (stop loss only, no take profit)
        bool pub1 = AeronPublishSignal(
            symbol,          // Symbol prefix (e.g., "ES", "NQ")
            instrument,      // Full instrument name
            AERON_LONG_ENTRY1,  // Action: Long entry 1
            SL,              // longSL in ticks
            0,               // shortSL (not used for long entries)
            0,               // profitTarget (entry1 uses stop loss only)
            1,               // quantity
            confidence,      // signal confidence
            AeronSourceTag   // source identifier
        );
        
        if(pub1)
        {
            PrintFormat("[AERON_PUB] ✅ LongEntry1 published: %s SL=%d qty=1 conf=%.1f", 
                        symbol, SL, confidence);
        }
        else
        {
            Print("[AERON_PUB] ⚠️ Failed to publish LongEntry1");
        }
        
        // Publish LongEntry2 (stop loss + profit target)
        int profitOffset = (int)(TP * 0.4);  // Match existing JSON logic
        bool pub2 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_LONG_ENTRY2,  // Action: Long entry 2
            SL,                 // longSL in ticks
            0,                  // shortSL
            SL + profitOffset,  // profitTarget in ticks
            1,                  // quantity
            confidence,
            AeronSourceTag
        );
        
        if(pub2)
        {
            PrintFormat("[AERON_PUB] ✅ LongEntry2 published: %s SL=%d TP=%d qty=1 conf=%.1f", 
                        symbol, SL, SL + profitOffset, confidence);
        }
        else
        {
            Print("[AERON_PUB] ⚠️ Failed to publish LongEntry2");
        }
    }
    
    // ... rest of existing OpenBuyPositions code ...
    // (keep all the trade execution logic)
}

//==================================================================
// SECTION 6: Modify OpenSellPositions() - Add AFTER JSON publishing
//==================================================================

void OpenSellPositions()
{
    Print("SELL Signal Detected. Opening dual positions.");
    
    // V20.4 - Generate signal ID and publish JSON signals
    string signalId = StringFormat("%lld-%d", GetTickCount64(), MathRand());
    
    if(PublishToKafka && !(publishFlags & PUBLISH_FLAG_SIGNAL))
    {
        // ... existing JSON publishing code ...
    }
    
    // ===============================================
    // V20.5 - Aeron Binary Signal Publishing
    // ===============================================
    if(EnableAeronPublishing)
    {
        string symbol = ExtractSymbolPrefix(_Symbol);
        string instrument = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : _Symbol;
        
        double mainBuffer[], signalBuffer[];
        ArraySetAsSeries(mainBuffer, true);
        ArraySetAsSeries(signalBuffer, true);
        
        float confidence = 80.0;
        if(CopyBuffer(stochHandle, 0, 0, 3, mainBuffer) > 0 && 
           CopyBuffer(stochHandle, 1, 0, 3, signalBuffer) > 0)
        {
            double K = mainBuffer[0];
            double D = signalBuffer[0];
            confidence = (float)MathMin(50.0 + MathAbs(K - D), 95.0);
        }
        
        // Publish ShortEntry1 (stop loss only)
        bool pub1 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_SHORT_ENTRY1,
            0,               // longSL (not used for short entries)
            SL,              // shortSL in ticks
            0,               // profitTarget (entry1 uses stop loss only)
            1,
            confidence,
            AeronSourceTag
        );
        
        if(pub1)
        {
            PrintFormat("[AERON_PUB] ✅ ShortEntry1 published: %s SL=%d qty=1 conf=%.1f", 
                        symbol, SL, confidence);
        }
        
        // Publish ShortEntry2 (stop loss + profit target)
        int profitOffset = (int)(TP * 0.4);
        bool pub2 = AeronPublishSignal(
            symbol,
            instrument,
            AERON_SHORT_ENTRY2,
            0,                  // longSL
            SL,                 // shortSL in ticks
            SL + profitOffset,  // profitTarget in ticks
            1,
            confidence,
            AeronSourceTag
        );
        
        if(pub2)
        {
            PrintFormat("[AERON_PUB] ✅ ShortEntry2 published: %s SL=%d TP=%d qty=1 conf=%.1f", 
                        symbol, SL, SL + profitOffset, confidence);
        }
    }
    
    // ... rest of existing OpenSellPositions code ...
}

//==================================================================
// SECTION 7: Add to OnTradeTransaction() - Exit Signal Publishing
//==================================================================

void OnTradeTransaction(
    const MqlTradeTransaction& trans,
    const MqlTradeRequest& request,
    const MqlTradeResult& result)
{
    // ... existing transaction handling ...
    
    // V20.5 - Publish Aeron exit signals when positions are closed
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD && EnableAeronPublishing)
    {
        ulong deal_ticket = trans.deal;
        if(HistoryDealSelect(deal_ticket))
        {
            ENUM_DEAL_ENTRY deal_entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
            ENUM_DEAL_TYPE deal_type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
            string deal_comment = HistoryDealGetString(deal_ticket, DEAL_COMMENT);
            
            string symbol = ExtractSymbolPrefix(_Symbol);
            string instrument = (StringLen(InstrumentFullName) > 0) ? InstrumentFullName : _Symbol;
            
            // Exit deals (position closures)
            if(deal_entry == DEAL_ENTRY_OUT)
            {
                // Check if it was a stop loss hit
                if(StringFind(deal_comment, "sl") >= 0 || StringFind(deal_comment, "stop") >= 0)
                {
                    if(deal_type == DEAL_TYPE_SELL)  // Closing long position
                    {
                        AeronPublishSignal(symbol, instrument, AERON_LONG_STOPLOSS,
                                          0, 0, 0, 1, 50.0, AeronSourceTag);
                        Print("[AERON_PUB] ✅ LongStopLoss published: ", symbol);
                    }
                    else if(deal_type == DEAL_TYPE_BUY)  // Closing short position
                    {
                        AeronPublishSignal(symbol, instrument, AERON_SHORT_STOPLOSS,
                                          0, 0, 0, 1, 50.0, AeronSourceTag);
                        Print("[AERON_PUB] ✅ ShortStopLoss published: ", symbol);
                    }
                }
                // Check if it was a profit target hit
                else if(StringFind(deal_comment, "tp") >= 0 || StringFind(deal_comment, "Scalp") >= 0)
                {
                    AeronPublishSignal(symbol, instrument, AERON_PROFIT_TARGET,
                                      0, 0, 0, 1, 50.0, AeronSourceTag);
                    Print("[AERON_PUB] ✅ ProfitTarget published: ", symbol);
                }
                // Manual exit or session close
                else
                {
                    if(deal_type == DEAL_TYPE_SELL)  // Closing long
                    {
                        AeronPublishSignal(symbol, instrument, AERON_LONG_EXIT,
                                          0, 0, 0, 1, 50.0, AeronSourceTag);
                        Print("[AERON_PUB] ✅ LongExit published: ", symbol);
                    }
                    else if(deal_type == DEAL_TYPE_BUY)  // Closing short
                    {
                        AeronPublishSignal(symbol, instrument, AERON_SHORT_EXIT,
                                          0, 0, 0, 1, 50.0, AeronSourceTag);
                        Print("[AERON_PUB] ✅ ShortExit published: ", symbol);
                    }
                }
            }
        }
    }
    
    // ... rest of existing OnTradeTransaction code ...
}

//==================================================================
// NOTES:
// 1. This is NOT a complete file - use these sections as reference
// 2. Keep ALL existing code - only ADD the Aeron sections
// 3. Compile after adding all sections
// 4. Test with AeronBridgeInt.mq5 as receiver
// 5. Set matching stream IDs between publisher and subscriber
//==================================================================
