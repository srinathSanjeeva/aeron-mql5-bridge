// AeronBridge.cpp — MT5 Subscriber Bridge (C API) + binary decode + mapping + tick conversion

#include "AeronBridge.h"

#include <aeron_client.h>
#include <aeronc.h>
#include <aeron_context.h>
#include <aeron_subscription.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

// ===============================
// Protocol (must match publisher)
// ===============================
// From AeronSignalPublisher.cs / AeronSignalAddon.cs 
static constexpr uint32_t MAGIC = 0xA330BEEF;
static constexpr uint16_t VERSION = 1;
static constexpr int FRAME_SIZE = 104;

static constexpr int MAGIC_OFFSET = 0;        // int32
static constexpr int VERSION_OFFSET = 4;      // int16
static constexpr int ACTION_OFFSET = 6;       // int16
static constexpr int TIMESTAMP_OFFSET = 8;    // int64 (ns-ish)
static constexpr int LONG_SL_OFFSET = 16;     // int32
static constexpr int SHORT_SL_OFFSET = 20;    // int32
static constexpr int PROFIT_TARGET_OFFSET = 24;// int32
static constexpr int QTY_OFFSET = 28;         // int32
static constexpr int CONFIDENCE_OFFSET = 32;  // float32
static constexpr int SYMBOL_OFFSET = 36;      // char[16]
static constexpr int INSTRUMENT_OFFSET = 52;  // char[32]
static constexpr int SOURCE_OFFSET = 84;      // char[16]

static constexpr int SYMBOL_LEN = 16;
static constexpr int INSTRUMENT_LEN = 32;
static constexpr int SOURCE_LEN = 16;

// ===============================
// Globals
// ===============================
static aeron_context_t* g_context = nullptr;
static aeron_t* g_aeron = nullptr;
static aeron_async_add_subscription_t* g_asyncSub = nullptr;
static aeron_subscription_t* g_subscription = nullptr;

static std::atomic<int> g_started{ 0 };

// last error (UTF-8)
static std::mutex  g_errMutex;
static std::string g_lastError;

// last valid signal CSV
static std::mutex  g_sigMutex;
static std::string g_lastSignalCsv;
static std::atomic<int> g_hasSignal{ 0 };

// Instrument mapping + conversion config
struct InstMap
{
    std::string mt5Symbol;   // e.g. "SPX500"
    double futTickSize;      // e.g. 0.25
    double mt5PointSize;     // e.g. 0.1 (broker-specific)
};

static std::mutex g_mapMutex;
static std::unordered_map<std::string, InstMap> g_map;

// ===============================
// Helpers
// ===============================
static void setErrorLocked(const std::string& s)
{
    g_lastError = s;
}

static void setError(const std::string& s)
{
    std::lock_guard<std::mutex> lock(g_errMutex);
    setErrorLocked(s);
}

static void setErrorFromAeron(const char* prefix)
{
    const char* e = aeron_errmsg();
    std::string msg = prefix ? std::string(prefix) : std::string("Aeron error");
    msg += ": ";
    msg += (e ? e : "unknown");
    setError(msg);
}

static inline uint16_t rd_u16_le(const uint8_t* p)
{
    return (uint16_t)(p[0] | (p[1] << 8));
}

static inline uint32_t rd_u32_le(const uint8_t* p)
{
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
}

static inline int32_t rd_i32_le(const uint8_t* p)
{
    return (int32_t)rd_u32_le(p);
}

static inline int64_t rd_i64_le(const uint8_t* p)
{
    uint64_t v =
        (uint64_t)p[0] |
        ((uint64_t)p[1] << 8) |
        ((uint64_t)p[2] << 16) |
        ((uint64_t)p[3] << 24) |
        ((uint64_t)p[4] << 32) |
        ((uint64_t)p[5] << 40) |
        ((uint64_t)p[6] << 48) |
        ((uint64_t)p[7] << 56);
    return (int64_t)v;
}

static inline float rd_f32_le(const uint8_t* p)
{
    uint32_t u = rd_u32_le(p);
    float f;
    std::memcpy(&f, &u, sizeof(float));
    return f;
}

static std::string read_ascii_trim0(const uint8_t* p, int len)
{
    int end = 0;
    for (int i = 0; i < len; i++)
    {
        if (p[i] == 0) break;
        end++;
    }
    return std::string((const char*)p, (size_t)end);
}

static std::string wide_to_utf8(const wchar_t* w)
{
    if (!w) return {};
    int lenW = (int)wcslen(w);
    if (lenW == 0) return {};

    // Windows UTF-16 -> UTF-8
    int needed = WideCharToMultiByte(CP_UTF8, 0, w, lenW, nullptr, 0, nullptr, nullptr);
    if (needed <= 0) return {};
    std::string out;
    out.resize((size_t)needed);
    WideCharToMultiByte(CP_UTF8, 0, w, lenW, &out[0], needed, nullptr, nullptr);
    return out;
}

