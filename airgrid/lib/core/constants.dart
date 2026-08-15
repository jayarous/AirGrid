/// Globally shared constants for AirGrid.
class AirGridConstants {
  AirGridConstants._();

  /// Nearby Connections service identifier — must be unique to this app.
  static const String kServiceId = 'com.airgrid.mesh';

  /// Default hop limit (TTL) assigned to every new outgoing packet.
  static const int kHopLimit = 8;

  /// Maximum serialised packet size in bytes.
  ///
  /// This must be high enough to allow large private file envelopes to be
  /// encoded before they are split into fragment packets by [PacketFragmenter].
  static const int kMaxPacketBytes = 8 * 1024 * 1024;

  /// How long a message ID stays in the dedup cache before eviction.
  static const Duration kCacheTtl = Duration(hours: 2);

  /// Maximum number of message IDs to hold in the dedup cache.
  static const int kMaxCacheSize = 10000;

  /// Upper bound (exclusive) for the legacy fixed-jitter delay in milliseconds.
  /// Replaced by [RelayController] adaptive jitter for relayed packets.
  static const int kRebroadcastMaxDelayMs = 10;

  /// Encoded-packet size (bytes) above which a packet is fragmented before
  /// sending.
  static const int kFragmentThreshold = 4096;

  /// Time-to-live for store-and-forward spooled packets (seconds).
  static const int kSpoolTtlSeconds = 15;

  /// Maximum total number of entries across all recipients in the forward spool.
  static const int kSpoolMaxEntries = 20;

  /// Maximum number of concurrent in-flight fragment reassembly buckets.
  static const int kMaxReassemblyBuckets = 50;

  /// How long an incomplete reassembly bucket is kept before being discarded.
  static const Duration kReassemblyTtl = Duration(seconds: 30);

  /// Maximum total decoded fragment bytes kept across reassembly buckets.
  static const int kReassemblyMaxBytesInFlight = 16 * 1024 * 1024;

  /// Maximum compressed image payload bytes accepted for private photo sends.
  static const int kPrivatePhotoMaxBytes = 300 * 1024;

  /// Maximum in-flight image envelope bytes before rejecting decode.
  /// Keep this above kPrivatePhotoMaxBytes to absorb metadata and base64 overhead.
  static const int kPrivatePhotoMaxWireBytes = 450 * 1024;

  /// Maximum encoded voice-note payload bytes accepted for private sends.
  /// Keep conservative for current JSON+base64 attachment envelope.
  static const int kPrivateVoiceNoteMaxBytes = 180 * 1024;

  /// Maximum in-flight voice-note envelope bytes before rejecting decode.
  static const int kPrivateVoiceNoteMaxWireBytes = 280 * 1024;

  /// Maximum file attachment bytes accepted for private sends.
  ///
  /// Derived from [kMaxPacketBytes], not chosen independently. A private file
  /// is base64-encoded twice before the codec sees it — once into the JSON
  /// envelope and once by [CryptoService.encryptContent] — so the raw byte
  /// budget is roughly `kMaxPacketBytes / (4/3)^2`, minus envelope and AEAD
  /// overhead. At 4 MiB the worst-case packet content is ~7.1 MiB, inside the
  /// 8 MiB ceiling. Raising this without raising [kMaxPacketBytes] makes
  /// files unsendable; `mesh_service_oversize_file_test.dart` pins the
  /// invariant.
  static const int kPrivateFileMaxBytes = 4 * 1024 * 1024;

  /// Maximum in-flight file envelope bytes before rejecting decode.
  /// Sized above the base64-expanded [kPrivateFileMaxBytes] (~5.4 MiB).
  static const int kPrivateFileMaxWireBytes = 6 * 1024 * 1024;

  /// Minimum duration for a valid voice note.
  static const Duration kPrivateVoiceNoteMinDuration = Duration(seconds: 1);

  /// Maximum duration for a valid voice note.
  static const Duration kPrivateVoiceNoteMaxDuration = Duration(seconds: 45);

  /// Minimum duration for a walkie-talkie clip.
  static const Duration kWalkieMinDuration = Duration(milliseconds: 350);

  /// Maximum duration for a walkie-talkie clip to keep latency predictable.
  static const Duration kWalkieMaxDuration = Duration(seconds: 15);

  /// Maximum payload bytes for a walkie clip.
  static const int kWalkieMaxBytes = 96 * 1024;

