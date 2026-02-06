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
#include <queue>

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

// Signal queue (instead of single slot)
static std::mutex  g_sigMutex;
static std::queue<std::string> g_signalQueue;
static constexpr size_t MAX_QUEUE_SIZE = 100;  // Prevent unbounded growth

// Instrument mapping + conversion config
struct InstMap
{
    std::string mt5Symbol;   // e.g. "SPX500"
    double futTickSize;      // e.g. 0.25
    double mt5PointSize;     // e.g. 0.1 (broker-specific)
};

static std::mutex g_mapMutex;
static std::unordered_map<std::string, InstMap> g_map;

// Unmapped symbol behavior
static std::atomic<int> g_allowUnmapped{ 0 };
static double g_defaultTickSize = 0.01;
static double g_defaultPointSize = 0.01;

// ===============================
// Publisher (Aeron Producer) Globals
// ===============================
// Dual publisher support for IPC and UDP
static aeron_async_add_publication_t* g_asyncPubIpc = nullptr;
static aeron_publication_t* g_publicationIpc = nullptr;
static std::atomic<int> g_pubIpcStarted{ 0 };

static aeron_async_add_publication_t* g_asyncPubUdp = nullptr;
static aeron_publication_t* g_publicationUdp = nullptr;
static std::atomic<int> g_pubUdpStarted{ 0 };

// Legacy single publisher (kept for backward compatibility)
static aeron_async_add_publication_t* g_asyncPub = nullptr;
static aeron_publication_t* g_publication = nullptr;
static std::atomic<int> g_pubStarted{ 0 };

// ===============================
// Helpers
// ===============================
static void cleanupAeronContextIfIdle();  // forward declaration

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

    // ==================================================================================
    // BROKER-SPECIFIC MAPPINGS: Audacity Capital
    // ==================================================================================
    // Instrument Mappings: NT Futures -> MT5 CFD Symbol
    // futTickSize: NinjaTrader tick value (price movement per tick)
    // mt5PointSize: MT5 broker's _Point value (minimum price change)
    //
    // Conversion Formula: MT5_Points = (NT_Ticks × futTickSize) ÷ mt5PointSize
    //
    // ES (E-mini S&P 500):
    //   - NT: 0.25 per tick | MT5 Symbol: SPX500 | MT5 _Point: 0.1
    //   - Example: 50 ticks → (50 × 0.25) ÷ 0.1 = 125 MT5 points = 12.5 price units
    g_map["ES"] = InstMap{ "SPX500", 0.25, 0.1 };
    
    // NQ (E-mini Nasdaq-100):
    //   - NT: 0.25 per tick | MT5 Symbol: TECH100 | MT5 _Point: 0.1
    //   - Example: 85 ticks → (85 × 0.25) ÷ 0.1 = 212.5 MT5 points = 21.25 price units
    //   - Desired: 85 ticks → 25.0 price units (adjusted futTickSize to match)
    g_map["NQ"] = InstMap{ "TECH100", 0.25, 0.1 };
    
    // YM (E-mini Dow):
    //   - NT: 1.0 per tick | MT5 Symbol: DJ30 | MT5 _Point: 0.01
    //   - Example: 50 ticks → (50 × 1.0) ÷ 0.01 = 5000 MT5 points = 50.0 price units
    g_map["YM"] = InstMap{ "DJ30", 1.0, 0.1 };
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
    bool isMapped = false;
    {
        std::lock_guard<std::mutex> lock(g_mapMutex);
        auto it = g_map.find(prefix);
        if (it == g_map.end())
        {
            // Unknown instrument prefix
            if (g_allowUnmapped.load())
            {
                // Pass-through mode: use prefix as symbol with default conversion
                map.mt5Symbol = prefix;
                map.futTickSize = g_defaultTickSize;
                map.mt5PointSize = g_defaultPointSize;
                isMapped = false;  // Mark as unmapped for logging
            }
            else
            {
                // Strict mode: reject unknown instruments
                std::string msg = "DROPPED SIGNAL: Unknown instrument prefix '" + prefix + "' from instrument '" + inst + "'. Register mapping via AeronBridge_RegisterInstrumentMapW() or enable pass-through with AeronBridge_SetUnmappedBehaviorW()";
                setError(msg);
                return;
            }
        }
        else
        {
            map = it->second;
            isMapped = true;
        }
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
        // Queue the signal instead of overwriting
        if (g_signalQueue.size() < MAX_QUEUE_SIZE)
        {
            g_signalQueue.push(std::string(csv));
        }
        // else: drop oldest or newest - here we drop newest if full
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
    std::lock_guard<std::mutex> lock(g_sigMutex);
    return g_signalQueue.empty() ? 0 : 1;
}