static bool channelLooksValid(const std::string& ch)
{
    // Basic check: must start with "aeron:" like you already want.
    return ch.rfind("aeron:", 0) == 0;
}

static std::string futPrefixFromInstrument(const std::string& instrument)
{
    // "ES MAR26" -> "ES"
    // "NQ MAR26" -> "NQ"
    auto pos = instrument.find(' ');
    if (pos == std::string::npos) return instrument;
    return instrument.substr(0, pos);
}

static int ticksToMt5Points(int ticks, const InstMap& m)
{
    // priceMove = ticks * futTickSize
    // mt5Points = priceMove / mt5PointSize
    if (ticks <= 0) return 0;
    if (m.futTickSize <= 0.0 || m.mt5PointSize <= 0.0) return 0;
    double priceMove = (double)ticks * m.futTickSize;
    double pts = priceMove / m.mt5PointSize;
    // round to nearest int (safer than trunc)
    if (pts < 0) pts = 0;
    return (int)(pts + 0.5);
}

static void ensureDefaultMap()
{
    std::lock_guard<std::mutex> lock(g_mapMutex);
    if (!g_map.empty()) return;

    // Defaults (adjust/override from MQL5 via AeronBridge_RegisterInstrumentMapW)
    // Example asked: ES -> SPX500
    g_map["ES"] = InstMap{ "SPX500", 0.25, 0.1 };
    // Common: NQ -> NAS100
    g_map["NQ"] = InstMap{ "NAS100", 0.25, 0.1 };
}

// ===============================
// Fragment handler
// ===============================
static void onFragment(
    void* /*clientd*/,
    const uint8_t* buffer,
    size_t length,
    aeron_header_t* /*header*/)
{
    if (!buffer || length < (size_t)FRAME_SIZE) return;

    // Validate MAGIC + VERSION
    const uint32_t magic = rd_u32_le(buffer + MAGIC_OFFSET);
    if (magic != MAGIC) return;

    const uint16_t ver = rd_u16_le(buffer + VERSION_OFFSET);
    if (ver != VERSION) return;

    const uint16_t action = rd_u16_le(buffer + ACTION_OFFSET);

    // Ignore exits as per your requirement (5,6)
    if (action == 5 || action == 6) return;

    const int32_t longSL = rd_i32_le(buffer + LONG_SL_OFFSET);
    const int32_t shortSL = rd_i32_le(buffer + SHORT_SL_OFFSET);
    const int32_t pt = rd_i32_le(buffer + PROFIT_TARGET_OFFSET);
    const int32_t qty = rd_i32_le(buffer + QTY_OFFSET);
    const float confidence = rd_f32_le(buffer + CONFIDENCE_OFFSET);

    const std::string sym = read_ascii_trim0(buffer + SYMBOL_OFFSET, SYMBOL_LEN);
    const std::string inst = read_ascii_trim0(buffer + INSTRUMENT_OFFSET, INSTRUMENT_LEN);
    const std::string src = read_ascii_trim0(buffer + SOURCE_OFFSET, SOURCE_LEN);

    // Determine relevant SL based on direction:
    // action 1/2 = long entries => use longSL
    // action 3/4 = short entries => use shortSL
    int slTicks = 0;
    if (action == 1 || action == 2) slTicks = longSL;
    else if (action == 3 || action == 4) slTicks = shortSL;

    ensureDefaultMap();

    const std::string prefix = futPrefixFromInstrument(inst);

    InstMap map;
    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        auto it = g_map.find(prefix);
        if (it == g_map.end())
        {
            // Reject unknown instruments (safe)
            return;
        }
        map = it->second;
    }

    const int slPoints = ticksToMt5Points(slTicks, map);
    const int ptPoints = ticksToMt5Points(pt, map);

    // Build CSV
    // action,qty,sl_points,pt_points,confidence,symbol,mt5_symbol,source,instrument
    char csv[512];
    std::snprintf(
        csv, sizeof(csv),
        "%u,%d,%d,%d,%.2f,%s,%s,%s,%s",
        (unsigned)action,
        (int)qty,
        (int)slPoints,
        (int)ptPoints,
        (double)confidence,
        sym.c_str(),
        map.mt5Symbol.c_str(),
        src.c_str(),
        inst.c_str());

    {
        std::lock_guard<std::mutex> lock(g_sigMutex);
        g_lastSignalCsv = csv;
        g_hasSignal.store(1, std::memory_order_release);
    }
}

