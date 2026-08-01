import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/ephemeral_media_cache.dart';
import 'package:airgrid/core/logger.dart';
import 'package:airgrid/core/lru_cache.dart';
import 'package:airgrid/core/rate_limiter.dart';
import 'package:airgrid/core/validation.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/transport/packet_fragmenter.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/data/transport/transport_event.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/models/peer_location.dart';
import 'package:airgrid/domain/models/privacy_mode.dart';
import 'package:airgrid/domain/services/relay_controller.dart';
import 'package:airgrid/domain/services/transport_service.dart';
import 'package:uuid/uuid.dart';

class _KeyAnnounceProfileMeta {
  final String? iconId;
  final String? status;

  const _KeyAnnounceProfileMeta({this.iconId, this.status});
}

// -- Spool entry -------------------------------------------------------

/// A single packet held in the store-and-forward spool.
class _SpoolEntry {
  final AirGridPacket packet;
  final DateTime _spooledAt;

  _SpoolEntry(this.packet, {DateTime Function()? clock})
    : _spooledAt = (clock ?? DateTime.now)();

  bool isExpired(Duration ttl, {DateTime Function()? clock}) =>
      (clock ?? DateTime.now)().difference(_spooledAt) > ttl;
}

/// Result of a [AirGridMeshService.sendPrivateMessage] call.
enum PrivateSendResult {
  /// Message sent and encrypted successfully.
  sentEncrypted,

  /// Message sent as plaintext (allowPlaintextFallback was true).
  sentPlaintext,

  /// Encryption is unavailable for this peer; caller should confirm plaintext.
  needsPlaintextConfirmation,

  /// Peer has no known stable node id; private send is not possible.
  peerUnavailable,

  /// The recipient node ID is blocked; the message was not sent.
  blockedContact,

  /// The recipient is not a trusted contact and trusted-contacts-only mode is
  /// active; the message was not sent.
  notTrusted,

  /// Transport or encoding error.
  failed,
}

/// Thrown when a packet cannot be serialised because it exceeds
/// [AirGridConstants.kMaxPacketBytes].
///
/// This is a *permanent* failure, unlike a transport error: the same packet
/// will fail identically on every retry. Callers must therefore never spool
/// or retry a packet that raises this — doing so both misreports the send as
/// successful and pins a packet in the spool that can never drain.
class PacketTooLargeException implements Exception {
  /// The ceiling that was exceeded.
  final int limit;

  /// The underlying codec error, kept for diagnostics.
  final Object cause;

  const PacketTooLargeException(this.limit, this.cause);

  @override
  String toString() =>
      'PacketTooLargeException: packet exceeds $limit bytes ($cause).';
}

/// Core mesh routing engine for AirGrid.
///
/// Responsibilities:
/// - duplicate suppression via bounded LRU caches
/// - loop prevention via [seenByNodes] check
/// - TTL / hop-limit enforcement
/// - controlled flooding with random per-packet jitter
/// - rebroadcast decisions (excluding the source endpoint)
///
/// Depends ONLY on [TransportService] - no direct Nearby Connections imports.
class AirGridMeshService {
  final TransportService _transport;
  final LocalIdentityStore _identity;
  final CryptoService _cryptoService;
  final EphemeralMediaCache _mediaCache;

  /// Bounded LRU cache for general message-ID dedup (chat, location, private).
  final _messageCache = LruCache<String>(
    maxSize: AirGridConstants.kMaxCacheSize,
    ttl: AirGridConstants.kCacheTtl,
  );

  /// Bounded LRU cache for key_announce dedup, keyed on "nodeId:publicKeyB64".
  final _keyAnnounceCache = LruCache<String>(
    maxSize: AirGridConstants.kMaxCacheSize,
    ttl: AirGridConstants.kCacheTtl,
  );

  /// Bounded LRU cache for deduping relayed receipt packets.
  final _relayedReceiptCache = LruCache<String>(
    maxSize: 1000,
    ttl: AirGridConstants.kCacheTtl,
  );

  /// Bounded LRU cache for deduping fragment chunks (relay dedup only).
  final _fragmentCache = LruCache<String>(
    maxSize: 5000,
    ttl: const Duration(minutes: 5),
  );

  /// Reassembly buffer: accumulates incoming fragment packets until all
  /// chunks of a given original message are present.
  final _fragmenter = PacketFragmenter();

  /// Store-and-forward spool: encrypted private packets waiting for a
  /// recipient that is not yet reachable.
  ///
  /// Keyed by [recipientNodeId]. Entries are delivered (and removed) when
  /// the recipient is discovered via a direct key_announce.
  /// Bounded by [AirGridConstants.kSpoolMaxEntries] and
  /// [AirGridConstants.kSpoolTtlSeconds].
  final _spool = <String, List<_SpoolEntry>>{};

  /// Currently connected peers, keyed by endpointId.
  final Map<String, MeshPeer> _peers = {};

  /// Maps a directly-connected endpointId to the peer's stable nodeId.
  /// Populated when a key_announce arrives from a direct (non-relayed) peer.
  /// Used to decide whether to encrypt outgoing messages.
  final Map<String, String> _endpointToNodeId = {};

  final _messageController = StreamController<AirGridMessage>.broadcast();
  final _peerController = StreamController<List<MeshPeer>>.broadcast();
  final _locationController = StreamController<PeerLocation>.broadcast();
  final _statusController =
      StreamController<({String messageId, DeliveryStatus status})>.broadcast();

  /// Maps transport packet IDs to local UI message IDs for resend flows.
  ///
  /// When a resend uses a fresh packet id, receipts come back for that packet
  /// id. This alias map lets us update the original local bubble status.
  final Map<String, String> _receiptMessageAliases = <String, String>{};

  late final StreamSubscription<TransportEvent> _eventSub;

  /// When non-null, all relay delays use this value instead of the jitter
  /// computed by [RelayController]. Intended for deterministic unit tests.
  final int? _jitterOverrideMs;

  /// Injectable clock for spool TTL. Defaults to [DateTime.now].
  final DateTime Function() _spoolClock;

  /// Persists known peer identities discovered via [key_announce].
  late final KnownContactStore _contactStore;

  /// Persists the user's chosen [PrivacyMode].
  late final PrivacySettingsStore _privacyStore;

  // -- Rate Limiting --------------------------------------------------------

  /// Outbound user message rate limiter (local sender).
  late final RateLimiter _outboundLimiter;

  /// Per-peer inbound packet rate limiters (keyed by endpoint ID).
  late final PerPeerRateLimiterMap _inboundLimiters;

  /// Key announce cooldown tracker (keyed by nodeId:publicKey).
  late final KeyAnnounceCooldownTracker _keyAnnounceCooldown;

  /// Per-peer read receipt batch rate limiters.
  late final PerPeerRateLimiterMap _receiptBatchLimiters;

  /// Periodically retries queued encrypted private packets.
  late final Timer _spoolRetryTimer;

  bool _isFlushingSpool = false;

