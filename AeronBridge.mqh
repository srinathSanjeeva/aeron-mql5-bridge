// AeronBridge.mqh
#import "AeronBridge.dll"

// Start Aeron + subscribe in one call
int  AeronBridge_StartW(
    string aeronDir,
    string channel,
    int    streamId,
    int    timeoutMs
);

// 
int  AeronBridge_RegisterInstrumentMapW(string futPrefix, string mt5Symbol, double futTickSize, double mt5PointSize);


// Poll subscription
int  AeronBridge_Poll();

// Message state
int  AeronBridge_HasSignal();

int  AeronBridge_GetSignalCsv(uchar &outBuf[], int outBufLen);


// Stop everything
void AeronBridge_Stop();

// Last error
int    AeronBridge_LastError(uchar &buffer[], int bufferLen);


#import
