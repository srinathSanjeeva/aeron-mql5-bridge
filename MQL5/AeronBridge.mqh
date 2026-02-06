//+------------------------------------------------------------------+
//| AeronBridge.mqh - MQL5 Import Declarations for AeronBridge.dll  |
//+------------------------------------------------------------------+
#ifndef AERON_BRIDGE_MQH
#define AERON_BRIDGE_MQH

#import "AeronBridge.dll"

// Subscriber API
int  AeronBridge_StartW(string aeronDir, string channel, int streamId, int timeoutMs);
int  AeronBridge_RegisterInstrumentMapW(string futPrefix, string mt5Symbol, double futTickSize, double mt5PointSize);
int  AeronBridge_SetUnmappedBehaviorW(int allowUnmapped, double defaultTickSize, double defaultPointSize);
int  AeronBridge_Poll();
int  AeronBridge_HasSignal();
int  AeronBridge_GetSignalCsv(uchar &outBuf[], int outBufLen);
void AeronBridge_Stop();
int  AeronBridge_LastError(uchar &buffer[], int bufferLen);

// Publisher API
int  AeronBridge_StartPublisherW(string aeronDir, string channel, int streamId, int timeoutMs);
int  AeronBridge_PublishBinary(uchar &buffer[], int bufferLen);
void AeronBridge_StopPublisher();

// Dual Publisher API (IPC + UDP)
int  AeronBridge_StartPublisherIpcW(string aeronDir, string channel, int streamId, int timeoutMs);
int  AeronBridge_StartPublisherUdpW(string aeronDir, string channel, int streamId, int timeoutMs);
int  AeronBridge_PublishBinaryIpc(uchar &buffer[], int bufferLen);
int  AeronBridge_PublishBinaryUdp(uchar &buffer[], int bufferLen);
void AeronBridge_StopPublisherIpc();
void AeronBridge_StopPublisherUdp();

#import

#endif // AERON_BRIDGE_MQH