// ===============================
// Exported API
// ===============================
int AeronBridge_StartW(const wchar_t* aeronDirW, const wchar_t* channelW, int streamId, int timeoutMs)
{
    if (g_started.load()) return 1;

    const std::string aeronDir = wide_to_utf8(aeronDirW);
    const std::string channel = wide_to_utf8(channelW);

    if (!channelLooksValid(channel))
    {
        setError("Invalid Aeron channel: must start with 'aeron:'");
        return 0;
    }
    if (streamId <= 0)
    {
        setError("Invalid streamId: must be > 0");
        return 0;
    }
    if (timeoutMs <= 0) timeoutMs = 3000;

    ensureDefaultMap();

    if (aeron_context_init(&g_context) < 0)
    {
        setErrorFromAeron("aeron_context_init failed");
        return 0;
    }

    if (!aeronDir.empty())
    {
        aeron_context_set_dir(g_context, aeronDir.c_str());
    }

    if (aeron_init(&g_aeron, g_context) < 0)
    {
        setErrorFromAeron("aeron_init failed");
        return 0;
    }

    if (aeron_start(g_aeron) < 0)
    {
        setErrorFromAeron("aeron_start failed");
        return 0;
    }

    // Subscribe async + timeout
    if (aeron_async_add_subscription(
        &g_asyncSub,
        g_aeron,
        channel.c_str(),
        streamId,
        nullptr, nullptr, nullptr, nullptr) < 0)
    {
        setErrorFromAeron("aeron_async_add_subscription failed");
        return 0;
    }

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);

    int pollRes = 0;
    while (true)
    {
        pollRes = aeron_async_add_subscription_poll(&g_subscription, g_asyncSub);
        if (pollRes < 0)
        {
            setErrorFromAeron("aeron_async_add_subscription_poll failed");
            g_asyncSub = nullptr;
            return 0;
        }
        if (pollRes > 0)
        {
            // Ready
            break;
        }

        if (std::chrono::steady_clock::now() >= deadline)
        {
            setError("Subscribe timeout: MediaDriver down or channel/stream mismatch");
            g_asyncSub = nullptr;
            return 0;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    g_started.store(1);
    return 1;
}

int AeronBridge_RegisterInstrumentMapW(
    const wchar_t* futPrefixW,
    const wchar_t* mt5SymbolW,
    double futTickSize,
    double mt5PointSize)
{
    const std::string futPrefix = wide_to_utf8(futPrefixW);
    const std::string mt5Symbol = wide_to_utf8(mt5SymbolW);

    if (futPrefix.empty() || mt5Symbol.empty())
    {
        setError("RegisterInstrumentMap: futPrefix/mt5Symbol cannot be empty");
        return 0;
    }
    if (futTickSize <= 0.0 || mt5PointSize <= 0.0)
    {
        setError("RegisterInstrumentMap: tick/point sizes must be > 0");
        return 0;
    }

    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        g_map[futPrefix] = InstMap{ mt5Symbol, futTickSize, mt5PointSize };
    }

    return 1;
}

int AeronBridge_Poll()
{
    if (!g_subscription) return 0;

    return (int)aeron_subscription_poll(
        g_subscription,
        onFragment,
        nullptr,
        10);
}

int AeronBridge_HasSignal()
{
    return g_hasSignal.load(std::memory_order_acquire);
}

int AeronBridge_GetSignalCsv(unsigned char* outBuf, int outBufLen)
{
    if (!outBuf || outBufLen <= 1) return 0;
    if (!g_hasSignal.load(std::memory_order_acquire)) return 0;

    std::lock_guard<std::mutex> lock(g_sigMutex);
    if (g_lastSignalCsv.empty()) return 0;

    const int n = (int)g_lastSignalCsv.size();
    const int copyN = (n >= outBufLen) ? (outBufLen - 1) : n;

    std::memcpy(outBuf, g_lastSignalCsv.data(), (size_t)copyN);
    outBuf[copyN] = 0;

    g_hasSignal.store(0, std::memory_order_release);
    return copyN;
}

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

    g_asyncSub = nullptr;
    g_started.store(0);
    g_hasSignal.store(0);

    {
        std::lock_guard<std::mutex> lock(g_sigMutex);
        g_lastSignalCsv.clear();
    }
}

int AeronBridge_LastError(unsigned char* outBuf, int outBufLen)
{
    if (!outBuf || outBufLen <= 1) return 0;

    std::lock_guard<std::mutex> lock(g_errMutex);
    const int n = (int)g_lastError.size();
    const int copyN = (n >= outBufLen) ? (outBufLen - 1) : n;

    std::memcpy(outBuf, g_lastError.data(), (size_t)copyN);
    outBuf[copyN] = 0;
    return copyN;
}
