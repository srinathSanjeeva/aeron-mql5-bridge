#pragma once

#ifdef __cplusplus
extern "C" {
#endif

	__declspec(dllexport) int AeronBridge_Start(
		const wchar_t* aeronDirW,
		const wchar_t* channelW,
		int streamId,
		int timeoutMs
	);
	__declspec(dllexport)
		int AeronBridge_Subscribe(
			const wchar_t* channelW,
			int streamId,
			int timeoutMs
		);

	__declspec(dllexport) int  AeronBridge_Poll(void);
	__declspec(dllexport) int  AeronBridge_HasMessage(void);
	__declspec(dllexport) int  AeronBridge_GetMessage(char* buffer, int bufferLen);
	__declspec(dllexport) void AeronBridge_Stop(void);
	__declspec(dllexport) int AeronBridge_LastError(char* buffer, int bufferLen);

#ifdef __cplusplus
}
#endif
