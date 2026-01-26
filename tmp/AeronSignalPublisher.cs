#region Using declarations
using System;
using System.Collections.Generic;
using Adaptive.Aeron;
using Adaptive.Agrona;
using Adaptive.Agrona.Concurrent;
#endregion

namespace NinjaTrader.NinjaScript.Common
{
    /// <summary>
    /// Trading window with start and end times for a specific day
    /// </summary>
    public class TradingWindow
    {
        public string start { get; set; }
        public string end { get; set; }
    }

    /// <summary>
    /// API response containing weekly trading hours schedule
    /// </summary>
    public class TradingHoursResponse
    {
        public string symbol { get; set; }
        public string timezone { get; set; }
        public Dictionary<string, TradingWindow> weekly_schedule { get; set; }
    }

    public enum AeronPublishMode
    {
        None,
        IpcOnly,
        UdpOnly,
        IpcAndUdp
    }
    /// <summary>
    /// Enum representing trading strategy actions for Aeron signal broadcasting
    /// </summary>
    public enum StrategyAction : ushort
    {
        LongEntry1 = 1,
        LongEntry2 = 2,
        ShortEntry1 = 3,
        ShortEntry2 = 4,
        LongExit = 5,
        ShortExit = 6,
        LongStopLoss = 7,
        ShortStopLoss = 8,
        ProfitTarget = 9
    }

    /// <summary>
    /// Low-latency Aeron signal publisher for broadcasting trading signals
    /// Uses a fixed 104-byte binary protocol for ultra-fast message serialization
    /// </summary>
    public sealed class AeronSignalPublisher : IDisposable
    {
        private readonly string aeronDirectory;

        // Protocol constants
        private const uint MAGIC = 0xA330BEEF;
        private const ushort VERSION = 1;
        private const int FRAME_SIZE = 104;

        // Fixed-length string field sizes
        private const int SYMBOL_LEN = 16;
        private const int INSTRUMENT_LEN = 32;
        private const int SOURCE_LEN = 16;

        private readonly UnsafeBuffer buffer;
        private readonly byte[] backing = new byte[FRAME_SIZE];

        private readonly string channel;
        private readonly int streamId;
        private readonly string source;
        private readonly Action<string> log;

        private Aeron aeron;
        private Publication publication;

        private static readonly DateTime UnixEpochUtc =
            new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        /// <summary>
        /// Creates a new AeronSignalPublisher instance
        /// </summary>
        /// <param name="aeronDirectory">Optional custom Aeron directory (empty for default)</param>
        /// <param name="channel">Aeron channel URI (e.g., "aeron:udp?endpoint=127.0.0.1:40123")</param>
        /// <param name="streamId">Unique stream identifier</param>
        /// <param name="source">Source strategy tag for signal identification</param>
        /// <param name="log">Optional logging action</param>
        public AeronSignalPublisher(
            string aeronDirectory,
            string channel,
            int streamId,
            string source,
            Action<string> log)
        {
            this.aeronDirectory = aeronDirectory;
            this.channel = channel;
            this.streamId = streamId;
            this.source = source;
            this.log = log ?? (_ => { });
            buffer = new UnsafeBuffer(backing);
        }

        /// <summary>
        /// Starts the Aeron publisher and establishes the publication channel
        /// </summary>
        public void Start()
        {
            var ctx = new Aeron.Context();

            if (!string.IsNullOrWhiteSpace(aeronDirectory))
            {
                ctx.AeronDirectoryName(aeronDirectory);
            }

            aeron = Aeron.Connect(ctx);

            publication = aeron.AddPublication(channel, streamId);
            log($"[Aeron] Started | channel={channel}, streamId={streamId}");
        }

        /// <summary>
        /// Publishes a trading signal to the Aeron channel
        /// </summary>
        /// <param name="symbol">Instrument symbol (e.g., "ES", "NQ")</param>
        /// <param name="instrument">Full instrument name</param>
        /// <param name="action">Trading action type</param>
        /// <param name="longSL">Stop loss for long positions (in ticks)</param>
        /// <param name="shortSL">Stop loss for short positions (in ticks)</param>
        /// <param name="profitTarget">Profit target (in ticks)</param>
        /// <param name="qty">Position quantity</param>
        /// <param name="confidence">Signal confidence metric (0-100)</param>
        public void TryPublish(
            string symbol,
            string instrument,
            StrategyAction action,
            int longSL,
            int shortSL,
            int profitTarget,
            int qty,
            float confidence)
        {
            Encode(symbol, instrument, action, longSL, shortSL, profitTarget, qty, confidence);
            publication?.Offer(buffer, 0, FRAME_SIZE);
        }

        /// <summary>
        /// Encodes the signal into binary format
        /// Frame structure (104 bytes total):
        /// - MAGIC (4 bytes)
        /// - VERSION (2 bytes)
        /// - ACTION (2 bytes)
        /// - TIMESTAMP (8 bytes)
        /// - LONG_SL (4 bytes)
        /// - SHORT_SL (4 bytes)
        /// - PROFIT_TARGET (4 bytes)
        /// - QTY (4 bytes)
        /// - CONFIDENCE (4 bytes)
        /// - SYMBOL (16 bytes)
        /// - INSTRUMENT (32 bytes)
        /// - SOURCE (16 bytes)
        /// </summary>
        private void Encode(
            string symbol,
            string instrument,
            StrategyAction action,
            int longSL,
            int shortSL,
            int profitTarget,
            int qty,
            float confidence)
        {
            int o = 0;

            buffer.PutInt(o, unchecked((int)MAGIC));
            o += 4;

            buffer.PutShort(o, (short)VERSION); o += 2;
            buffer.PutShort(o, (short)action); o += 2;
            buffer.PutLong(o, (DateTime.UtcNow - UnixEpochUtc).Ticks * 100); o += 8;

            buffer.PutInt(o, longSL); o += 4;
            buffer.PutInt(o, shortSL); o += 4;
            buffer.PutInt(o, profitTarget); o += 4;
            buffer.PutInt(o, qty); o += 4;
            buffer.PutFloat(o, confidence); o += 4;

            PutAscii(o, symbol, SYMBOL_LEN); o += SYMBOL_LEN;
            PutAscii(o, instrument, INSTRUMENT_LEN); o += INSTRUMENT_LEN;
            PutAscii(o, source, SOURCE_LEN);
        }

        /// <summary>
        /// Writes an ASCII string to the buffer with zero-padding
        /// </summary>
        private void PutAscii(int offset, string value, int len)
        {
            for (int i = 0; i < len; i++)
                buffer.PutByte(offset + i, 0);

            if (string.IsNullOrEmpty(value)) return;

            for (int i = 0; i < Math.Min(len, value.Length); i++)
                buffer.PutByte(offset + i, (byte)(value[i] <= 127 ? value[i] : '?'));
        }

        /// <summary>
        /// Disposes of Aeron resources
        /// </summary>
        public void Dispose()
        {
            publication?.Dispose();
            aeron?.Dispose();
        }
    }
}
