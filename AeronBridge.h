#pragma once

#ifdef __cplusplus
extern "C" {
#endif

    // Wide-char API for MT5 (UTF-16). Use these from MQL5.

    // Start + subscribe in one call.
    // aeronDir: Aeron directory (e.g. L"C:\\aeron\\standalone")
    // channel : Aeron URI (e.g. L"aeron:udp?endpoint=239.10.10.1:40123")
    // streamId: stream id (e.g. 1001)
    // timeoutMs: max time to wait for subscription to become available
    // Returns 1 on success, 0 on failure.
    __declspec(dllexport) int AeronBridge_StartW(
        const wchar_t* aeronDir,
        const wchar_t* channel,
        int streamId,
        int timeoutMs);

    // Optional: register/override mapping + tick conversion rules
    // futPrefix: "ES", "NQ", etc.
    // mt5Symbol: "SPX500", "NAS100", etc.
    // futTickSize: e.g. ES=0.25, NQ=0.25
    // mt5PointSize: broker-dependent, e.g. 0.1 for many indices
    // Returns 1 on success, 0 on invalid args.
    __declspec(dllexport) int AeronBridge_RegisterInstrumentMapW(
        const wchar_t* futPrefix,
        const wchar_t* mt5Symbol,
        double futTickSize,
        double mt5PointSize);

    // Configure unmapped symbol behavior
    // allowUnmapped: 1 = pass-through unmapped symbols with prefix as symbol, 0 = drop them (default)
    // defaultTickSize: tick size to use for unmapped instruments (e.g. 0.01)
    // defaultPointSize: point size to use for unmapped instruments (e.g. 0.01)
    // Returns 1 on success.
    __declspec(dllexport) int AeronBridge_SetUnmappedBehaviorW(
        int allowUnmapped,
        double defaultTickSize,
        double defaultPointSize);

    // Poll Aeron (call on timer/tick).
    __declspec(dllexport) int AeronBridge_Poll();

    // Returns 1 if a *valid* signal is ready (after filtering + mapping), else 0.
    __declspec(dllexport) int AeronBridge_HasSignal();

    // Get last valid signal as CSV (ASCII/UTF-8 bytes into uchar[]).
    // CSV format:
    // action,qty,sl_points,pt_points,confidence,symbol,mt5_symbol,source,instrument
    // Returns bytes written (excluding null terminator), 0 if none.
    __declspec(dllexport) int AeronBridge_GetSignalCsv(unsigned char* outBuf, int outBufLen);

    // Stop/cleanup
    __declspec(dllexport) void AeronBridge_Stop();

    // Copies last error string into outBuf (UTF-8 bytes). Returns bytes written.
    __declspec(dllexport) int AeronBridge_LastError(unsigned char* outBuf, int outBufLen);

    // ===============================
    // Publisher API (Aeron Producer)
    // ===============================

    // Start Aeron publisher
    // aeronDir: Aeron directory (e.g. L"C:\\aeron\\standalone")
    // channel : Aeron URI for publishing (e.g. L"aeron:ipc" or L"aeron:udp?endpoint=127.0.0.1:40123")
    // streamId: stream id for publication (e.g. 2001)
    // timeoutMs: max time to wait for publication to become available
    // Returns 1 on success, 0 on failure.
    __declspec(dllexport) int AeronBridge_StartPublisherW(
        const wchar_t* aeronDir,
        const wchar_t* channel,
        int streamId,
        int timeoutMs);

    // Publish a binary signal message (104 bytes, same format as subscriber)
    // buffer: 104-byte binary message in the protocol format
    // Returns 1 on success, 0 on failure.
    __declspec(dllexport) int AeronBridge_PublishBinary(
        const unsigned char* buffer,
        int bufferLen);

    // Stop/cleanup publisher
    __declspec(dllexport) void AeronBridge_StopPublisher();

    // ===============================
    // Dual Publisher API (IPC + UDP)
    // ===============================

    // Start Aeron IPC publisher
    __declspec(dllexport) int AeronBridge_StartPublisherIpcW(
        const wchar_t* aeronDir,
        const wchar_t* channel,
        int streamId,
        int timeoutMs);

    // Start Aeron UDP publisher
    __declspec(dllexport) int AeronBridge_StartPublisherUdpW(
        const wchar_t* aeronDir,
        const wchar_t* channel,
        int streamId,
        int timeoutMs);

    // Publish binary signal to IPC channel
    __declspec(dllexport) int AeronBridge_PublishBinaryIpc(
        const unsigned char* buffer,
        int bufferLen);

    // Publish binary signal to UDP channel
    __declspec(dllexport) int AeronBridge_PublishBinaryUdp(
        const unsigned char* buffer,
        int bufferLen);

    // Stop/cleanup IPC publisher
    __declspec(dllexport) void AeronBridge_StopPublisherIpc();

    // Stop/cleanup UDP publisher
    __declspec(dllexport) void AeronBridge_StopPublisherUdp();

#ifdef __cplusplus
}
#endif
