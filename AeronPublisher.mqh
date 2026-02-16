//+------------------------------------------------------------------+
//| AeronPublisher.mqh - Binary Signal Publisher for MT5            |
//| Matches the protocol in AeronSignalPublisher.cs                  |
//+------------------------------------------------------------------+
//| IMPORTANT: Include AeronBridge.mqh BEFORE this file in your EA  |
//+------------------------------------------------------------------+

// Protocol constants (must match C# publisher - AeronSignalPublisher.cs)
#define AERON_MAGIC        0xA330BEEF  // Will be interpreted as signed int
#define AERON_VERSION      1
#define AERON_FRAME_SIZE   104

// Field sizes (must match C# exactly)
// Header: 4+2+2+8+4+4+4+4+4 = 36 bytes
// Strings: 16+32+16 = 64 bytes
// Total: 100 bytes (with 4 bytes padding to reach 104)
#define SYMBOL_LEN         16
#define INSTRUMENT_LEN     32
#define SOURCE_LEN         16

// Strategy action enum (matches C#)
enum AeronStrategyAction
{
   AERON_LONG_ENTRY1    = 1,
   AERON_LONG_ENTRY2    = 2,
   AERON_SHORT_ENTRY1   = 3,
   AERON_SHORT_ENTRY2   = 4,
   AERON_LONG_EXIT      = 5,
   AERON_SHORT_EXIT     = 6,
   AERON_LONG_STOPLOSS  = 7,
   AERON_SHORT_STOPLOSS = 8,
   AERON_PROFIT_TARGET  = 9,
   AERON_FORCE_EXIT     = 10  // Close all positions (reverse signal after hours)
};

//+------------------------------------------------------------------+
//| Helper: Write int32 in little-endian                             |
//+------------------------------------------------------------------+
void WriteInt32LE(uchar &buffer[], int offset, int value)
{
   buffer[offset + 0] = (uchar)(value & 0xFF);
   buffer[offset + 1] = (uchar)((value >> 8) & 0xFF);
   buffer[offset + 2] = (uchar)((value >> 16) & 0xFF);
   buffer[offset + 3] = (uchar)((value >> 24) & 0xFF);
}

//+------------------------------------------------------------------+
//| Helper: Write int16 in little-endian                             |
//+------------------------------------------------------------------+
void WriteInt16LE(uchar &buffer[], int offset, int value)
{
   buffer[offset + 0] = (uchar)(value & 0xFF);
   buffer[offset + 1] = (uchar)((value >> 8) & 0xFF);
}

//+------------------------------------------------------------------+
//| Helper: Write int64 in little-endian                             |
//+------------------------------------------------------------------+
void WriteInt64LE(uchar &buffer[], int offset, long value)
{
   buffer[offset + 0] = (uchar)(value & 0xFF);
   buffer[offset + 1] = (uchar)((value >> 8) & 0xFF);
   buffer[offset + 2] = (uchar)((value >> 16) & 0xFF);
   buffer[offset + 3] = (uchar)((value >> 24) & 0xFF);
   buffer[offset + 4] = (uchar)((value >> 32) & 0xFF);
   buffer[offset + 5] = (uchar)((value >> 40) & 0xFF);
   buffer[offset + 6] = (uchar)((value >> 48) & 0xFF);
   buffer[offset + 7] = (uchar)((value >> 56) & 0xFF);
}

//+------------------------------------------------------------------+
//| Helper: Write float32 in little-endian                           |
//+------------------------------------------------------------------+

// Helper struct for float conversion
struct FloatConverter
{
   float f;
};

void WriteFloat32LE(uchar &buffer[], int offset, double value)
{
   // MQL5 workaround: use structure packing
   // Convert double to float, then to bytes
   float fval = (float)value;
   
   // Pack into a structure and copy bytes
   FloatConverter temp;
   temp.f = fval;
   
   // Extract bytes using StructToCharArray
   uchar bytes[];
   int bytesWritten = StructToCharArray(temp, bytes);
   
   // Copy up to 4 bytes in little-endian order (with bounds check)
   int copyLen = MathMin(4, bytesWritten);
   for(int i = 0; i < copyLen; i++)
   {
      buffer[offset + i] = bytes[i];
   }
   // Pad remaining bytes with zeros if StructToCharArray returned less than 4
   for(int i = copyLen; i < 4; i++)
   {
      buffer[offset + i] = 0;
   }
}

//+------------------------------------------------------------------+
//| Helper: Write ASCII string with zero-padding                     |
//+------------------------------------------------------------------+
void WriteAsciiPadded(uchar &buffer[], int offset, string value, int maxLen)
{
   // Bounds check
   int bufferSize = ArraySize(buffer);
   if(offset < 0 || offset + maxLen > bufferSize)
   {
      PrintFormat("[AERON_ERROR] WriteAsciiPadded bounds error: offset=%d, maxLen=%d, bufferSize=%d", offset, maxLen, bufferSize);
      return;
   }
   
   // Zero fill
   for(int i = 0; i < maxLen; i++)
      buffer[offset + i] = 0;
   
   // Copy string (truncate if necessary)
   int len = StringLen(value);
   if(len > maxLen) len = maxLen;
   
   for(int i = 0; i < len; i++)
   {
      ushort ch = StringGetCharacter(value, i);
      buffer[offset + i] = (uchar)(ch <= 127 ? ch : '?');
   }
}