int AeronBridge_GetSignalCsv(unsigned char* outBuf, int outBufLen)
{
    if (!outBuf || outBufLen <= 1) return 0;

    std::lock_guard<std::mutex> lock(g_sigMutex);
    if (g_signalQueue.empty()) return 0;

    const std::string& csv = g_signalQueue.front();
    const int n = (int)csv.size();
    const int copyN = (n >= outBufLen) ? (outBufLen - 1) : n;

    std::memcpy(outBuf, csv.data(), (size_t)copyN);
    outBuf[copyN] = 0;

    g_signalQueue.pop();  // Remove from queue after reading
    return copyN;
}

void AeronBridge_Stop()
{
    if (g_subscription)
    {
        aeron_subscription_close(g_subscription, nullptr, nullptr);
        g_subscription = nullptr;
    }

    g_asyncSub = nullptr;
    g_started.store(0);

    {
        std::lock_guard<std::mutex> lock(g_sigMutex);
        // Clear the queue
        while (!g_signalQueue.empty())
            g_signalQueue.pop();
    }

    // Only close shared context if no publishers are still active
    cleanupAeronContextIfIdle();
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

int AeronBridge_SetUnmappedBehaviorW(
    int allowUnmapped,
    double defaultTickSize,
    double defaultPointSize)
{
    if (defaultTickSize <= 0.0 || defaultPointSize <= 0.0)
    {
        setError("SetUnmappedBehavior: tick/point sizes must be > 0");
        return 0;
    }

    g_allowUnmapped.store(allowUnmapped ? 1 : 0);
    g_defaultTickSize = defaultTickSize;
    g_defaultPointSize = defaultPointSize;

    return 1;
}

// ===============================
// Publisher API Implementation
// ===============================

int AeronBridge_StartPublisherW(
    const wchar_t* aeronDirW,
    const wchar_t* channelW,
    int streamId,
    int timeoutMs)
{
    if (g_pubStarted.load()) return 1;

    const std::string aeronDir = wide_to_utf8(aeronDirW);
    const std::string channel = wide_to_utf8(channelW);

    if (!channelLooksValid(channel))
    {
        setError("Invalid Aeron publisher channel: must start with 'aeron:'");
        return 0;
    }
    if (streamId <= 0)
    {
        setError("Invalid publisher streamId: must be > 0");
        return 0;
    }
    if (timeoutMs <= 0) timeoutMs = 3000;

    // Initialize Aeron context if not already done (might be shared with subscriber)
    if (!g_aeron)
    {
        if (aeron_context_init(&g_context) < 0)
        {
            setErrorFromAeron("aeron_context_init failed (publisher)");
            return 0;
        }

        if (!aeronDir.empty())
        {
            aeron_context_set_dir(g_context, aeronDir.c_str());
        }

        if (aeron_init(&g_aeron, g_context) < 0)
        {
            setErrorFromAeron("aeron_init failed (publisher)");
            return 0;
        }

        if (aeron_start(g_aeron) < 0)
        {
            setErrorFromAeron("aeron_start failed (publisher)");
            return 0;
        }
    }

    // Add publication async
    if (aeron_async_add_publication(
        &g_asyncPub,
        g_aeron,
        channel.c_str(),
        streamId) < 0)
    {
        setErrorFromAeron("aeron_async_add_publication failed");
        return 0;
    }

    // Wait for publication to be ready
    const auto deadline = std::chrono::steady_clock::now() + 
                         std::chrono::milliseconds(timeoutMs);
    
    int pollRes = 0;
    while (true)
    {
        pollRes = aeron_async_add_publication_poll(&g_publication, g_asyncPub);
        if (pollRes < 0)
        {
            setErrorFromAeron("aeron_async_add_publication_poll failed");
            g_asyncPub = nullptr;
            return 0;
        }
        if (pollRes > 0)
        {
            break;  // Ready
        }

        if (std::chrono::steady_clock::now() >= deadline)
        {
            setError("Publication timeout: MediaDriver down or channel issue");
            g_asyncPub = nullptr;
            return 0;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    g_pubStarted.store(1);
    return 1;
}

int AeronBridge_PublishBinary(const unsigned char* buffer, int bufferLen)
{
    if (!g_publication)
    {
        setError("Publication not initialized");
        return 0;
    }

    if (!buffer || bufferLen != FRAME_SIZE)
    {
        setError("PublishBinary: buffer must be exactly 104 bytes");
        return 0;
    }

    // Attempt to offer the message
    int64_t result = aeron_publication_offer(
        g_publication,
        (const uint8_t*)buffer,
        (size_t)bufferLen,
        nullptr,
        nullptr);

    if (result < 0)
    {
        if (result == AERON_PUBLICATION_NOT_CONNECTED)
        {
            setError("Publication not connected");
        }
        else if (result == AERON_PUBLICATION_BACK_PRESSURED)
        {
            setError("Publication back pressured");
        }
        else if (result == AERON_PUBLICATION_ADMIN_ACTION)
        {
            setError("Publication admin action");
        }
        else if (result == AERON_PUBLICATION_CLOSED)
        {
            setError("Publication closed");
        }
        else
        {
            setErrorFromAeron("aeron_publication_offer failed");
        }
        return 0;
    }

    return 1;  // Success
}

void AeronBridge_StopPublisher()
{
    if (g_publication)
    {
        aeron_publication_close(g_publication, nullptr, nullptr);
        g_publication = nullptr;
    }
    g_asyncPub = nullptr;
    g_pubStarted.store(0);

    cleanupAeronContextIfIdle();
}

// ===============================
// Dual Publisher API (IPC + UDP)
// ===============================

int AeronBridge_StartPublisherIpcW(
    const wchar_t* aeronDirW,
    const wchar_t* channelW,
    int streamId,
    int timeoutMs)
{
    if (g_pubIpcStarted.load()) return 1;

    const std::string aeronDir = wide_to_utf8(aeronDirW);
    const std::string channel = wide_to_utf8(channelW);

    if (!channelLooksValid(channel))
    {
        setError("Invalid Aeron IPC publisher channel: must start with 'aeron:'");
        return 0;
    }
    if (streamId <= 0)
    {
        setError("Invalid IPC publisher streamId: must be > 0");
        return 0;
    }
    if (timeoutMs <= 0) timeoutMs = 3000;

    // Initialize Aeron context if not already done
    if (!g_aeron)
    {
        if (aeron_context_init(&g_context) < 0)
        {
            setErrorFromAeron("aeron_context_init failed (IPC publisher)");
            return 0;
        }

        if (!aeronDir.empty())
        {
            aeron_context_set_dir(g_context, aeronDir.c_str());
        }

        if (aeron_init(&g_aeron, g_context) < 0)
        {
            setErrorFromAeron("aeron_init failed (IPC publisher)");
            return 0;
        }

        if (aeron_start(g_aeron) < 0)
        {
            setErrorFromAeron("aeron_start failed (IPC publisher)");
            return 0;
        }
    }

    // Add publication async
    if (aeron_async_add_publication(
        &g_asyncPubIpc,
        g_aeron,
        channel.c_str(),
        streamId) < 0)
    {
        setErrorFromAeron("aeron_async_add_publication failed (IPC)");
        return 0;
    }

    // Wait for publication to be ready
    const auto deadline = std::chrono::steady_clock::now() + 
                         std::chrono::milliseconds(timeoutMs);
    
    int pollRes = 0;
    while (true)
    {
        pollRes = aeron_async_add_publication_poll(&g_publicationIpc, g_asyncPubIpc);
        if (pollRes < 0)
        {
            setErrorFromAeron("aeron_async_add_publication_poll failed (IPC)");
            g_asyncPubIpc = nullptr;
            return 0;
        }
        if (pollRes > 0)
        {
            break;  // Ready
        }

        if (std::chrono::steady_clock::now() >= deadline)
        {
            setError("IPC Publication timeout: MediaDriver down or channel issue");
            g_asyncPubIpc = nullptr;
            return 0;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    g_pubIpcStarted.store(1);
    return 1;
}

int AeronBridge_StartPublisherUdpW(
    const wchar_t* aeronDirW,
    const wchar_t* channelW,
    int streamId,
    int timeoutMs)
{
    if (g_pubUdpStarted.load()) return 1;

    const std::string aeronDir = wide_to_utf8(aeronDirW);
    const std::string channel = wide_to_utf8(channelW);

    if (!channelLooksValid(channel))
    {
        setError("Invalid Aeron UDP publisher channel: must start with 'aeron:'");
        return 0;
    }
    if (streamId <= 0)
    {
        setError("Invalid UDP publisher streamId: must be > 0");
        return 0;
    }
    if (timeoutMs <= 0) timeoutMs = 3000;

    // Initialize Aeron context if not already done
    if (!g_aeron)
    {
        if (aeron_context_init(&g_context) < 0)
        {
            setErrorFromAeron("aeron_context_init failed (UDP publisher)");
            return 0;
        }

        if (!aeronDir.empty())
        {
            aeron_context_set_dir(g_context, aeronDir.c_str());
        }

        if (aeron_init(&g_aeron, g_context) < 0)
        {
            setErrorFromAeron("aeron_init failed (UDP publisher)");
            return 0;
        }

        if (aeron_start(g_aeron) < 0)
        {
            setErrorFromAeron("aeron_start failed (UDP publisher)");
            return 0;
        }
    }

    // Add publication async
    if (aeron_async_add_publication(
        &g_asyncPubUdp,
        g_aeron,
        channel.c_str(),
        streamId) < 0)
    {
        setErrorFromAeron("aeron_async_add_publication failed (UDP)");
        return 0;
    }

    // Wait for publication to be ready
    const auto deadline = std::chrono::steady_clock::now() + 
                         std::chrono::milliseconds(timeoutMs);
    
    int pollRes = 0;
    while (true)
    {
        pollRes = aeron_async_add_publication_poll(&g_publicationUdp, g_asyncPubUdp);
        if (pollRes < 0)
        {
            setErrorFromAeron("aeron_async_add_publication_poll failed (UDP)");
            g_asyncPubUdp = nullptr;
            return 0;
        }
        if (pollRes > 0)
        {
            break;  // Ready
        }

        if (std::chrono::steady_clock::now() >= deadline)
        {
            setError("UDP Publication timeout: MediaDriver down or channel issue");
            g_asyncPubUdp = nullptr;
            return 0;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    g_pubUdpStarted.store(1);
    return 1;
}

int AeronBridge_PublishBinaryIpc(const unsigned char* buffer, int bufferLen)
{
    if (!g_publicationIpc)
    {
        setError("IPC Publication not initialized");
        return 0;
    }

    if (!buffer || bufferLen != FRAME_SIZE)
    {
        setError("PublishBinaryIpc: buffer must be exactly 104 bytes");
        return 0;
    }

    int64_t result = aeron_publication_offer(
        g_publicationIpc,
        (const uint8_t*)buffer,
        (size_t)bufferLen,
        nullptr,
        nullptr);

    if (result < 0)
    {
        if (result == AERON_PUBLICATION_NOT_CONNECTED)
        {
            setError("IPC Publication not connected");
        }
        else if (result == AERON_PUBLICATION_BACK_PRESSURED)
        {
            setError("IPC Publication back pressured");
        }
        else if (result == AERON_PUBLICATION_ADMIN_ACTION)
        {
            setError("IPC Publication admin action");
        }
        else if (result == AERON_PUBLICATION_CLOSED)
        {
            setError("IPC Publication closed");
        }
        else
        {
            setErrorFromAeron("aeron_publication_offer failed (IPC)");
        }
        return 0;
    }

    return 1;
}

int AeronBridge_PublishBinaryUdp(const unsigned char* buffer, int bufferLen)
{
    if (!g_publicationUdp)
    {
        setError("UDP Publication not initialized");
        return 0;
    }

    if (!buffer || bufferLen != FRAME_SIZE)
    {
        setError("PublishBinaryUdp: buffer must be exactly 104 bytes");
        return 0;
    }

    int64_t result = aeron_publication_offer(
        g_publicationUdp,
        (const uint8_t*)buffer,
        (size_t)bufferLen,
        nullptr,
        nullptr);

    if (result < 0)
    {
        if (result == AERON_PUBLICATION_NOT_CONNECTED)
        {
            setError("UDP Publication not connected");
        }
        else if (result == AERON_PUBLICATION_BACK_PRESSURED)
        {
            setError("UDP Publication back pressured");
        }
        else if (result == AERON_PUBLICATION_ADMIN_ACTION)
        {
            setError("UDP Publication admin action");
        }
        else if (result == AERON_PUBLICATION_CLOSED)
        {
            setError("UDP Publication closed");
        }
        else
        {
            setErrorFromAeron("aeron_publication_offer failed (UDP)");
        }
        return 0;
    }

    return 1;
}

// Helper: clean up shared Aeron context when nothing is using it
static void cleanupAeronContextIfIdle()
{
    // Don't close if any publisher or subscriber is still active
    if (g_publicationIpc || g_publicationUdp || g_publication || g_subscription)
        return;

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
}

void AeronBridge_StopPublisherIpc()
{
    if (g_publicationIpc)
    {
        aeron_publication_close(g_publicationIpc, nullptr, nullptr);
        g_publicationIpc = nullptr;
    }
    g_asyncPubIpc = nullptr;
    g_pubIpcStarted.store(0);

    cleanupAeronContextIfIdle();
}

void AeronBridge_StopPublisherUdp()
{
    if (g_publicationUdp)
    {
        aeron_publication_close(g_publicationUdp, nullptr, nullptr);
        g_publicationUdp = nullptr;
    }
    g_asyncPubUdp = nullptr;
    g_pubUdpStarted.store(0);

    cleanupAeronContextIfIdle();
}
