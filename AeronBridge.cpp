// AeronBridge.cpp — FINAL (C API ONLY)

#include "AeronBridge.h"

#include <aeron_client.h>
#include <aeronc.h>
#include <aeron_context.h>
#include <aeron_subscription.h>

#include <atomic>
#include <mutex>
#include <string>
#include <cstring>
#include <thread>
#include <chrono>

#include <windows.h>



// ===============================
// Globals
// ===============================

static aeron_context_t* g_context = nullptr;
static aeron_t* g_aeron = nullptr;
static aeron_async_add_subscription_t* g_asyncSubscription = nullptr;
static aeron_subscription_t* g_subscription = nullptr;

static std::atomic<int>        g_started{ 0 };
static std::atomic<int>        g_hasMessage{ 0 };

static std::string             g_lastError;
static std::string             g_lastMessage;
static std::mutex              g_msgMutex;

// ===============================
// Helpers
// ===============================

static void setError(const char* msg)
{
    g_lastError = msg ? msg : "unknown";
}

static void setErrorFromAeron()
{
    setError(aeron_errmsg());
}

static std::string WideToUtf8(const wchar_t* w)
{
    if (!w) return {};

    int len = WideCharToMultiByte(
        CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);

    if (len <= 0) return {};

    std::string out(len - 1, '\0');

    WideCharToMultiByte(
        CP_UTF8, 0, w, -1,
        &out[0], len,
        nullptr, nullptr);

    return out;
}

static bool isValidChannel(const std::string& channel, std::string& outReason)
{
    if (channel.empty())
    {
        outReason = "Channel is empty";
        return false;
    }

    if (!*channel.c_str())
    {
        outReason = "Channel is empty string";
        return false;
    }

    // Must start with aeron:
    if (strncmp(channel.c_str(), "aeron:", 6) != 0)
    {
        outReason = "Channel must start with 'aeron:' but got: '";
        outReason += channel;
        outReason += "'";
        return false;
    }

    return true; // Let Aeron do the real validation
}





// ===============================
// Fragment Handler (C API)
// ===============================

static void onFragment(
    void* clientd,
    const uint8_t* buffer,
    size_t length,
    aeron_header_t* /*header*/)
{
    if (!buffer || length == 0)
        return;

    std::lock_guard<std::mutex> lock(g_msgMutex);
    g_lastMessage.assign(reinterpret_cast<const char*>(buffer), length);
    g_hasMessage.store(1, std::memory_order_release);
}

// ===============================
// DLL API
// ===============================

extern "C" __declspec(dllexport)
int AeronBridge_Start(
    const wchar_t* aeronDirW,
    const wchar_t* channelW,
    int streamId,
    int timeoutMs)
{
    std::string aeronDir = WideToUtf8(aeronDirW);
    std::string channel = WideToUtf8(channelW);

    //if (channel.rfind("aeron:", 0) != 0)
    //{
    //    setError(("Invalid Aeron channel: " + channel).c_str());
    //    return 0;
    //}

    aeron_context_set_dir(g_context, aeronDir.c_str());
    if (g_started.load())
        return 1;

    std::string channelError;
    if (!isValidChannel(channel, channelError))
    {
        std::string errorMsg = "Invalid Aeron channel in AeronBridge_Start: ";
        errorMsg += channelError;
        setError(errorMsg.c_str());
        return 0;
    }


    if (streamId <= 0)
    {
        setError("Invalid streamId (must be > 0)");
        return 0;
    }

    if (aeron_context_init(&g_context) < 0)
    {
        setErrorFromAeron();
        return 0;
    }

    if (!aeronDir.empty())
        aeron_context_set_dir(g_context, aeronDir.c_str());

    if (aeron_init(&g_aeron, g_context) < 0)
    {
        setErrorFromAeron();
        return 0;
    }

    if (aeron_start(g_aeron) < 0)
    {
        setErrorFromAeron();
        return 0;
    }

    // ---- subscribe immediately (important for MT5 UX)
    if (!AeronBridge_Subscribe(channelW, streamId, timeoutMs))
        return 0;

    g_started.store(1);
    return 1;
}



extern "C" __declspec(dllexport)
int AeronBridge_Subscribe(
    const wchar_t* channelW,
    int streamId,
    int timeoutMs)
{
    if (!g_aeron)
    {
        setError("Aeron not started");
        return 0;
    }
    std::string channel = WideToUtf8(channelW);

    if (aeron_async_add_subscription(
        &g_asyncSubscription,
        g_aeron,
        channel.c_str(),
        streamId,
        nullptr, nullptr,
        nullptr, nullptr) < 0)
    {
        setErrorFromAeron();
        return 0;
    }

    auto start = std::chrono::steady_clock::now();

    while (true)
    {
        int rc = aeron_async_add_subscription_poll(
            &g_subscription,
            g_asyncSubscription);

        if (rc > 0)
            return 1;

        if (rc < 0)
        {
            setErrorFromAeron();
            return 0;
        }

        auto elapsed =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - start)
            .count();

        if (elapsed > timeoutMs)
        {
            setError("Aeron subscribe timeout (Media Driver not running?)");
            return 0;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}


extern "C" __declspec(dllexport)
int AeronBridge_Poll()
{
    if (!g_subscription)
        return 0;

    return (int)aeron_subscription_poll(
        g_subscription,
        onFragment,
        nullptr,
        10 /* fragment limit */
    );
}

extern "C" __declspec(dllexport)
int AeronBridge_HasMessage()
{
    return g_hasMessage.load(std::memory_order_acquire);
}

extern "C" __declspec(dllexport)
int AeronBridge_GetMessage(char* buffer, int bufferLen)
{
    if (!buffer || bufferLen <= 0)
        return 0;

    if (!g_hasMessage.load())
        return 0;

    std::lock_guard<std::mutex> lock(g_msgMutex);

    int copyLen = (int)g_lastMessage.size();
    if (copyLen >= bufferLen)
        copyLen = bufferLen - 1;

    memcpy(buffer, g_lastMessage.data(), copyLen);
    buffer[copyLen] = '\0';

    g_hasMessage.store(0, std::memory_order_release);
    return copyLen;
}

extern "C" __declspec(dllexport)
void AeronBridge_Stop()
{
    if (g_subscription)
    {
        aeron_subscription_close(g_subscription, nullptr, nullptr);
        g_subscription = nullptr;
    }

    if (g_aeron)
    {
        aeron_close(g_aeron);
        g_aeron = nullptr;
    }

    if (g_context)
    {
        aeron_context_close(g_context);
        g_context = nullptr;
    }

    g_started.store(0);
    g_hasMessage.store(0);
}

extern "C" __declspec(dllexport)
int AeronBridge_LastError(char* buffer, int bufferLen)
{
    if (!buffer || bufferLen <= 0)
        return 0;

    int len = (int)g_lastError.size();
    if (len >= bufferLen)
        len = bufferLen - 1;

    memcpy(buffer, g_lastError.data(), len);
    buffer[len] = '\0';
    return len;
}