  AirGridMeshService(
    this._transport,
    this._identity,
    this._cryptoService, {
    EphemeralMediaCache? mediaCache,
    int? jitterOverrideMs,
    DateTime Function()? spoolClock,
    KnownContactStore? contactStore,
    PrivacySettingsStore? privacyStore,
  }) : _jitterOverrideMs = jitterOverrideMs,
       _spoolClock = spoolClock ?? DateTime.now,
       _mediaCache = mediaCache ?? EphemeralMediaCache() {
    _contactStore = contactStore ?? InMemoryKnownContactStore();
    _privacyStore = privacyStore ?? InMemoryPrivacySettingsStore();
    _eventSub = _transport.events.listen(_handleTransportEvent);

    // Initialize rate limiters
    final clock = spoolClock; // Use same clock for all limiters
    _outboundLimiter = RateLimiter(
      burstCapacity: AirGridConstants.kOutboundMessageBurst,
      tokensPerSecond: AirGridConstants.kOutboundMessageRatePerSec,
      clock: clock,
    );
    _inboundLimiters = PerPeerRateLimiterMap(
      burstCapacity: AirGridConstants.kInboundPacketBurst,
      tokensPerSecond: AirGridConstants.kInboundPacketRatePerSec,
      idleEviction: AirGridConstants.kRateLimiterIdleEviction,
      clock: clock,
    );
    _keyAnnounceCooldown = KeyAnnounceCooldownTracker(
      cooldown: AirGridConstants.kKeyAnnounceCooldown,
      clock: clock,
    );
    _receiptBatchLimiters = PerPeerRateLimiterMap(
      burstCapacity: AirGridConstants.kReceiptBatchBurst,
      tokensPerSecond: AirGridConstants.kReceiptBatchRatePerSec,
      idleEviction: AirGridConstants.kRateLimiterIdleEviction,
      clock: clock,
    );

    _spoolRetryTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_flushAllSpooled());
    });
  }

  bool _shouldAcceptFromNode(String senderNodeId) {
    if (_privacyStore.currentMode == PrivacyMode.everyoneNearby) {
      return true;
    }
    return _contactStore.isTrusted(senderNodeId);
  }

  bool _shouldPaceFragments(AirGridPacket packet) {
    return packet.packetType == 'audio' ||
        packet.packetType == 'image' ||
        packet.packetType == 'file';
  }

  /// Wraps a codec size error as a typed, non-retryable failure and logs it.
  PacketTooLargeException _asPacketTooLarge(ArgumentError e) {
    AirGridLogger.log(
      LogCategory.routing,
      'Packet rejected: exceeds kMaxPacketBytes '
      '(${AirGridConstants.kMaxPacketBytes}). Not retryable, not spooled.',
    );
    return PacketTooLargeException(AirGridConstants.kMaxPacketBytes, e);
  }

  Future<void> _sendPacketFragments(
    AirGridPacket packet,
    List<String> targets, {
    void Function(double progress)? onProgress,
  }) async {
    final paced = _shouldPaceFragments(packet);
    final maxAttempts = paced ? 6 : 3;

    // Fragmentation encodes the whole packet first, so an oversize payload
    // throws here rather than at send time. Translate it into a typed,
    // explicitly non-retryable failure so callers do not mistake it for a
    // transient transport error and spool it.
    final List<AirGridPacket> fragments;
    try {
      fragments = PacketFragmenter.fragment(packet);
    } on ArgumentError catch (e) {
      throw _asPacketTooLarge(e);
    }

    for (var index = 0; index < fragments.length; index++) {
      final outgoing = fragments[index];
      final Uint8List encoded;
      try {
        encoded = TransportCodec.encode(outgoing);
      } on ArgumentError catch (e) {
        throw _asPacketTooLarge(e);
      }
      Object? lastError;

      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          await _transport.sendToEndpoints(targets, encoded);
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          if (attempt < maxAttempts) {
            await Future<void>.delayed(Duration(milliseconds: 40 * attempt));
          }
        }
      }

      if (lastError != null) {
        throw lastError;
      }

      onProgress?.call((index + 1) / fragments.length);

      if (paced) {
        await Future<void>.delayed(const Duration(milliseconds: 6));
      }
    }
    onProgress?.call(1.0);
  }

  // -- Public API -----------------------------------------------------------

  /// Stream of messages to display in the chat UI.
  Stream<AirGridMessage> get messageStream => _messageController.stream;

  /// Stream of current peer list; emits on every connect/disconnect.
  Stream<List<MeshPeer>> get peerStream => _peerController.stream;

  /// Stream of peer location updates shared by online users.
  Stream<PeerLocation> get locationStream => _locationController.stream;

  /// Stream of delivery status updates for outgoing private messages.
  Stream<({String messageId, DeliveryStatus status})> get statusStream =>
      _statusController.stream;

  /// Current peer list snapshot.
  List<MeshPeer> get peers => List.unmodifiable(_peers.values);

  /// Stream of all known contacts; emits whenever the set changes.
  Stream<List<KnownContact>> get knownContactsStream =>
      _contactStore.contactsStream;

  /// Current known-contacts snapshot.
  List<KnownContact> get knownContacts => _contactStore.contacts;

  /// Send a new public text message originating from this device.
  ///
  /// Always sends as plaintext to all connected endpoints.
  /// For private direct messages use [sendPrivateMessage].
  Future<void> sendMessage(String content) async {
    // Validate content at API boundary (defense in depth)
    final validation = MessageContentValidator.validateLocal(content);
    if (!validation.isValid) {
      AirGridLogger.log(
        LogCategory.validation,
        'Rejected outbound message: ${validation.error}',
      );
      throw ArgumentError(validation.error);
    }

    // Rate limit outbound user messages
    if (!_outboundLimiter.allow()) {
      final retryAfter = _outboundLimiter.retryAfter();
      AirGridLogger.log(
        LogCategory.routing,
        'Outbound message rate limited (retry after ${retryAfter.inMilliseconds}ms)',
      );
      throw StateError(
        'Message rate limited. Please wait ${retryAfter.inSeconds}s.',
      );
    }

    final localNodeId = _identity.nodeId;

    final packet = AirGridPacket(
      messageId: const Uuid().v4(),
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: validation.sanitizedValue!,
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
    );

    // Register in cache so we never process our own echo.
    _messageCache.add(packet.messageId);

    // Display locally.
    _messageController.add(AirGridMessage.fromPacket(packet, localNodeId));

    final targets = _transport.connectedEndpoints.toList();
    if (targets.isNotEmpty) {
      for (final outgoing in PacketFragmenter.fragment(packet)) {
        await _transport.sendToEndpoints(
          targets,
          TransportCodec.encode(outgoing),
        );
      }
    }
    AirGridLogger.log(
      LogCategory.routing,
      'Sent public ${packet.messageId} to ${targets.length} peer(s)',
    );
  }

  /// Send a walkie-talkie voice clip to all peers on the public channel.
  ///
  /// Broadcasts unencrypted audio to every connected endpoint, similar to
  /// [sendMessage] but with [packetType] set to 'audio'. No invite/session
  /// handshake is required.
  Future<void> sendPublicAudio(AudioAttachmentPayload audio) async {
    if (!_outboundLimiter.allow()) {
      throw StateError(
        'Audio rate limited. Please wait before transmitting again.',
      );
    }

    final localNodeId = _identity.nodeId;
    final packet = AirGridPacket(
      messageId: const Uuid().v4(),
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: audio.toWire(),
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      packetType: 'audio',
      // conversationType defaults to 'public'
    );

    _messageCache.add(packet.messageId);

    // Emit a local copy so the sender sees their own transmission.
    _messageController.add(
      AirGridMessage.fromPacket(
        packet.copyWith(content: '[walkie]'),
        localNodeId,
        messageKind: 'audio',
        mediaMimeType: audio.mimeType,
        mediaByteLength: audio.byteLength,
        mediaTransferId: audio.transferId,
        mediaDurationMs: audio.durationMs,
        mediaTempPath: audio.localTempPath,
      ),
    );

    final targets = _transport.connectedEndpoints.toList();
    if (targets.isNotEmpty) {
      for (final outgoing in PacketFragmenter.fragment(packet)) {
        await _transport.sendToEndpoints(
          targets,
          TransportCodec.encode(outgoing),
        );
      }
    }
    AirGridLogger.log(
      LogCategory.routing,
      'Sent public walkie ${packet.messageId} to ${targets.length} peer(s)',
    );
  }

  /// Send a private message directly to [peer].
  ///
  /// Prefers encryption; if encryption is unavailable and [allowPlaintextFallback]
  /// is false, returns [PrivateSendResult.needsPlaintextConfirmation] so the
  /// caller can show a confirmation dialog before retrying with
  /// [allowPlaintextFallback] set to true.
  ///
  /// Private messages are sent only to [peer]'s endpoint and are never
  /// rebroadcast, whether encrypted or plaintext.
  Future<PrivateSendResult> sendPrivateMessage(
    MeshPeer peer,
    String content, {
    bool allowPlaintextFallback = false,
  }) async {
    // Validate content at API boundary
    final validation = MessageContentValidator.validateLocal(content);
    if (!validation.isValid) {
      AirGridLogger.log(
        LogCategory.validation,
        'Rejected outbound private message: ${validation.error}',
      );
      return PrivateSendResult.failed;
    }

    // Rate limit outbound user messages
    if (!_outboundLimiter.allow()) {
      final retryAfter = _outboundLimiter.retryAfter();
      AirGridLogger.log(
        LogCategory.routing,
        'Outbound private message rate limited (retry after ${retryAfter.inMilliseconds}ms)',
      );
      return PrivateSendResult.failed;
    }

    final validatedContent = validation.sanitizedValue!;

    final recipientNodeId = peer.nodeId;
    if (recipientNodeId == null) return PrivateSendResult.peerUnavailable;

    // Refuse to send to a blocked contact.
    if (_contactStore.isBlocked(recipientNodeId)) {
      AirGridLogger.log(
        LogCategory.routing,
        'Outbound private message blocked: $recipientNodeId is blocked',
      );
      return PrivateSendResult.blockedContact;
    }

    // Refuse to send to a non-trusted contact in trusted-contacts-only mode.
    if (_privacyStore.currentMode == PrivacyMode.trustedContactsOnly &&
        !_contactStore.isTrusted(recipientNodeId)) {
      AirGridLogger.log(
        LogCategory.routing,
        'Outbound private message refused: $recipientNodeId is not trusted',
      );
      return PrivateSendResult.notTrusted;
    }

    final localNodeId = _identity.nodeId;
    bool encrypted = false;
    String wireContent = validatedContent;
    int? encryptionVersion;

    if (_cryptoService.hasKey(recipientNodeId)) {
      final cipher = await _cryptoService.encryptContent(
        validatedContent,
        recipientNodeId,
      );
      if (cipher != null) {
        wireContent = cipher;
        encrypted = true;
        encryptionVersion = 1;
      }
    }

    if (!encrypted && !allowPlaintextFallback) {
      return PrivateSendResult.needsPlaintextConfirmation;
    }

    final packet = AirGridPacket(
      messageId: const Uuid().v4(),
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: wireContent,
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      senderPublicKey: encrypted ? _identity.publicKeyBase64 : null,
      encryptionVersion: encryptionVersion,
      conversationType: 'private',
      recipientNodeId: recipientNodeId,
    );

    _messageCache.add(packet.messageId);

    // Emit as pending locally before attempting the transport send.
    _messageController.add(
      AirGridMessage.fromPacket(
        packet.copyWith(content: validatedContent),
        localNodeId,
        conversationType: 'private',
        peerNodeId: recipientNodeId,
        peerName: peer.displayName,
        deliveryStatus: DeliveryStatus.pending,
      ),
    );

    try {
      final targets = encrypted
          ? _transport.connectedEndpoints.toSet().toList()
          : [peer.endpointId];
      if (encrypted && !targets.contains(peer.endpointId)) {
        targets.add(peer.endpointId);
      }
      for (final outgoing in PacketFragmenter.fragment(packet)) {
        await _transport.sendToEndpoints(
          targets,
          TransportCodec.encode(outgoing),
        );
      }

      AirGridLogger.log(
        LogCategory.routing,
        'Sent private ${packet.messageId} to ${peer.endpointId}'
        '${encrypted ? " [encrypted]" : " [plaintext fallback]"}',
      );

      _statusController.add((
        messageId: packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return encrypted
          ? PrivateSendResult.sentEncrypted
          : PrivateSendResult.sentPlaintext;
    } catch (_) {
      _statusController.add((
        messageId: packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    }
  }

  /// Broadcast this node's X25519 public key to all connected peers.
  ///
  /// Should be called after [TransportService.start] succeeds and whenever
  /// a new peer connects.  This is a best-effort send - it is not retried.
  Future<void> sendKeyAnnounce() async {
    final publicKeyB64 = _identity.publicKeyBase64;
    if (publicKeyB64 == null) return;

    final profileMeta = <String, dynamic>{};
    final profileIconId = _identity.profileIconId.trim();
    final profileStatus = _identity.profileStatus?.trim();
    if (profileIconId.isNotEmpty) {
      profileMeta['profileIconId'] = profileIconId;
    }
    if (profileStatus != null && profileStatus.isNotEmpty) {
      profileMeta['profileStatus'] = profileStatus;
    }

    final localNodeId = _identity.nodeId;
    final packet = AirGridPacket(
      messageId: const Uuid().v4(),
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: profileMeta.isEmpty ? '' : jsonEncode(profileMeta),
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      packetType: 'key_announce',
      senderPublicKey: publicKeyB64,
    );

    // key_announce packets are NOT added to _messageCache - they are
    // deduplicated by their own seenKeyAnnounces set.

    final targets = _transport.connectedEndpoints.toList();
    if (targets.isNotEmpty) {
      final bytes = TransportCodec.encode(packet);
      await _transport.sendToEndpoints(targets, bytes);
    }
    AirGridLogger.log(
      LogCategory.routing,
      'Sent key_announce to ${targets.length} peer(s)',
    );
  }

  Future<void> sendLocationUpdate(PeerLocation location) async {
    final localNodeId = _identity.nodeId;
    final packet = AirGridPacket(
      messageId: const Uuid().v4(),
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: jsonEncode(location.toJson()),
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      packetType: 'location_update',
    );

    _messageCache.add(packet.messageId);

    final targets = _transport.connectedEndpoints.toList();
    if (targets.isNotEmpty) {
      final bytes = TransportCodec.encode(packet);
      await _transport.sendToEndpoints(targets, bytes);
    }
    AirGridLogger.log(
      LogCategory.routing,
      'Sent location_update to ${targets.length} peer(s)',
    );
  }

  /// Send a private message to a [KnownContact] who may or may not be a
  /// currently connected direct peer.
  ///
  /// Always encrypted — no plaintext fallback is permitted for crowd-relay
  /// private messages. Returns [PrivateSendResult.peerUnavailable] only if
  /// encryption fails despite the contact having a known public key (should
  /// never occur in practice).
  Future<PrivateSendResult> sendPrivateMessageToContact(
    KnownContact contact,
    String content,
  ) async {
    // Validate content at API boundary
    final validation = MessageContentValidator.validateLocal(content);
    if (!validation.isValid) {
      AirGridLogger.log(
        LogCategory.validation,
        'Rejected outbound contact message: ${validation.error}',
      );
      return PrivateSendResult.failed;
    }

    // Rate limit outbound user messages
    if (!_outboundLimiter.allow()) {
      final retryAfter = _outboundLimiter.retryAfter();
      AirGridLogger.log(
        LogCategory.routing,
        'Outbound contact message rate limited (retry after ${retryAfter.inMilliseconds}ms)',
      );
      return PrivateSendResult.failed;
    }

    // Refuse to send to a blocked contact.
    if (_contactStore.isBlocked(contact.nodeId)) {
      AirGridLogger.log(
        LogCategory.routing,
        'Outbound contact message blocked: ${contact.nodeId} is blocked',
      );
      return PrivateSendResult.blockedContact;
    }

    // Refuse to send to a non-trusted contact in trusted-contacts-only mode.
    if (_privacyStore.currentMode == PrivacyMode.trustedContactsOnly &&
        !_contactStore.isTrusted(contact.nodeId)) {
      AirGridLogger.log(
        LogCategory.routing,
        'Outbound contact message refused: ${contact.nodeId} is not trusted',
      );
      return PrivateSendResult.notTrusted;
    }

    final validatedContent = validation.sanitizedValue!;

    // Re-cache the key in case the in-memory crypto service was cleared.
    if (!_cryptoService.hasKey(contact.nodeId)) {
      _cryptoService.cacheKey(contact.nodeId, contact.publicKeyBase64);
    }

    final cipher = await _cryptoService.encryptContent(
      validatedContent,
      contact.nodeId,
    );
    if (cipher == null) return PrivateSendResult.peerUnavailable;

    final localNodeId = _identity.nodeId;
    final packet = AirGridPacket(
      messageId: const Uuid().v4(),
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: cipher,
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      senderPublicKey: _identity.publicKeyBase64,
      encryptionVersion: 1,
      conversationType: 'private',
      recipientNodeId: contact.nodeId,
    );

    _messageCache.add(packet.messageId);

    // Show the message locally as pending immediately.
    _messageController.add(
      AirGridMessage.fromPacket(
        packet.copyWith(content: validatedContent),
        localNodeId,
        conversationType: 'private',
        peerNodeId: contact.nodeId,
        peerName: contact.displayName,
        deliveryStatus: DeliveryStatus.pending,
      ),
    );

    // Priority 1: send direct if the contact is currently a connected peer.
    // Priority 2: broadcast to all connected endpoints for crowd relay.
    // Priority 3: spool if no peers are connected at all.
    final directEndpoint = _endpointToNodeId.entries
        .where((e) => e.value == contact.nodeId)
        .map((e) => e.key)
        .firstOrNull;

    final targets = directEndpoint != null
        ? [directEndpoint]
        : _transport.connectedEndpoints.toList();

    if (targets.isEmpty) {
      if (!_spoolPacket(packet)) {
        _statusController.add((
          messageId: packet.messageId,
          status: DeliveryStatus.failed,
        ));
        return PrivateSendResult.failed;
      }
      _statusController.add((
        messageId: packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return PrivateSendResult.sentEncrypted;
    }

    try {
      await _sendPacketFragments(packet, targets);
      AirGridLogger.log(
        LogCategory.routing,
        'Sent private ${packet.messageId} to contact ${contact.nodeId}'
        '${directEndpoint != null ? " [direct]" : " [relay broadcast]"}',
      );
      _statusController.add((
        messageId: packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return PrivateSendResult.sentEncrypted;
    } catch (_) {
      _statusController.add((
        messageId: packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    }
  }

  /// Sends a private image to a directly connected [peer].
  Future<PrivateSendResult> sendPrivateImage(
    MeshPeer peer,
    ImageAttachmentPayload image, {
    bool allowPlaintextFallback = false,
    String? messageId,
    String? packetId,
    bool emitLocalMessage = true,
  }) async {
    final recipientNodeId = peer.nodeId;
    if (recipientNodeId == null) return PrivateSendResult.peerUnavailable;

    if (_contactStore.isBlocked(recipientNodeId)) {
      return PrivateSendResult.blockedContact;
    }

    if (_privacyStore.currentMode == PrivacyMode.trustedContactsOnly &&
        !_contactStore.isTrusted(recipientNodeId)) {
      return PrivateSendResult.notTrusted;
    }

    if (!_outboundLimiter.allow()) {
      return PrivateSendResult.failed;
    }

    var wireContent = image.toWire();
    var encrypted = false;
    int? encryptionVersion;

    if (_cryptoService.hasKey(recipientNodeId)) {
      final cipher = await _cryptoService.encryptContent(
        wireContent,
        recipientNodeId,
      );
      if (cipher != null) {
        wireContent = cipher;
        encrypted = true;
        encryptionVersion = 1;
      }
    }

    if (!encrypted && !allowPlaintextFallback) {
      return PrivateSendResult.needsPlaintextConfirmation;
    }

    final localNodeId = _identity.nodeId;
    final packetMessageId = packetId ?? messageId ?? const Uuid().v4();
    final packet = AirGridPacket(
      messageId: packetMessageId,
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: wireContent,
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      packetType: 'image',
      senderPublicKey: encrypted ? _identity.publicKeyBase64 : null,
      encryptionVersion: encryptionVersion,
      conversationType: 'private',
      recipientNodeId: recipientNodeId,
    );

    _messageCache.add(packet.messageId);
    _rememberReceiptAlias(packet.messageId, messageId);

    if (emitLocalMessage) {
      _messageController.add(
        AirGridMessage.fromPacket(
          packet.copyWith(content: '[photo]'),
          localNodeId,
          conversationType: 'private',
          peerNodeId: recipientNodeId,
          peerName: peer.displayName,
          deliveryStatus: DeliveryStatus.pending,
          messageKind: 'image',
          mediaMimeType: image.mimeType,
          mediaByteLength: image.byteLength,
          mediaWidth: image.width,
          mediaHeight: image.height,
          mediaTransferId: image.transferId,
          mediaTempPath: image.localTempPath,
          mediaPreviewBase64: image.dataBase64,
        ),
      );
    }

    try {
      final targets = encrypted
          ? _transport.connectedEndpoints.toSet().toList()
          : [peer.endpointId];
      if (encrypted && !targets.contains(peer.endpointId)) {
        targets.add(peer.endpointId);
      }
      await _sendPacketFragments(packet, targets);
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return encrypted
          ? PrivateSendResult.sentEncrypted
          : PrivateSendResult.sentPlaintext;
    } on PacketTooLargeException {
      // Permanent: the packet cannot be encoded at any time, so neither the
      // relay fallback nor the spool can ever deliver it. Report the real
      // failure instead of laundering it into a "sent" status.
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    } catch (_) {
      if (encrypted) {
        final fallbackTargets = _transport.connectedEndpoints
            .where((id) => id != peer.endpointId)
            .toList();

        if (fallbackTargets.isNotEmpty) {
          try {
            await _sendPacketFragments(packet, fallbackTargets);
            _statusController.add((
              messageId: messageId ?? packet.messageId,
              status: DeliveryStatus.sent,
            ));
            return PrivateSendResult.sentEncrypted;
          } catch (_) {
            // Fall through to spool for deferred relay when immediate fallback fails.
          }
        }

        _spoolPacket(packet);
        _statusController.add((
          messageId: messageId ?? packet.messageId,
          status: DeliveryStatus.sent,
        ));
        return PrivateSendResult.sentEncrypted;
      }

      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    }
  }

  /// Sends a private image to a known contact; supports relay/spool flow.
  Future<PrivateSendResult> sendPrivateImageToContact(
    KnownContact contact,
    ImageAttachmentPayload image, {
    String? messageId,
    String? packetId,
    bool emitLocalMessage = true,
  }) async {
    if (_contactStore.isBlocked(contact.nodeId)) {
      return PrivateSendResult.blockedContact;
    }
    if (_privacyStore.currentMode == PrivacyMode.trustedContactsOnly &&
        !_contactStore.isTrusted(contact.nodeId)) {
      return PrivateSendResult.notTrusted;
    }
    if (!_outboundLimiter.allow()) {
      return PrivateSendResult.failed;
    }

    if (!_cryptoService.hasKey(contact.nodeId)) {
      _cryptoService.cacheKey(contact.nodeId, contact.publicKeyBase64);
    }

    final cipher = await _cryptoService.encryptContent(
      image.toWire(),
      contact.nodeId,
    );
    if (cipher == null) return PrivateSendResult.peerUnavailable;

    final localNodeId = _identity.nodeId;
    final packetMessageId = packetId ?? messageId ?? const Uuid().v4();
    final packet = AirGridPacket(
      messageId: packetMessageId,
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: cipher,
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      packetType: 'image',
      senderPublicKey: _identity.publicKeyBase64,
      encryptionVersion: 1,
      conversationType: 'private',
      recipientNodeId: contact.nodeId,
    );

    _messageCache.add(packet.messageId);
    _rememberReceiptAlias(packet.messageId, messageId);

    if (emitLocalMessage) {
      _messageController.add(
        AirGridMessage.fromPacket(
          packet.copyWith(content: '[photo]'),
          localNodeId,
          conversationType: 'private',
          peerNodeId: contact.nodeId,
          peerName: contact.displayName,
          deliveryStatus: DeliveryStatus.pending,
          messageKind: 'image',
          mediaMimeType: image.mimeType,
          mediaByteLength: image.byteLength,
          mediaWidth: image.width,
          mediaHeight: image.height,
          mediaTransferId: image.transferId,
          mediaTempPath: image.localTempPath,
          mediaPreviewBase64: image.dataBase64,
        ),
      );
    }

    final directEndpoint = _endpointToNodeId.entries
        .where((e) => e.value == contact.nodeId)
        .map((e) => e.key)
        .firstOrNull;

    final targets = directEndpoint != null
        ? [directEndpoint]
        : _transport.connectedEndpoints.toList();

    if (targets.isEmpty) {
      if (!_spoolPacket(packet)) {
        _statusController.add((
          messageId: messageId ?? packet.messageId,
          status: DeliveryStatus.failed,
        ));
        return PrivateSendResult.failed;
      }
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return PrivateSendResult.sentEncrypted;
    }

    try {
      await _sendPacketFragments(packet, targets);
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return PrivateSendResult.sentEncrypted;
    } catch (_) {
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    }
  }

  /// Sends a private voice note to a directly connected [peer].
  Future<PrivateSendResult> sendPrivateAudio(
    MeshPeer peer,
    AudioAttachmentPayload audio, {
    bool allowPlaintextFallback = false,
    String? messageId,
    String? packetId,
    bool emitLocalMessage = true,
  }) async {
    final recipientNodeId = peer.nodeId;
    if (recipientNodeId == null) return PrivateSendResult.peerUnavailable;

    if (_contactStore.isBlocked(recipientNodeId)) {
      return PrivateSendResult.blockedContact;
    }

    if (_privacyStore.currentMode == PrivacyMode.trustedContactsOnly &&
        !_contactStore.isTrusted(recipientNodeId)) {
      return PrivateSendResult.notTrusted;
    }

    if (!_outboundLimiter.allow()) {
      return PrivateSendResult.failed;
    }

    var wireContent = audio.toWire();
    var encrypted = false;
    int? encryptionVersion;

    if (_cryptoService.hasKey(recipientNodeId)) {
      final cipher = await _cryptoService.encryptContent(
        wireContent,
        recipientNodeId,
      );
      if (cipher != null) {
        wireContent = cipher;
        encrypted = true;
        encryptionVersion = 1;
      }
    }

    if (!encrypted && !allowPlaintextFallback) {
      return PrivateSendResult.needsPlaintextConfirmation;
    }

    final localNodeId = _identity.nodeId;
    final packetMessageId = packetId ?? messageId ?? const Uuid().v4();
    final packet = AirGridPacket(
      messageId: packetMessageId,
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: wireContent,
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      packetType: 'audio',
      senderPublicKey: encrypted ? _identity.publicKeyBase64 : null,
      encryptionVersion: encryptionVersion,
      conversationType: 'private',
      recipientNodeId: recipientNodeId,
    );

    _messageCache.add(packet.messageId);
    _rememberReceiptAlias(packet.messageId, messageId);

    if (emitLocalMessage) {
      final audioContent = audio.source == AudioAttachmentPayload.sourceWalkie
          ? '[walkie]'
          : '[voice]';
      _messageController.add(
        AirGridMessage.fromPacket(
          packet.copyWith(content: audioContent),
          localNodeId,
          conversationType: 'private',
          peerNodeId: recipientNodeId,
          peerName: peer.displayName,
          deliveryStatus: DeliveryStatus.pending,
          messageKind: 'audio',
          mediaMimeType: audio.mimeType,
          mediaByteLength: audio.byteLength,
          mediaTransferId: audio.transferId,
          mediaDurationMs: audio.durationMs,
          mediaTempPath: audio.localTempPath,
        ),
      );
    }

    try {
      final targets = encrypted
          ? _transport.connectedEndpoints.toSet().toList()
          : [peer.endpointId];
      if (encrypted && !targets.contains(peer.endpointId)) {
        targets.add(peer.endpointId);
      }
      await _sendPacketFragments(packet, targets);
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return encrypted
          ? PrivateSendResult.sentEncrypted
          : PrivateSendResult.sentPlaintext;
    } on PacketTooLargeException {
      // Permanent: the packet cannot be encoded at any time, so neither the
      // relay fallback nor the spool can ever deliver it. Report the real
      // failure instead of laundering it into a "sent" status.
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    } catch (_) {
      if (encrypted) {
        final fallbackTargets = _transport.connectedEndpoints
            .where((id) => id != peer.endpointId)
            .toList();

        if (fallbackTargets.isNotEmpty) {
          try {
            await _sendPacketFragments(packet, fallbackTargets);
            _statusController.add((
              messageId: messageId ?? packet.messageId,
              status: DeliveryStatus.sent,
            ));
            return PrivateSendResult.sentEncrypted;
          } catch (_) {
            // Fall through to spool for deferred relay when immediate fallback fails.
          }
        }

        _spoolPacket(packet);
        _statusController.add((
          messageId: messageId ?? packet.messageId,
          status: DeliveryStatus.sent,
        ));
        return PrivateSendResult.sentEncrypted;
      }

      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    }
  }

  /// Sends a private voice note to a known contact; supports relay/spool flow.
  Future<PrivateSendResult> sendPrivateAudioToContact(
    KnownContact contact,
    AudioAttachmentPayload audio, {
    String? messageId,
    String? packetId,
    bool emitLocalMessage = true,
  }) async {
    if (_contactStore.isBlocked(contact.nodeId)) {
      return PrivateSendResult.blockedContact;
    }
    if (_privacyStore.currentMode == PrivacyMode.trustedContactsOnly &&
        !_contactStore.isTrusted(contact.nodeId)) {
      return PrivateSendResult.notTrusted;
    }
    if (!_outboundLimiter.allow()) {
      return PrivateSendResult.failed;
    }

    if (!_cryptoService.hasKey(contact.nodeId)) {
      _cryptoService.cacheKey(contact.nodeId, contact.publicKeyBase64);
    }

    final cipher = await _cryptoService.encryptContent(
      audio.toWire(),
      contact.nodeId,
    );
    if (cipher == null) return PrivateSendResult.peerUnavailable;

    final localNodeId = _identity.nodeId;
    final packetMessageId = packetId ?? messageId ?? const Uuid().v4();
    final packet = AirGridPacket(
      messageId: packetMessageId,
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: cipher,
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      packetType: 'audio',
      senderPublicKey: _identity.publicKeyBase64,
      encryptionVersion: 1,
      conversationType: 'private',
      recipientNodeId: contact.nodeId,
    );

    _messageCache.add(packet.messageId);
    _rememberReceiptAlias(packet.messageId, messageId);

    if (emitLocalMessage) {
      final audioContent = audio.source == AudioAttachmentPayload.sourceWalkie
          ? '[walkie]'
          : '[voice]';
      _messageController.add(
        AirGridMessage.fromPacket(
          packet.copyWith(content: audioContent),
          localNodeId,
          conversationType: 'private',
          peerNodeId: contact.nodeId,
          peerName: contact.displayName,
          deliveryStatus: DeliveryStatus.pending,
          messageKind: 'audio',
          mediaMimeType: audio.mimeType,
          mediaByteLength: audio.byteLength,
          mediaTransferId: audio.transferId,
          mediaDurationMs: audio.durationMs,
          mediaTempPath: audio.localTempPath,
        ),
      );
    }

    final directEndpoint = _endpointToNodeId.entries
        .where((e) => e.value == contact.nodeId)
        .map((e) => e.key)
        .firstOrNull;

    final targets = directEndpoint != null
        ? [directEndpoint]
        : _transport.connectedEndpoints.toList();

    if (targets.isEmpty) {
      if (!_spoolPacket(packet)) {
        _statusController.add((
          messageId: messageId ?? packet.messageId,
          status: DeliveryStatus.failed,
        ));
        return PrivateSendResult.failed;
      }
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return PrivateSendResult.sentEncrypted;
    }

    try {
      await _sendPacketFragments(packet, targets);
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return PrivateSendResult.sentEncrypted;
    } catch (_) {
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    }
  }

  Future<PrivateSendResult> sendPrivateFile(
    MeshPeer peer,
    FileAttachmentPayload file, {
    bool allowPlaintextFallback = false,
    String? messageId,
    String? packetId,
    bool emitLocalMessage = true,
    void Function(double progress)? onProgress,
  }) async {
    final recipientNodeId = peer.nodeId;
    if (recipientNodeId == null) return PrivateSendResult.peerUnavailable;

    if (_contactStore.isBlocked(recipientNodeId)) {
      return PrivateSendResult.blockedContact;
    }

    if (_privacyStore.currentMode == PrivacyMode.trustedContactsOnly &&
        !_contactStore.isTrusted(recipientNodeId)) {
      return PrivateSendResult.notTrusted;
    }

    if (!_outboundLimiter.allow()) {
      return PrivateSendResult.failed;
    }

    var wireContent = file.toWire();
    var encrypted = false;
    int? encryptionVersion;

    if (_cryptoService.hasKey(recipientNodeId)) {
      final cipher = await _cryptoService.encryptContent(
        wireContent,
        recipientNodeId,
      );
      if (cipher != null) {
        wireContent = cipher;
        encrypted = true;
        encryptionVersion = 1;
      }
    }

    if (!encrypted && !allowPlaintextFallback) {
      return PrivateSendResult.needsPlaintextConfirmation;
    }

    final localNodeId = _identity.nodeId;
    final packetMessageId = packetId ?? messageId ?? const Uuid().v4();
    final packet = AirGridPacket(
      messageId: packetMessageId,
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: wireContent,
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      packetType: 'file',
      senderPublicKey: encrypted ? _identity.publicKeyBase64 : null,
      encryptionVersion: encryptionVersion,
      conversationType: 'private',
      recipientNodeId: recipientNodeId,
    );

    _messageCache.add(packet.messageId);
    _rememberReceiptAlias(packet.messageId, messageId);

    if (emitLocalMessage) {
      _messageController.add(
        AirGridMessage.fromPacket(
          packet.copyWith(content: '[file]'),
          localNodeId,
          conversationType: 'private',
          peerNodeId: recipientNodeId,
          peerName: peer.displayName,
          deliveryStatus: DeliveryStatus.pending,
          messageKind: 'file',
          mediaMimeType: file.mimeType,
          mediaByteLength: file.byteLength,
          mediaTransferId: file.transferId,
          mediaTempPath: file.localTempPath,
        ),
      );
    }

    try {
      final targets = encrypted
          ? _transport.connectedEndpoints.toSet().toList()
          : [peer.endpointId];
      if (encrypted && !targets.contains(peer.endpointId)) {
        targets.add(peer.endpointId);
      }
      await _sendPacketFragments(packet, targets, onProgress: onProgress);
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return encrypted
          ? PrivateSendResult.sentEncrypted
          : PrivateSendResult.sentPlaintext;
    } on PacketTooLargeException {
      // Permanent: the packet cannot be encoded at any time, so neither the
      // relay fallback nor the spool can ever deliver it. Report the real
      // failure instead of laundering it into a "sent" status.
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    } catch (_) {
      if (encrypted) {
        final fallbackTargets = _transport.connectedEndpoints
            .where((id) => id != peer.endpointId)
            .toList();

        if (fallbackTargets.isNotEmpty) {
          try {
            await _sendPacketFragments(
              packet,
              fallbackTargets,
              onProgress: onProgress,
            );
            _statusController.add((
              messageId: messageId ?? packet.messageId,
              status: DeliveryStatus.sent,
            ));
            return PrivateSendResult.sentEncrypted;
          } catch (_) {
            // Fall through to spool for deferred relay when immediate fallback fails.
          }
        }

        _spoolPacket(packet);
        _statusController.add((
          messageId: messageId ?? packet.messageId,
          status: DeliveryStatus.sent,
        ));
        return PrivateSendResult.sentEncrypted;
      }

      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    }
  }

  Future<PrivateSendResult> sendPrivateFileToContact(
    KnownContact contact,
    FileAttachmentPayload file, {
    String? messageId,
    String? packetId,
    bool emitLocalMessage = true,
    void Function(double progress)? onProgress,
  }) async {
    if (_contactStore.isBlocked(contact.nodeId)) {
      return PrivateSendResult.blockedContact;
    }
    if (_privacyStore.currentMode == PrivacyMode.trustedContactsOnly &&
        !_contactStore.isTrusted(contact.nodeId)) {
      return PrivateSendResult.notTrusted;
    }
    if (!_outboundLimiter.allow()) {
      return PrivateSendResult.failed;
    }

    if (!_cryptoService.hasKey(contact.nodeId)) {
      _cryptoService.cacheKey(contact.nodeId, contact.publicKeyBase64);
    }

    final cipher = await _cryptoService.encryptContent(
      file.toWire(),
      contact.nodeId,
    );
    if (cipher == null) return PrivateSendResult.peerUnavailable;

    final localNodeId = _identity.nodeId;
    final packetMessageId = packetId ?? messageId ?? const Uuid().v4();
    final packet = AirGridPacket(
      messageId: packetMessageId,
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: cipher,
      seenByNodes: [localNodeId],
      hopLimit: AirGridConstants.kHopLimit,
      packetType: 'file',
      senderPublicKey: _identity.publicKeyBase64,
      encryptionVersion: 1,
      conversationType: 'private',
      recipientNodeId: contact.nodeId,
    );

    _messageCache.add(packet.messageId);
    _rememberReceiptAlias(packet.messageId, messageId);

    if (emitLocalMessage) {
      _messageController.add(
        AirGridMessage.fromPacket(
          packet.copyWith(content: '[file]'),
          localNodeId,
          conversationType: 'private',
          peerNodeId: contact.nodeId,
          peerName: contact.displayName,
          deliveryStatus: DeliveryStatus.pending,
          messageKind: 'file',
          mediaMimeType: file.mimeType,
          mediaByteLength: file.byteLength,
          mediaTransferId: file.transferId,
          mediaTempPath: file.localTempPath,
        ),
      );
    }

    final directEndpoint = _endpointToNodeId.entries
        .where((e) => e.value == contact.nodeId)
        .map((e) => e.key)
        .firstOrNull;

    final targets = directEndpoint != null
        ? [directEndpoint]
        : _transport.connectedEndpoints.toList();

    if (targets.isEmpty) {
      if (!_spoolPacket(packet)) {
        _statusController.add((
          messageId: messageId ?? packet.messageId,
          status: DeliveryStatus.failed,
        ));
        return PrivateSendResult.failed;
      }
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return PrivateSendResult.sentEncrypted;
    }

    try {
      await _sendPacketFragments(packet, targets, onProgress: onProgress);
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.sent,
      ));
      return PrivateSendResult.sentEncrypted;
    } catch (_) {
      _statusController.add((
        messageId: messageId ?? packet.messageId,
        status: DeliveryStatus.failed,
      ));
      return PrivateSendResult.failed;
    }
  }

  Future<void> dispose() async {
    _spoolRetryTimer.cancel();
    await _eventSub.cancel();
    await _messageController.close();
    await _peerController.close();
    await _locationController.close();
    await _statusController.close();
    await _contactStore.dispose();
  }

  // -- Transport event handling ---------------------------------------------

  void _handleTransportEvent(TransportEvent event) {
    switch (event) {
      case TransportBytesReceived(:final fromEndpointId, :final bytes):
        // Packet processing may involve async decryption - fire and forget.
        unawaited(_onPacketReceived(fromEndpointId, bytes));

      case TransportPeerConnected(
        :final endpointId,
        :final displayName,
        :final nodeId,
      ):
        _peers[endpointId] = MeshPeer(
          endpointId: endpointId,
          displayName: displayName,
          connectedAt: DateTime.now(),
          nodeId: nodeId,
          encryptionReady: nodeId != null && _cryptoService.hasKey(nodeId),
        );
        if (nodeId != null) {
          _endpointToNodeId[endpointId] = nodeId;
          // If messages were queued while this contact was offline, flush them
          // immediately when a direct route appears, even before key_announce.
          unawaited(_flushSpool(nodeId, preferredEndpointId: endpointId));
        }
        _peerController.add(peers);
        AirGridLogger.log(
          LogCategory.connection,
          'Peer joined: $endpointId ($displayName) - total: ${_peers.length}',
        );

      case TransportPeerDisconnected(:final endpointId):
        final disconnectedNodeId = _endpointToNodeId[endpointId];
        _peers.remove(endpointId);
        _endpointToNodeId.remove(endpointId);
        if (disconnectedNodeId != null) {
          unawaited(_contactStore.markOffline(disconnectedNodeId));
        }
        _peerController.add(peers);
        AirGridLogger.log(
          LogCategory.connection,
          'Peer left: $endpointId - total: ${_peers.length}',
        );

      case TransportStartFailed(:final reason):
        AirGridLogger.log(
          LogCategory.connection,
          'Transport start failed: $reason',
        );
    }
  }

  // -- Packet receive pipeline ----------------------------------------------

  Future<void> _onPacketReceived(
    String fromEndpointId,
    Uint8List bytes, {
    bool fromAssembly = false,
  }) async {
    // -- Gate 0: decode (needed early to check packet type for rate limiting) -
    final packet = TransportCodec.decode(bytes);
    if (packet == null) {
      AirGridLogger.log(
        LogCategory.validation,
        'Malformed packet from $fromEndpointId - dropped',
      );
      return;
    }

    // -- Gate 1: Rate limit inbound packets per peer -----------------------
    // Key by endpoint ID first (available immediately), upgrade to node ID
    // after identity is known via key_announce for better tracking.
    //
    // Fragment packets are EXEMPT from the per-peer rate limiter.  A photo
    // at 300 KB produces ~73 fragments (÷ 4096 byte threshold) but the burst
    // bucket is only 20, so without this exemption roughly 53 fragments would
    // be silently dropped every send, preventing reassembly and delivery
    // receipt.  Fragment DoS is already bounded by the reassembly-layer limits
    // (kMaxReassemblyBuckets / kReassemblyMaxBytesInFlight).
    // Reassembled packets (fromAssembly=true) are synthetic: their underlying
    // fragments were already received, so double-counting them is wrong.
    final isFragment = packet.packetType == 'fragment';
    if (!fromAssembly &&
        !isFragment &&
        !_inboundLimiters.allow(fromEndpointId)) {
      final retryAfter = _inboundLimiters.retryAfter(fromEndpointId);
      AirGridLogger.log(
        LogCategory.routing,
        'Inbound packet from $fromEndpointId rate limited '
        '(retry after ${retryAfter.inMilliseconds}ms)',
      );
      return;
    }

    // -- Gate 1a: Validate remote node IDs -------------------------------
    final nodeIdValidation = NodeIdValidator.validate(packet.senderNodeId);
    if (!nodeIdValidation.isValid) {
      AirGridLogger.log(
        LogCategory.validation,
        '${packet.messageId} dropped: invalid senderNodeId '
        '(${nodeIdValidation.error})',
      );
      return;
    }

    // Validate recipientNodeId if present
    final recipientId = packet.recipientNodeId;
    if (recipientId != null && recipientId.isNotEmpty) {
      final recipientValidation = NodeIdValidator.validate(recipientId);
      if (!recipientValidation.isValid) {
        AirGridLogger.log(
          LogCategory.validation,
          '${packet.messageId} dropped: invalid recipientNodeId '
          '(${recipientValidation.error})',
        );
        return;
      }
    }

    // -- Gate 1b: Validate remote display name ---------------------------
    final nameValidation = DisplayNameValidator.validateRemote(
      packet.senderName,
    );
    if (!nameValidation.isValid) {
      AirGridLogger.log(
        LogCategory.validation,
        '${packet.messageId} dropped from ${packet.senderNodeId}: '
        'invalid display name (${nameValidation.error})',
      );
      return;
    }

    // -- Gate 1c: Validate message content (for chat packets) ------------
    // Skip validation for special packet types (key_announce, fragment, receipts, location)
    if (packet.packetType != 'key_announce' &&
        packet.packetType != 'fragment' &&
        packet.packetType != 'delivery_receipt' &&
        packet.packetType != 'read_receipt' &&
        packet.packetType != 'location_update' &&
        packet.packetType != 'image' &&
        packet.packetType != 'audio' &&
        packet.packetType != 'file') {
      final contentValidation = MessageContentValidator.validateRemote(
        packet.content,
      );
      if (!contentValidation.isValid) {
        AirGridLogger.log(
          LogCategory.validation,
          '${packet.messageId} dropped from ${packet.senderNodeId}: '
          'invalid content (${contentValidation.error})',
        );
        return;
      }
    }

    // -- Gate 2: hop limit ------------------------------------------------
    if (packet.hopLimit <= 0) {
      AirGridLogger.log(
        LogCategory.routing,
        '${packet.messageId} dropped: hopLimit exhausted',
      );
      return;
    }

    // -- Gate 3: seenByNodes loop prevention ------------------------------
    final localNodeId = _identity.nodeId;
    if (packet.seenByNodes.contains(localNodeId)) {
      AirGridLogger.log(
        LogCategory.routing,
        '${packet.messageId} dropped: loop detected (nodeId in seenByNodes)',
      );
      return;
    }

    // -- Gate 3b: blocked sender ------------------------------------------
    if (_contactStore.isBlocked(packet.senderNodeId)) {
      AirGridLogger.log(
        LogCategory.routing,
        '${packet.messageId} dropped from ${packet.senderNodeId}: sender is blocked',
      );
      return;
    }

    // -- Gate 3c: trusted-contacts-only mode --------------------------------
    // key_announce is always allowed so unknown nodes can be learned before
    // the user decides to trust them. Chat and location are gated.
    if ((packet.packetType == 'chat' ||
            packet.packetType == 'image' ||
            packet.packetType == 'audio' ||
            packet.packetType == 'file' ||
            packet.packetType == 'location_update') &&
        !_shouldAcceptFromNode(packet.senderNodeId)) {
      AirGridLogger.log(
        LogCategory.routing,
        '${packet.messageId} dropped from ${packet.senderNodeId}: '
        'trusted-contacts-only mode, sender not trusted',
      );
      return;
    }

    // -- Packet-type branch ------------------------------------------------
    if (packet.packetType == 'key_announce') {
      _handleKeyAnnounce(packet, fromEndpointId);
      return;
    }

    // -- Fragment handling -------------------------------------------------
    if (packet.packetType == 'fragment') {
      _handleFragment(packet, fromEndpointId);
      return;
    }

    // -- Gate 4a: private packet routing ---------------------------------
    final isPrivate = packet.conversationType == 'private';
    if (isPrivate) {
      final rid = packet.recipientNodeId;
      if (rid != null && rid != localNodeId) {
        // Relay encrypted private packets on behalf of others;
        // plaintext private packets are never relayed.
        if (packet.encryptionVersion != null) {
          _relayOrSpoolPrivate(packet, fromEndpointId);
        } else {
          AirGridLogger.log(
            LogCategory.routing,
            '${packet.messageId} dropped: plaintext private for $rid',
          );
        }
        return;
      }
    }

    // -- Receipt packets ---------------------------------------------------
    // Only process receipts that are explicitly private and addressed to us.
    if (packet.packetType == 'delivery_receipt' ||
        packet.packetType == 'read_receipt') {
      if (packet.conversationType == 'private' &&
          packet.recipientNodeId == localNodeId) {
        await _handleReceipt(packet);
      }
      return;
    }

    // -- Gate 4: duplicate suppression (chat packets only) ----------------
    if (_messageCache.contains(packet.messageId)) {
      AirGridLogger.log(
        LogCategory.dedup,
        '${packet.messageId} dropped: duplicate',
      );
      return;
    }

    // -- Accept -----------------------------------------------------------
    _messageCache.add(packet.messageId);
    // -- Opportunistic decryption ---------------------------------------
    if (packet.packetType == 'location_update') {
      _handleLocationUpdate(packet, fromEndpointId);
      return;
    }

    if (packet.encryptionVersion != null) {
      // Any non-null encryptionVersion is treated as encrypted.
      // Version 1 with a public key: attempt decryption.
      // Anything else (unsupported version, missing key): show placeholder.
      // In all cases: do NOT rebroadcast - encrypted packets are direct.
      if (packet.encryptionVersion == 1 && packet.senderPublicKey != null) {
        final plaintext = await _cryptoService.decryptContent(
          packet.content,
          packet.senderPublicKey!,
        );
        if (plaintext != null &&
            (packet.packetType == 'image' ||
                packet.packetType == 'audio' ||
                packet.packetType == 'file')) {
          final emitted = packet.packetType == 'image'
              ? await _buildImageMessage(
                  packet,
                  localNodeId,
                  plaintext,
                  isPrivate: isPrivate,
                )
              : packet.packetType == 'audio'
              ? await _buildAudioMessage(
                  packet,
                  localNodeId,
                  plaintext,
                  isPrivate: isPrivate,
                )
              : await _buildFileMessage(
                  packet,
                  localNodeId,
                  plaintext,
                  isPrivate: isPrivate,
                );
          if (emitted != null) {
            _messageController.add(emitted);
          }
        } else {
          final displayContent = plaintext ?? '[encrypted message]';
          _messageController.add(
            AirGridMessage.fromPacket(
              packet.copyWith(content: displayContent),
              localNodeId,
              conversationType: packet.conversationType,
              peerNodeId: isPrivate ? packet.senderNodeId : null,
              peerName: isPrivate ? packet.senderName : null,
            ),
          );
        }
        AirGridLogger.log(
          LogCategory.routing,
          'Accepted ${packet.messageId} from ${packet.senderName} '
          '[${plaintext != null ? "decrypted" : "undecryptable"}]',
        );
      } else {
        // Unsupported encryption version or missing metadata - show placeholder.
        _messageController.add(
          AirGridMessage.fromPacket(
            packet.copyWith(content: '[encrypted message]'),
            localNodeId,
            conversationType: packet.conversationType,
            peerNodeId: isPrivate ? packet.senderNodeId : null,
            peerName: isPrivate ? packet.senderName : null,
          ),
        );
        AirGridLogger.log(
          LogCategory.routing,
          'Accepted ${packet.messageId} from ${packet.senderName} '
          '[unsupported encryption v${packet.encryptionVersion}]',
        );
      }
      if (isPrivate) unawaited(_sendDeliveryReceipt(packet, fromEndpointId));
      return;
    }

    // -- Emit plaintext to UI -----------------------------------------
    if (packet.packetType == 'image' ||
        packet.packetType == 'audio' ||
        packet.packetType == 'file') {
      final emitted = packet.packetType == 'image'
          ? await _buildImageMessage(
              packet,
              localNodeId,
              packet.content,
              isPrivate: isPrivate,
            )
          : packet.packetType == 'audio'
          ? await _buildAudioMessage(
              packet,
              localNodeId,
              packet.content,
              isPrivate: isPrivate,
            )
          : await _buildFileMessage(
              packet,
              localNodeId,
              packet.content,
              isPrivate: isPrivate,
            );
      if (emitted != null) {
        _messageController.add(emitted);
      }
    } else {
      // Emit to UI before mutating the packet.
      _messageController.add(
        AirGridMessage.fromPacket(
          packet,
          localNodeId,
          conversationType: packet.conversationType,
          peerNodeId: isPrivate ? packet.senderNodeId : null,
          peerName: isPrivate ? packet.senderName : null,
        ),
      );
    }
    AirGridLogger.log(
      LogCategory.routing,
      'Accepted ${packet.messageId} from ${packet.senderName}',
    );

    // -- Rebroadcast (public plaintext only) ----------------------------------
    if (isPrivate) {
      unawaited(_sendDeliveryReceipt(packet, fromEndpointId));
      return;
    }
    // Assembled packets were already distributed as fragments; skip relay.
    if (fromAssembly) return;
    if (!_shouldAcceptFromNode(packet.senderNodeId)) return;

    final decision = RelayController.decide(
      packetType: packet.packetType,
      isDirectedEncrypted: false,
      peerCount: _peers.length,
      currentHopLimit: packet.hopLimit,
    );
    if (!decision.shouldRelay) return;

    final forwardPacket = packet.copyWith(
      seenByNodes: [...packet.seenByNodes, localNodeId],
      hopLimit: decision.newHopLimit,
    );

    final targets = _transport.connectedEndpoints
        .where((id) => id != fromEndpointId)
        .toList();

    if (targets.isNotEmpty) {
      final delayMs = _jitterOverrideMs ?? decision.delayMs;
      void send() {
        final encoded = TransportCodec.encode(forwardPacket);
        _transport.sendToEndpoints(targets, encoded);
        AirGridLogger.log(
          LogCategory.rebroadcast,
          'Rebroadcast ${packet.messageId} -> ${targets.length} peer(s) '
          'after ${delayMs}ms',
        );
      }

      if (delayMs == 0) {
        send();
      } else {
        Future.delayed(Duration(milliseconds: delayMs), send);
      }
    }
  }

  // -- Key-announce handling ------------------------------------------------

  void _handleLocationUpdate(AirGridPacket packet, String fromEndpointId) {
    try {
      final map = jsonDecode(packet.content) as Map<String, dynamic>;
      final location = PeerLocation.fromJson(map);
      if (location.nodeId != packet.senderNodeId) {
        AirGridLogger.log(
          LogCategory.validation,
          '${packet.messageId} dropped: location node mismatch',
        );
        return;
      }
      _locationController.add(location);
      AirGridLogger.log(
        LogCategory.routing,
        'Accepted location_update from ${packet.senderName}',
      );
    } catch (_) {
      AirGridLogger.log(
        LogCategory.validation,
        '${packet.messageId} dropped: malformed location_update',
      );
      return;
    }

    if (!_shouldAcceptFromNode(packet.senderNodeId)) return;

    final decision = RelayController.decide(
      packetType: packet.packetType,
      isDirectedEncrypted: false,
      peerCount: _peers.length,
      currentHopLimit: packet.hopLimit,
    );
    if (!decision.shouldRelay) return;

    final forwardPacket = packet.copyWith(
      seenByNodes: [...packet.seenByNodes, _identity.nodeId],
      hopLimit: decision.newHopLimit,
    );
    final targets = _transport.connectedEndpoints
        .where((id) => id != fromEndpointId)
        .toList();
    if (targets.isEmpty) return;

    final delayMs = _jitterOverrideMs ?? decision.delayMs;
    void send() {
      final encoded = TransportCodec.encode(forwardPacket);
      _transport.sendToEndpoints(targets, encoded);
      AirGridLogger.log(
        LogCategory.rebroadcast,
        'Rebroadcast location_update ${packet.messageId} '
        'to ${targets.length} peer(s) after ${delayMs}ms',
      );
    }

    if (delayMs == 0) {
      send();
    } else {
      Future.delayed(Duration(milliseconds: delayMs), send);
    }
  }

  Future<AirGridMessage?> _buildImageMessage(
    AirGridPacket packet,
    String localNodeId,
    String wireContent, {
    required bool isPrivate,
  }) async {
    if (wireContent.length > AirGridConstants.kPrivatePhotoMaxWireBytes) {
      return null;
    }

    final payload = ImageAttachmentPayload.fromWire(wireContent);
    if (payload == null) {
      return null;
    }
    if (payload.byteLength > AirGridConstants.kPrivatePhotoMaxBytes) {
      return null;
    }

    String? mediaPath;
    try {
      mediaPath = await _mediaCache.writeImageBytes(
        payload.transferId,
        payload.bytes,
        extension: _extensionForMime(payload.mimeType),
      );
    } catch (_) {
      mediaPath = null;
    }

    return AirGridMessage.fromPacket(
      packet.copyWith(content: '[photo]'),
      localNodeId,
      conversationType: packet.conversationType,
      peerNodeId: isPrivate ? packet.senderNodeId : null,
      peerName: isPrivate ? packet.senderName : null,
      messageKind: 'image',
      mediaMimeType: payload.mimeType,
      mediaByteLength: payload.byteLength,
      mediaWidth: payload.width,
      mediaHeight: payload.height,
      mediaTransferId: payload.transferId,
      mediaTempPath: mediaPath,
      mediaPreviewBase64: mediaPath == null ? payload.dataBase64 : null,
    );
  }

  Future<AirGridMessage?> _buildAudioMessage(
    AirGridPacket packet,
    String localNodeId,
    String wireContent, {
    required bool isPrivate,
  }) async {
    if (wireContent.length > AirGridConstants.kPrivateVoiceNoteMaxWireBytes) {
      return null;
    }

    final payload = AudioAttachmentPayload.fromWire(wireContent);
    if (payload == null) {
      return null;
    }
    if (payload.byteLength > AirGridConstants.kPrivateVoiceNoteMaxBytes) {
      return null;
    }

    String? mediaPath;
    try {
      mediaPath = await _mediaCache.writeAudioBytes(
        payload.transferId,
        payload.bytes,
        extension: _audioExtensionForMime(payload.mimeType),
      );
    } catch (_) {
      mediaPath = null;
    }

    return AirGridMessage.fromPacket(
      packet.copyWith(
        content: payload.source == AudioAttachmentPayload.sourceWalkie
            ? '[walkie]'
            : '[voice]',
      ),
      localNodeId,
      conversationType: packet.conversationType,
      peerNodeId: isPrivate ? packet.senderNodeId : null,
      peerName: isPrivate ? packet.senderName : null,
      messageKind: 'audio',
      mediaMimeType: payload.mimeType,
      mediaByteLength: payload.byteLength,
      mediaTransferId: payload.transferId,
      mediaDurationMs: payload.durationMs,
      mediaTempPath: mediaPath,
    );
  }

  Future<AirGridMessage?> _buildFileMessage(
    AirGridPacket packet,
    String localNodeId,
    String wireContent, {
    required bool isPrivate,
  }) async {
    // Bound the decode before allocating, mirroring the photo and voice-note
    // paths. Remote input is untrusted: reject, do not sanitise.
    if (wireContent.length > AirGridConstants.kPrivateFileMaxWireBytes) {
      AirGridLogger.log(
        LogCategory.validation,
        'File envelope rejected: ${wireContent.length} bytes exceeds '
        'kPrivateFileMaxWireBytes',
      );
      return null;
    }

    final payload = FileAttachmentPayload.fromWire(wireContent);
    if (payload == null) {
      return null;
    }

    if (payload.byteLength > AirGridConstants.kPrivateFileMaxBytes) {
      AirGridLogger.log(
        LogCategory.validation,
        'File rejected: ${payload.byteLength} bytes exceeds '
        'kPrivateFileMaxBytes',
      );
      return null;
    }

    String? mediaPath;
    try {
      mediaPath = await _mediaCache.writeFileBytes(
        payload.transferId,
        payload.bytes,
        fileName: payload.fileName,
      );
    } catch (_) {
      mediaPath = null;
    }

    return AirGridMessage.fromPacket(
      packet.copyWith(content: '[file]'),
      localNodeId,
      conversationType: packet.conversationType,
      peerNodeId: isPrivate ? packet.senderNodeId : null,
      peerName: isPrivate ? packet.senderName : null,
      messageKind: 'file',
      mediaMimeType: payload.mimeType,
      mediaByteLength: payload.byteLength,
      mediaTransferId: payload.transferId,
      mediaTempPath: mediaPath,
    );
  }

  String _extensionForMime(String mimeType) {
    if (mimeType == 'image/png') return 'png';
    if (mimeType == 'image/webp') return 'webp';
    return 'jpg';
  }

  String _audioExtensionForMime(String mimeType) {
    if (mimeType == 'audio/mpeg' || mimeType == 'audio/mp3') return 'mp3';
    if (mimeType == 'audio/ogg') return 'ogg';
    if (mimeType == 'audio/aac') return 'aac';
    return 'm4a';
  }

  // -- Fragment handling ----------------------------------------------------

  void _handleFragment(AirGridPacket fragment, String fromEndpointId) {
    final origId = fragment.fragmentOf;
    final idx = fragment.fragmentIndex;
    final count = fragment.fragmentCount;

    if (origId == null ||
        idx == null ||
        count == null ||
        count < 1 ||
        idx < 0 ||
        idx >= count) {
      AirGridLogger.log(
        LogCategory.validation,
        '${fragment.messageId} dropped: malformed fragment fields',
      );
      return;
    }

    // Relay dedup: have we already forwarded this specific chunk?
    if (_fragmentCache.contains(fragment.messageId)) {
      AirGridLogger.log(
        LogCategory.dedup,
        '${fragment.messageId} dropped: duplicate fragment chunk',
      );
      return;
    }
    _fragmentCache.add(fragment.messageId);

    // Relay the chunk if eligible.
    if (fragment.isRelayEligible) {
      final decision = RelayController.decide(
        packetType: fragment.packetType,
        isDirectedEncrypted: fragment.encryptionVersion != null,
        peerCount: _peers.length,
        currentHopLimit: fragment.hopLimit,
      );
      if (decision.shouldRelay) {
        final targets = _transport.connectedEndpoints
            .where((id) => id != fromEndpointId)
            .toList();
        if (targets.isNotEmpty) {
          final forwardFrag = fragment.copyWith(
            seenByNodes: [...fragment.seenByNodes, _identity.nodeId],
            hopLimit: decision.newHopLimit,
          );
          final delayMs = _jitterOverrideMs ?? decision.delayMs;
          void send() {
            _transport.sendToEndpoints(
              targets,
              TransportCodec.encode(forwardFrag),
            );
            AirGridLogger.log(
              LogCategory.rebroadcast,
              'Relayed fragment ${fragment.messageId} '
              '(${idx + 1}/$count of $origId) -> ${targets.length} peer(s)',
            );
          }

          if (delayMs == 0) {
            send();
          } else {
            Future.delayed(Duration(milliseconds: delayMs), send);
          }
        }
      }
    }

    // Attempt reassembly only for packets addressed to us (or public).
    final isForUs =
        fragment.conversationType == 'public' ||
        fragment.recipientNodeId == null ||
        fragment.recipientNodeId == _identity.nodeId;
    if (!isForUs) return;

    final assembled = _fragmenter.tryReassemble(fragment);
    if (assembled != null) {
      AirGridLogger.log(
        LogCategory.routing,
        'Reassembled $origId from $count fragment(s)',
      );
      unawaited(
        _onPacketReceived(
          fromEndpointId,
          TransportCodec.encode(assembled),
          fromAssembly: true,
        ),
      );
    }
  }

  /// Helper: marks a direct peer as ready for encryption.
  /// Updates [_endpointToNodeId], enriches the peer, and emits [peerStream]
  /// if the peer's state changed.
  void _markDirectPeerReady(String endpointId, String nodeId) {
    if (!_peers.containsKey(endpointId)) return;

    final oldPeer = _peers[endpointId]!;
    if (oldPeer.nodeId == nodeId && oldPeer.encryptionReady) {
      // No change - peer already has this nodeId and is ready.
      return;
    }

    // Update mapping and peer state.
    _endpointToNodeId[endpointId] = nodeId;
    _peers[endpointId] = oldPeer.copyWith(
      nodeId: nodeId,
      encryptionReady: true,
    );
    _peerController.add(peers);
    unawaited(_flushSpool(nodeId, preferredEndpointId: endpointId));

    // Update the known contact's direct endpoint now that identity is confirmed.
    final contact = _contactStore.contacts
        .where((c) => c.nodeId == nodeId)
        .firstOrNull;
    if (contact != null) {
      unawaited(
        _contactStore.upsert(
          contact.copyWith(
            lastEndpointId: endpointId,
            lastSeenAt: DateTime.now(),
          ),
        ),
      );
    }
  }

  // -- Encrypted private relay + store-and-forward --------------------------

  /// Relays an encrypted private packet not addressed to this node.
  ///
  /// Delivery priority:
  /// 1. Direct delivery if the recipient is a currently connected endpoint.
  /// 2. Controlled flood relay to other peers via [RelayController].
  /// 3. Spool for later delivery if no route is available right now.
  void _relayOrSpoolPrivate(AirGridPacket packet, String fromEndpointId) {
    final rid = packet.recipientNodeId!;
    final isReceipt =
        packet.packetType == 'delivery_receipt' ||
        packet.packetType == 'read_receipt';
    final dedupCache = isReceipt ? _relayedReceiptCache : _messageCache;

    // Dedup: relay each encrypted private packet at most once.
    if (dedupCache.contains(packet.messageId)) {
      AirGridLogger.log(
        LogCategory.dedup,
        '${packet.messageId} dropped: duplicate private relay',
      );
      return;
    }
    dedupCache.add(packet.messageId);

    // Priority 1: recipient is directly connected.
    final recipientEndpoint = _endpointToNodeId.entries
        .where((e) => e.value == rid)
        .map((e) => e.key)
        .firstOrNull;
    if (recipientEndpoint != null && recipientEndpoint != fromEndpointId) {
      for (final outgoing in PacketFragmenter.fragment(packet)) {
        _transport.sendToEndpoints([
          recipientEndpoint,
        ], TransportCodec.encode(outgoing));
      }
      AirGridLogger.log(
        LogCategory.routing,
        'Forwarded private ${packet.messageId} direct to $rid',
      );
      return;
    }

    // Priority 2: relay via flooding.
    final decision = RelayController.decide(
      packetType: packet.packetType,
      isDirectedEncrypted: true,
      peerCount: _peers.length,
      currentHopLimit: packet.hopLimit,
    );
    final targets = _transport.connectedEndpoints
        .where((id) => id != fromEndpointId)
        .toList();
    if (targets.isNotEmpty && decision.shouldRelay) {
      final localNodeId = _identity.nodeId;
      final forwardPacket = packet.copyWith(
        seenByNodes: [...packet.seenByNodes, localNodeId],
        hopLimit: decision.newHopLimit,
      );
      final delayMs = _jitterOverrideMs ?? decision.delayMs;
      void send() {
        _transport.sendToEndpoints(
          targets,
          TransportCodec.encode(forwardPacket),
        );
        AirGridLogger.log(
          LogCategory.rebroadcast,
          'Relayed private ${packet.messageId} to ${targets.length} peer(s)',
        );
      }

      if (delayMs == 0) {
        send();
      } else {
        Future.delayed(Duration(milliseconds: delayMs), send);
      }
      return;
    }

    // Priority 3: spool for later delivery.
    _spoolPacket(packet);
  }

  /// Adds [packet] to the store-and-forward spool for later delivery.
  ///
  /// Enforces [AirGridConstants.kSpoolMaxEntries] capacity and prunes any
  /// expired entries before inserting.
  /// Returns true when the packet was accepted into the spool.
  ///
  /// Returns false for packets that can never be delivered — currently only
  /// packets too large to encode. Callers that report delivery status must
  /// not claim success when this returns false.
  bool _spoolPacket(AirGridPacket packet) {
    final rid = packet.recipientNodeId!;
    final ttl = const Duration(seconds: AirGridConstants.kSpoolTtlSeconds);

    // Backstop: never admit a packet the codec will reject. Spooling one
    // guarantees a retry loop that can never drain, because every flush
    // re-encodes and re-throws.
    if (!_isEncodable(packet)) {
      AirGridLogger.log(
        LogCategory.routing,
        '${packet.messageId} not spooled: exceeds kMaxPacketBytes',
      );
      return false;
    }

    // Prune expired entries across all recipients before inserting.
    for (final entries in _spool.values) {
      entries.removeWhere((e) => e.isExpired(ttl, clock: _spoolClock));
    }
    _spool.removeWhere((_, entries) => entries.isEmpty);

    // Enforce total capacity.
    final total = _spool.values.fold(0, (sum, list) => sum + list.length);
    if (total >= AirGridConstants.kSpoolMaxEntries) {
      AirGridLogger.log(
        LogCategory.routing,
        '${packet.messageId} dropped: spool at capacity '
        '(${AirGridConstants.kSpoolMaxEntries})',
      );
      return false;
    }

    _spool
        .putIfAbsent(rid, () => [])
        .add(_SpoolEntry(packet, clock: _spoolClock));
    AirGridLogger.log(
      LogCategory.routing,
      'Spooled ${packet.messageId} for $rid '
      '(${_spool[rid]!.length} queued)',
    );

    // If we already have a direct route right now, retry immediately.
    final endpointId = _endpointToNodeId.entries
        .where((e) => e.value == rid)
        .map((e) => e.key)
        .firstOrNull;
    if (endpointId != null) {
      unawaited(_flushSpool(rid, preferredEndpointId: endpointId));
    }
    return true;
  }

  /// Whether [packet] can be serialised within
  /// [AirGridConstants.kMaxPacketBytes].
  ///
  /// Fragmentation encodes the whole packet before splitting, so an oversize
  /// packet is undeliverable regardless of the fragment threshold.
  bool _isEncodable(AirGridPacket packet) {
    try {
      TransportCodec.encode(packet);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  /// Delivers all spooled packets for [recipientNodeId] to [endpointId]
  /// and removes them from the spool.
  ///
  /// Called from [_markDirectPeerReady] when a direct peer is fully identified.
  Future<void> _flushSpool(
    String recipientNodeId, {
    String? preferredEndpointId,
  }) async {
    final entries = _spool[recipientNodeId];
    if (entries == null || entries.isEmpty) return;

    final connected = _transport.connectedEndpoints.toList();
    final mappedEndpoints = _endpointToNodeId.entries
        .where((e) => e.value == recipientNodeId)
        .map((e) => e.key)
        .toList();
    final targets = <String>[];

    if (preferredEndpointId != null &&
        connected.contains(preferredEndpointId)) {
      targets.add(preferredEndpointId);
    }
    for (final id in mappedEndpoints) {
      if (connected.contains(id) && !targets.contains(id)) {
        targets.add(id);
      }
    }
    for (final id in connected) {
      if (!targets.contains(id)) {
        targets.add(id);
      }
    }

    if (targets.isEmpty) {
      return;
    }

    final ttl = const Duration(seconds: AirGridConstants.kSpoolTtlSeconds);
    final valid = entries
        .where((e) => !e.isExpired(ttl, clock: _spoolClock))
        .toList();
    if (valid.isEmpty) {
      _spool.remove(recipientNodeId);
      return;
    }

    final remaining = <_SpoolEntry>[];

    for (final entry in valid) {
      var delivered = false;
      String? deliveredVia;

      for (final endpointId in targets) {
        try {
          await _sendPacketFragments(entry.packet, [endpointId]);
          delivered = true;
          deliveredVia = endpointId;
          break;
        } catch (_) {
          // Try the next candidate endpoint.
        }
      }

      if (delivered) {
        AirGridLogger.log(
          LogCategory.routing,
          'Flushed spooled ${entry.packet.messageId} to $recipientNodeId '
          'via $deliveredVia',
        );
      } else {
        remaining.add(entry);
        AirGridLogger.log(
          LogCategory.routing,
          'Flush failed for spooled ${entry.packet.messageId} to $recipientNodeId; keeping queued',
        );
      }
    }

    if (remaining.isEmpty) {
      _spool.remove(recipientNodeId);
    } else {
      _spool[recipientNodeId] = remaining;
    }
  }

  Future<void> _flushAllSpooled() async {
    if (_isFlushingSpool || _spool.isEmpty) {
      return;
    }

    _isFlushingSpool = true;
    try {
      final recipients = _spool.keys.toList();
      for (final recipientNodeId in recipients) {
        await _flushSpool(recipientNodeId);
      }
    } finally {
      _isFlushingSpool = false;
    }
  }

  void _handleKeyAnnounce(AirGridPacket packet, String fromEndpointId) {
    final publicKeyB64 = packet.senderPublicKey;
    if (publicKeyB64 == null || publicKeyB64.isEmpty) {
      AirGridLogger.log(
        LogCategory.validation,
        'key_announce from ${packet.senderNodeId} missing public key - dropped',
      );
      return;
    }

    // Determine if this is a direct-peer announce BEFORE dedup check.
    final isDirect =
        _peers.containsKey(fromEndpointId) &&
        packet.seenByNodes.length == 1 &&
        packet.seenByNodes.first == packet.senderNodeId;

    // key_announce dedup: keyed on "nodeId:publicKeyB64".
    final cacheKey = '${packet.senderNodeId}:$publicKeyB64';
    final isDuplicate = _keyAnnounceCache.contains(cacheKey);

    if (!isDuplicate) {
      _keyAnnounceCache.add(cacheKey);
    }

    // Cache the public key for future opportunistic encryption.
    _cryptoService.cacheKey(packet.senderNodeId, publicKeyB64);

    final profileMeta = _parseKeyAnnounceProfileMeta(packet.content);

    // Persist/update the known contact. The direct endpoint (if any) is set
    // later in _markDirectPeerReady once identity is confirmed.
    unawaited(
      _contactStore.upsert(
        KnownContact(
          nodeId: packet.senderNodeId,
          displayName: packet.senderName,
          profileIconId: profileMeta.iconId,
          profileStatus: profileMeta.status,
          publicKeyBase64: publicKeyB64,
          lastSeenAt: DateTime.now(),
        ),
      ),
    );

    // Enrich direct peers regardless of dedup status - they may arrive in any order.
    if (isDirect) {
      _markDirectPeerReady(fromEndpointId, packet.senderNodeId);
    }

    // Check key announce cooldown AFTER direct peer enrichment to prevent
    // rebroadcast spam, but still allow identity updates for direct connections.
    if (!_keyAnnounceCooldown.shouldAccept(packet.senderNodeId, publicKeyB64)) {
      AirGridLogger.log(
        LogCategory.routing,
        'key_announce for ${packet.senderNodeId} suppressed: cooldown active',
      );
      return;
    }

    // Suppress duplicate rebroadcast (no matter if direct or relayed).
    if (isDuplicate) {
      AirGridLogger.log(
        LogCategory.dedup,
        'key_announce for ${packet.senderNodeId} dropped: duplicate',
      );
      return;
    }

    AirGridLogger.log(
      LogCategory.routing,
      'Cached public key for ${packet.senderNodeId}',
    );

    // Rebroadcast with jitter (excluding source endpoint).
    final decision = RelayController.decide(
      packetType: packet.packetType,
      isDirectedEncrypted: false,
      peerCount: _peers.length,
      currentHopLimit: packet.hopLimit,
    );
    if (!decision.shouldRelay) return;
    final targets = _transport.connectedEndpoints
        .where((id) => id != fromEndpointId)
        .toList();
    if (targets.isNotEmpty) {
      final forwardPacket = packet.copyWith(
        seenByNodes: [...packet.seenByNodes, _identity.nodeId],
        hopLimit: decision.newHopLimit,
      );
      final delayMs = _jitterOverrideMs ?? decision.delayMs;
      void send() {
        final encoded = TransportCodec.encode(forwardPacket);
        _transport.sendToEndpoints(targets, encoded);
        AirGridLogger.log(
          LogCategory.rebroadcast,
          'Rebroadcast key_announce for ${packet.senderNodeId} '
          '-> ${targets.length} peer(s) after ${delayMs}ms',
        );
      }

      if (delayMs == 0) {
        send();
      } else {
        Future.delayed(Duration(milliseconds: delayMs), send);
      }
    }
  }

  _KeyAnnounceProfileMeta _parseKeyAnnounceProfileMeta(String rawContent) {
    if (rawContent.trim().isEmpty) {
      return const _KeyAnnounceProfileMeta();
    }

    try {
      final decoded = jsonDecode(rawContent);
      if (decoded is! Map<String, dynamic>) {
        return const _KeyAnnounceProfileMeta();
      }

      final iconRaw = decoded['profileIconId'];
      final statusRaw = decoded['profileStatus'];

      String? iconId;
      String? status;

      if (iconRaw is String) {
        final trimmed = iconRaw.trim();
        if (trimmed.isNotEmpty && trimmed.length <= 40) {
          iconId = trimmed;
        }
      }

      if (statusRaw is String) {
        final trimmed = statusRaw.trim();
        if (trimmed.isNotEmpty) {
          status = trimmed.length > 80 ? trimmed.substring(0, 80) : trimmed;
        }
      }

      return _KeyAnnounceProfileMeta(iconId: iconId, status: status);
    } catch (_) {
      return const _KeyAnnounceProfileMeta();
    }
  }

  Future<AirGridPacket> _buildReceiptPacket({
    required String packetType,
    required String recipientNodeId,
    required String receiptMessageId,
  }) async {
    final localNodeId = _identity.nodeId;
    final senderPublicKey = _identity.publicKeyBase64;
    var content = '';
    int? encryptionVersion;
    String? wireReceiptMessageId = receiptMessageId;
    var hopLimit = 1;

    if (senderPublicKey != null && _cryptoService.hasKey(recipientNodeId)) {
      final cipher = await _cryptoService.encryptContent(
        receiptMessageId,
        recipientNodeId,
      );
      if (cipher != null) {
        content = cipher;
        encryptionVersion = 1;
        wireReceiptMessageId = null;
        hopLimit = AirGridConstants.kHopLimit;
      }
    }

    return AirGridPacket(
      messageId: const Uuid().v4(),
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: content,
      seenByNodes: [localNodeId],
      hopLimit: hopLimit,
      packetType: packetType,
      senderPublicKey: encryptionVersion != null ? senderPublicKey : null,
      encryptionVersion: encryptionVersion,
      conversationType: 'private',
      recipientNodeId: recipientNodeId,
      receiptMessageId: wireReceiptMessageId,
    );
  }

  Future<void> _sendPrivateControlPacket(
    AirGridPacket packet, {
    String? preferredEndpointId,
  }) async {
    final rid = packet.recipientNodeId;
    if (rid == null) return;

    final directEndpoint = _endpointToNodeId.entries
        .where((e) => e.value == rid)
        .map((e) => e.key)
        .firstOrNull;

    if (packet.encryptionVersion != null) {
      final targets = directEndpoint != null
          ? <String>[directEndpoint]
          : _transport.connectedEndpoints.toList();

      if (targets.isEmpty) {
        _spoolPacket(packet);
        return;
      }

      for (final outgoing in PacketFragmenter.fragment(packet)) {
        await _transport.sendToEndpoints(
          targets,
          TransportCodec.encode(outgoing),
        );
      }
      return;
    }

    final plaintextTarget = directEndpoint ?? preferredEndpointId;
    if (plaintextTarget == null) return;
    await _transport.sendToEndpoints([
      plaintextTarget,
    ], TransportCodec.encode(packet));
  }

  /// Sends [read_receipt] packets to [peerNodeId] for each of [messageIds].
  ///
  /// Called when the user opens a private conversation. Best-effort;
  /// individual send failures are silently ignored.
  Future<void> sendReadReceipts(
    String peerNodeId,
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;

    // Rate limit read receipt batches per peer
    if (!_receiptBatchLimiters.allow(peerNodeId)) {
      final retryAfter = _receiptBatchLimiters.retryAfter(peerNodeId);
      AirGridLogger.log(
        LogCategory.routing,
        'Read receipt batch to $peerNodeId rate limited '
        '(retry after ${retryAfter.inMilliseconds}ms)',
      );
      return;
    }

    final directEndpointId = _endpointToNodeId.entries
        .where((e) => e.value == peerNodeId)
        .map((e) => e.key)
        .firstOrNull;

    for (final msgId in messageIds) {
      final receipt = await _buildReceiptPacket(
        packetType: 'read_receipt',
        recipientNodeId: peerNodeId,
        receiptMessageId: msgId,
      );
      try {
        await _sendPrivateControlPacket(
          receipt,
          preferredEndpointId: directEndpointId,
        );
      } catch (_) {
        // best effort
      }
    }
    AirGridLogger.log(
      LogCategory.routing,
      'Sent ${messageIds.length} read receipt(s) to $peerNodeId',
    );
  }

  Future<void> _handleReceipt(AirGridPacket packet) async {
    var receiptMessageId = packet.receiptMessageId;
    if (packet.encryptionVersion != null) {
      if (packet.encryptionVersion != 1 || packet.senderPublicKey == null) {
        AirGridLogger.log(
          LogCategory.validation,
          'Encrypted receipt ${packet.messageId} missing supported metadata',
        );
        return;
      }
      receiptMessageId = await _cryptoService.decryptContent(
        packet.content,
        packet.senderPublicKey!,
      );
    }

    if (receiptMessageId == null) {
      AirGridLogger.log(
        LogCategory.validation,
        'Receipt packet missing receiptMessageId - dropped',
      );
      return;
    }
    final canonicalMessageId =
        _receiptMessageAliases[receiptMessageId] ?? receiptMessageId;
    final status = packet.packetType == 'read_receipt'
        ? DeliveryStatus.read
        : DeliveryStatus.delivered;
    _statusController.add((messageId: canonicalMessageId, status: status));
    AirGridLogger.log(
      LogCategory.routing,
      'Receipt ${packet.packetType} for $canonicalMessageId '
      'from ${packet.senderName}',
    );
  }

  void _rememberReceiptAlias(String packetMessageId, String? localMessageId) {
    if (localMessageId == null || packetMessageId == localMessageId) {
      return;
    }

    _receiptMessageAliases[packetMessageId] = localMessageId;
    if (_receiptMessageAliases.length > 2000) {
      _receiptMessageAliases.remove(_receiptMessageAliases.keys.first);
    }
  }

  Future<void> _sendDeliveryReceipt(
    AirGridPacket originalPacket,
    String fromEndpointId,
  ) async {
    if (!_peers.containsKey(fromEndpointId)) return;
    final originalSenderPublicKey = originalPacket.senderPublicKey;
    if (originalSenderPublicKey != null) {
      _cryptoService.cacheKey(
        originalPacket.senderNodeId,
        originalSenderPublicKey,
      );
    }
    final receipt = await _buildReceiptPacket(
      packetType: 'delivery_receipt',
      recipientNodeId: originalPacket.senderNodeId,
      receiptMessageId: originalPacket.messageId,
    );
    try {
      await _sendPrivateControlPacket(
        receipt,
        preferredEndpointId: fromEndpointId,
      );
      AirGridLogger.log(
        LogCategory.routing,
        'Sent delivery_receipt for ${originalPacket.messageId} '
        'to $fromEndpointId',
      );
    } catch (_) {
      // best effort
    }
  }
}
