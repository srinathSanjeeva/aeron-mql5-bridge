// AeronBridge.mqh
#import "AeronBridge.dll"

// Start Aeron + subscribe in one call
int  AeronBridge_Start(
    string aeronDir,
    string channel,
    int    streamId,
    int    timeoutMs
);

// Poll subscription
int  AeronBridge_Poll();

// Message state
int  AeronBridge_HasMessage();

// Read message
int  AeronBridge_GetMessage(uchar &buffer[], int bufferLen);

// Stop everything
void AeronBridge_Stop();

// Last error
int    AeronBridge_LastError(uchar &buffer[], int bufferLen);


#import