//+------------------------------------------------------------------+
//| Helper: Get nanoseconds since Unix epoch (approximate)           |
//+------------------------------------------------------------------+
long GetTimestampNanos()
{
   // Unix epoch: 1970-01-01 00:00:00
   datetime unixEpoch = D'1970.01.01';
   datetime now = TimeCurrent();
   
   // Seconds since epoch
   long seconds = (long)(now - unixEpoch);
   
   // Convert to nanoseconds (approximate - MT5 doesn't have sub-second precision for TimeCurrent)
   // We can use GetTickCount64() for milliseconds within the current session
   long nanos = seconds * 1000000000LL;
   
   // Add milliseconds from tick count (modulo to avoid overflow issues)
   long tickMs = (long)(GetTickCount64() % 1000);
   nanos += tickMs * 1000000LL;
   
   return nanos;
}

//+------------------------------------------------------------------+
//| Encode and publish Aeron signal (binary format)                 |
//+------------------------------------------------------------------+
bool AeronPublishSignal(
   string symbol,           // e.g., "ES", "NQ"
   string instrument,       // Full instrument name
   AeronStrategyAction action,
   int longSL,              // Stop loss for long positions (in ticks)
   int shortSL,             // Stop loss for short positions (in ticks)
   int profitTarget,        // Profit target (in ticks)
   int qty,                 // Position quantity
   float confidence,        // Signal confidence (0-100)
   string source            // Source strategy tag
)
{
   uchar buffer[AERON_FRAME_SIZE];
   ArrayInitialize(buffer, 0);
   
   int offset = 0;
   
   // MAGIC (4 bytes)
   WriteInt32LE(buffer, offset, (int)AERON_MAGIC);
   offset += 4;
   
   // VERSION (2 bytes)
   WriteInt16LE(buffer, offset, AERON_VERSION);
   offset += 2;
   
   // ACTION (2 bytes)
   WriteInt16LE(buffer, offset, (int)action);
   offset += 2;
   
   // TIMESTAMP (8 bytes) - nanoseconds since Unix epoch
   WriteInt64LE(buffer, offset, GetTimestampNanos());
   offset += 8;
   
   // LONG_SL (4 bytes)
   WriteInt32LE(buffer, offset, longSL);
   offset += 4;
   
   // SHORT_SL (4 bytes)
   WriteInt32LE(buffer, offset, shortSL);
   offset += 4;
   
   // PROFIT_TARGET (4 bytes)
   WriteInt32LE(buffer, offset, profitTarget);
   offset += 4;
   
   // QTY (4 bytes)
   WriteInt32LE(buffer, offset, qty);
   offset += 4;
   
   // CONFIDENCE (4 bytes float)
   WriteFloat32LE(buffer, offset, confidence);
   offset += 4;
   
   // SYMBOL (16 bytes)
   WriteAsciiPadded(buffer, offset, symbol, SYMBOL_LEN);
   offset += SYMBOL_LEN;
   
   // INSTRUMENT (32 bytes)
   WriteAsciiPadded(buffer, offset, instrument, INSTRUMENT_LEN);
   offset += INSTRUMENT_LEN;
   
   // SOURCE (16 bytes)
   WriteAsciiPadded(buffer, offset, source, SOURCE_LEN);
   offset += SOURCE_LEN;
   
   // PADDING (4 bytes) - to reach 104 byte frame size
   // Bytes are already 0 from ArrayInitialize
   offset += 4;
   
   // Total should be 104 bytes
   if(offset != AERON_FRAME_SIZE)
   {
      PrintFormat("[AERON_ERROR] Frame size mismatch: %d != %d", offset, AERON_FRAME_SIZE);
      return false;
   }
   
   // Publish via DLL
   int result = AeronBridge_PublishBinary(buffer, AERON_FRAME_SIZE);
   if(result == 0)
   {
      Print("[AERON_ERROR] Failed to publish signal");
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Helper: Extract symbol prefix from instrument full name         |
//+------------------------------------------------------------------+
string ExtractSymbolPrefix(string fullName)
{
   // Extract first token before space or first 2-3 chars
   int spacePos = StringFind(fullName, " ");
   if(spacePos > 0)
      return StringSubstr(fullName, 0, spacePos);
   
   // Fallback: first 2-3 characters
   int len = StringLen(fullName);
   if(len >= 3) return StringSubstr(fullName, 0, 3);
   if(len >= 2) return StringSubstr(fullName, 0, 2);
   return fullName;
}