  // ── ChatController Constants ─────────────────────────────────────────────

  /// Debounce duration for message pruning in ChatController.
  static const Duration kChatPruneDebounce = Duration(seconds: 2);

  /// Maximum number of messages to keep in memory in ChatController.
  static const int kChatMaxMessages = 1000;

  /// Maximum age of messages to keep in ChatController.
  static const Duration kChatMaxAge = Duration(days: 30);

  /// Upper bound on messages read for a history export.
  ///
  /// Deliberately well above [kChatMaxMessages]. Pruning is debounced and
  /// scheduled, so the table can briefly hold more rows than the retention
  /// policy allows — and an export that quietly stopped at the cap would drop
  /// the user's oldest messages without ever saying so.
  static const int kHistoryExportLimit = 5000;

  /// Minimum interval between location updates.
  static const Duration kLocationUpdateMinInterval = Duration(seconds: 45);

  /// Distance filter in meters for location updates.
  static const int kLocationDistanceFilterMeters = 25;

  // ── Rate Limiting Constants ──────────────────────────────────────────────

  /// Outbound user message rate: tokens per second (sustained rate).
  static const double kOutboundMessageRatePerSec = 5.0;

  /// Outbound user message burst capacity (max tokens in bucket).
  static const int kOutboundMessageBurst = 10;

  /// Inbound packet rate per peer: tokens per second (sustained rate).
  static const double kInboundPacketRatePerSec = 10.0;

  /// Inbound packet burst capacity per peer (max tokens in bucket).
  static const int kInboundPacketBurst = 20;

  /// Rider audio frame rate per peer. Higher than chat because Rider Mode
  /// sends small near-live PCM frames while a trusted 1:1 session is active.
  static const double kRiderInboundFrameRatePerSec = 25.0;

  /// Rider audio frame burst capacity per peer.
  static const int kRiderInboundFrameBurst = 40;

  /// Key announce cooldown: minimum interval between accepting key_announce
  /// packets from the same node ID / public key pair.
  static const Duration kKeyAnnounceCooldown = Duration(seconds: 5);

  /// Read receipt batch rate per peer: batches per second.
  static const double kReceiptBatchRatePerSec = 1.0;

  /// Read receipt batch burst capacity per peer.
  static const int kReceiptBatchBurst = 3;

  /// Idle duration after which a per-peer rate limiter may be evicted.
  static const Duration kRateLimiterIdleEviction = Duration(minutes: 5);

  // ── Public walkie airtime budget ─────────────────────────────────────────
  //
  // Public broadcast gets its own limiter, charged in *seconds of audio*
  // rather than in packets.
  //
  // [kOutboundMessageRatePerSec] cannot do this job. It counts packets, so a
  // 96 KiB walkie clip and a 20-byte chat message each cost one token — at 5
  // per second with a [kWalkieMinDuration] floor of 350 ms, it permits roughly
  // 300 KiB/s of 8-hop flood. It is a brake on message *frequency*, never on
  // airtime. Do not delete this budget as redundant with it.
  //
  // Public walkie is free, so the paywall no longer limits who can broadcast.
  // These three numbers are the only thing standing between one device and the
  // heaviest traffic the mesh carries.

  /// Seconds of audio a device may broadcast back-to-back from idle.
  ///
  /// One maximum-length clip, or roughly six three-second clips.
  static const int kPublicAudioAirtimeBurst = 20;

  /// Seconds of broadcast airtime earned per second of real time.
  ///
  /// A sustained duty cycle of ~20%: a device may hold about a fifth of the
  /// public channel indefinitely. Refills an empty budget in 100 seconds.
  ///
  /// This is the knob most likely to need tuning once real meshes are
  /// observed. Lowering it is a one-line patch; 0.15 is the conservative
  /// alternative and still allows four three-second clips from idle.
  static const double kPublicAudioAirtimeRefillPerSec = 0.2;

  /// Minimum airtime charged for any single clip, however short.
  ///
  /// Flood cost is per *clip*, not per second: every broadcast is a fresh
  /// fragment set relayed across [kHopLimit] hops by every peer, plus a dedup
  /// cache entry on each node it reaches. Without a floor, a burst of 350 ms
  /// clips costs almost nothing in airtime while being one of the most
  /// expensive things a device can do to the mesh.
  static const double kPublicAudioMinChargeSeconds = 2.0;
}
