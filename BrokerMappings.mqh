//+------------------------------------------------------------------+
//|                                               BrokerMappings.mqh |
//|                   Centralized Broker Symbol Mapping Definitions  |
//+------------------------------------------------------------------+
#property strict

#include "AeronBridge.mqh"

//+------------------------------------------------------------------+
//| Broker Profile Enumeration                                        |
//+------------------------------------------------------------------+
enum ENUM_BROKER_PROFILE
{
   BROKER_PROFILE_A,        // Broker A (DJ30, SPX500, NAS100)
   BROKER_PROFILE_B,        // Broker B (US30, US500, USTEC)
   BROKER_PROFILE_C,        // Broker C (Custom naming)
   BROKER_PROFILE_CUSTOM    // Use custom configuration
};

//+------------------------------------------------------------------+
//| Register Broker-Specific Symbol Mappings                         |
//+------------------------------------------------------------------+
bool RegisterBrokerMappings(ENUM_BROKER_PROFILE profile)
{
   bool success = true;
   
   switch(profile)
   {
      case BROKER_PROFILE_A:
         Print("Loading Broker A symbol mappings...");
         // Broker A uses DJ30, SPX500, TECH100, US2000
         success &= (AeronBridge_RegisterInstrumentMapW("YM", "DJ30", 1.0, 0.1) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("NQ", "TECH100", 0.25, 0.1) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("MBT", "BTCUSD", 5.0, 0.01) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("RTY", "US2000", 0.10, 0.1) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("ZB", "US10Y", 0.03125, 0.01) == 1);
        //  success &= (AeronBridge_RegisterInstrumentMapW("GC", "GOLD", 0.10, 0.01) == 1);
        //  success &= (AeronBridge_RegisterInstrumentMapW("CL", "CRUDEOIL", 0.01, 0.01) == 1);
         break;
         
      case BROKER_PROFILE_B:
         Print("Loading Broker B symbol mappings...");
         // Broker B uses US30, US500, NAS100
         success &= (AeronBridge_RegisterInstrumentMapW("YM", "US30", 1.0, 0.1) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("ES", "SPX500", 0.25, 0.1) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("NQ", "NAS100", 0.25, 0.1) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("MBT", "BTCUSD", 5.0, 0.01) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("RTY", "RUSSELL", 0.10, 0.1) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("ZB", "BOND", 0.03125, 0.01) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("GC", "XAUUSD", 0.10, 0.01) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("CL", "US Oil", 0.01, 0.01) == 1);
         break;
         
      case BROKER_PROFILE_C:
         Print("Loading Broker C symbol mappings...");
         // Broker C uses futures-style naming with contract month
         success &= (AeronBridge_RegisterInstrumentMapW("YM", "YMH25", 1.0, 0.01) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("ES", "ESH25", 0.25, 0.01) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("NQ", "NQH25", 0.25, 0.01) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("MBT", "BTCUSD", 5.0, 0.01) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("RTY", "RTYH25", 0.10, 0.01) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("ZB", "ZBH25", 0.03125, 0.015625) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("GC", "GCJ25", 0.10, 0.01) == 1);
         success &= (AeronBridge_RegisterInstrumentMapW("CL", "CLG25", 0.01, 0.01) == 1);
         break;
         
      case BROKER_PROFILE_CUSTOM:
         Print("BROKER_PROFILE_CUSTOM selected - mappings must be registered manually");
         // User must call AeronBridge_RegisterInstrumentMapW manually
         success = true;
         break;
         
      default:
         Print("Unknown broker profile: ", (int)profile);
         success = false;
   }
   
   if(success)
      Print("Broker mappings registered successfully");
   else
      Print("WARNING: Some broker mappings failed to register");
   
   return success;
}

//+------------------------------------------------------------------+
//| Register Custom Symbol Mapping                                   |
//| Use this for one-off mappings or custom configurations           |
//+------------------------------------------------------------------+
bool RegisterCustomMapping(
   string futPrefix,
   string mt5Symbol,
   double futTickSize,
   double mt5PointSize)
{
   int result = AeronBridge_RegisterInstrumentMapW(
      futPrefix,
      mt5Symbol,
      futTickSize,
      mt5PointSize
   );
   
   if(result == 1)
   {
      PrintFormat("Registered: %s -> %s (TickSize=%.5f, PointSize=%.5f)",
         futPrefix, mt5Symbol, futTickSize, mt5PointSize);
      return true;
   }
   else
   {
      PrintFormat("Failed to register: %s -> %s", futPrefix, mt5Symbol);
      return false;
   }
}

//+------------------------------------------------------------------+
//| Detect Broker Profile from Account Server Name                   |
//| Attempts to auto-detect broker based on account info             |
//+------------------------------------------------------------------+
ENUM_BROKER_PROFILE DetectBrokerProfile()
{
   string serverName = AccountInfoString(ACCOUNT_SERVER);
   string companyName = AccountInfoString(ACCOUNT_COMPANY);
   
   Print("Detecting broker profile...");
   PrintFormat("Server: %s, Company: %s", serverName, companyName);
   
   // Add your broker detection logic here
   // Example:
   if(StringFind(serverName, "BrokerA") >= 0 || StringFind(companyName, "BrokerA") >= 0)
   {
      Print("Detected: Broker A");
      return BROKER_PROFILE_A;
   }
   else if(StringFind(serverName, "BrokerB") >= 0 || StringFind(companyName, "BrokerB") >= 0)
   {
      Print("Detected: Broker B");
      return BROKER_PROFILE_B;
   }
   else if(StringFind(serverName, "BrokerC") >= 0 || StringFind(companyName, "BrokerC") >= 0)
   {
      Print("Detected: Broker C");
      return BROKER_PROFILE_C;
   }
   
   // Default to custom if unable to detect
   Print("Unable to auto-detect broker - using BROKER_PROFILE_CUSTOM");
   return BROKER_PROFILE_CUSTOM;
}

//+------------------------------------------------------------------+
//| Load Mappings from CSV File                                      |
//| File format: FutPrefix,MT5Symbol,TickSize,PointSize             |
//+------------------------------------------------------------------+
bool LoadMappingsFromCSV(string filename)
{
   string filepath = filename;
   
   // Try to find file in common locations
   int handle = FileOpen(filepath, FILE_READ|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
   {
      filepath = "MQL5\\Files\\" + filename;
      handle = FileOpen(filename, FILE_READ|FILE_CSV|FILE_ANSI, ',');
   }
   
   if(handle == INVALID_HANDLE)
   {
      PrintFormat("Failed to open mapping file: %s (Error: %d)", filename, GetLastError());
      return false;
   }
   
   Print("Loading mappings from: ", filename);
   
   // Skip header line if present
   if(!FileIsEnding(handle))
   {
      string header = FileReadString(handle);
      // Check if it's actually a header (contains non-numeric chars)
      if(StringFind(header, "FutPrefix") >= 0 || StringFind(header, "Symbol") >= 0)
      {
         // Header detected, move to next line
      }
      else
      {
         // First line is data, seek back to start
         FileSeek(handle, 0, SEEK_SET);
      }
   }
   
   int count = 0;
   while(!FileIsEnding(handle))
   {
      string futPrefix = FileReadString(handle);
      if(futPrefix == "") break; // End of file or empty line
      
      string mt5Symbol = FileReadString(handle);
      double tickSize = FileReadNumber(handle);
      double pointSize = FileReadNumber(handle);
      
      if(RegisterCustomMapping(futPrefix, mt5Symbol, tickSize, pointSize))
         count++;
   }
   
   FileClose(handle);
   
   PrintFormat("Loaded %d symbol mappings from CSV", count);
   return (count > 0);
}

//+------------------------------------------------------------------+
//| Example CSV File Content (save as broker_mappings.csv):          |
//|                                                                  |
//| FutPrefix,MT5Symbol,TickSize,PointSize                          |
//| YM,DJ30,1.0,0.1                                                  |
//| ES,SPX500,0.25,0.1                                               |
//| NQ,NAS100,0.25,0.1                                               |
//| RTY,US2000,0.10,0.1                                              |
//| ZB,US10Y,0.03125,0.01                                            |
//| GC,GOLD,0.10,0.01                                                |
//| CL,CRUDEOIL,0.01,0.01                                            |
//|                                                                  |
//+------------------------------------------------------------------+
