import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/foreground_service_bridge.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/core/validation.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/transport/nearby_connections_transport.dart';
import 'package:airgrid/data/transport/transport_event.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/local_report.dart';
import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/models/peer_location.dart';
import 'package:airgrid/domain/models/privacy_mode.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/domain/services/transport_service.dart';
import 'package:airgrid/features/chat/chat_state.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

// ── Providers ──────────────────────────────────────────────────────────────

/// Override in main.dart after async [LocalIdentityStore.create()].
final localIdentityStoreProvider = Provider<LocalIdentityStore>(
  (ref) => throw UnimplementedError(),
);

/// Override in main.dart after [SqliteMessageRepository.open()].
final messageRepositoryProvider = Provider<MessageRepository>(
  (ref) => throw UnimplementedError(),
);

final transportServiceProvider = Provider<TransportService>((ref) {
  final transport = NearbyConnectionsTransport();
  ref.onDispose(transport.stop);
  return transport;
});

final playServicesProvider = Provider<PlayServicesAvailability>(
  (ref) => const PlayServicesBridge(),
);

final foregroundServiceProvider = Provider<MeshForegroundService>(
  (ref) => const ForegroundServiceBridge(),
);

/// Override in main.dart after [CryptoService.loadLocalKeyPair] completes.
final cryptoServiceProvider = Provider<CryptoService>(
  (ref) => throw UnimplementedError(),
);

/// Override in main.dart after [SharedPrefsKnownContactStore.create()] completes.
final knownContactStoreProvider = Provider<KnownContactStore>(
  (ref) => throw UnimplementedError(),
);

/// Override in main.dart after [SharedPrefsLocalReportStore.create()] completes.
final localReportStoreProvider = Provider<LocalReportStore>(
  (ref) => throw UnimplementedError(),
);

/// Override in main.dart after [SharedPrefsPrivacySettingsStore.create()] completes.
final privacySettingsStoreProvider = Provider<PrivacySettingsStore>(
  (ref) => throw UnimplementedError(),
);

final batterySettingsStoreProvider = Provider<BatterySettingsStore>(
  (ref) => throw UnimplementedError(),
);

final meshServiceProvider = Provider<AirGridMeshService>((ref) {
  final transport = ref.watch(transportServiceProvider);
  final identity = ref.watch(localIdentityStoreProvider);
  final crypto = ref.watch(cryptoServiceProvider);
  final contactStore = ref.watch(knownContactStoreProvider);
  final privacyStore = ref.watch(privacySettingsStoreProvider);
  final service = AirGridMeshService(
    transport,
    identity,
    crypto,
    contactStore: contactStore,
    privacyStore: privacyStore,
  );
  ref.onDispose(service.dispose);
  return service;
});

final chatControllerProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);

// ── Controller ─────────────────────────────────────────────────────────────

const _locationUpdateMinInterval = Duration(seconds: 45);
const _locationUpdateDistanceFilterMeters = 25;
const _locationAccuracy = LocationAccuracy.low;

class _AutomaticImageRetryState {
  _AutomaticImageRetryState({
    this.attempts = 0,
    this.inFlight = false,
    this.timer,
  });

  int attempts;
  bool inFlight;
  Timer? timer;

  void cancel() {
    timer?.cancel();
    timer = null;
    inFlight = false;
  }
}

class ChatController extends Notifier<ChatState> {
  static Duration automaticImageAckTimeout = const Duration(seconds: 12);
  static Duration automaticImageRetryBackoff = const Duration(seconds: 4);
  static Duration automaticImageRetryStartupGrace = const Duration(minutes: 10);
  static int automaticImageRetryMaxAttempts = 2;
  static Duration imageRetryPeerOnlineTimeout = const Duration(seconds: 10);
  static Duration imageRetryPeerOnlinePollInterval = const Duration(
    milliseconds: 200,
  );
  static Duration imageRetryPeerOnlineSettleDelay = const Duration(seconds: 3);
  static Duration imageRetrySecondAttemptDelay = const Duration(
    milliseconds: 700,
  );
  static Duration imageRetrySecondAttemptTimeout = const Duration(seconds: 4);
  static Duration imageRetrySecondAttemptSettleDelay = const Duration(
    seconds: 1,
  );

  StreamSubscription<dynamic>? _messageSub;
  StreamSubscription<dynamic>? _peerSub;
  StreamSubscription<dynamic>? _locationSub;
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<dynamic>? _transportEventSub;
  StreamSubscription<dynamic>? _statusSub;
  StreamSubscription<dynamic>? _contactsSub;
  StreamSubscription<void>? _foregroundExitSub;
  bool _isStarting = false;
  int _foregroundCriticalActions = 0;
  bool _batterySettingLoaded = false;
  bool _stoppedByBatteryOptimization = false;
  DateTime? _lastLocationPublishAt;

  /// Endpoint IDs of currently connected peers, tracked to detect new joins.
  var _connectedPeerEndpoints = <String>{};
  Timer? _pruneTimer;
  final Map<String, _AutomaticImageRetryState> _automaticImageRetries = {};

  @override
  ChatState build() {
    // Register disposal callback to prevent subscription/timer leaks
    ref.onDispose(() {
      _messageSub?.cancel();
      _peerSub?.cancel();
      _locationSub?.cancel();
      _positionSub?.cancel();
      _transportEventSub?.cancel();
      _statusSub?.cancel();
      _contactsSub?.cancel();
      _foregroundExitSub?.cancel();
      _pruneTimer?.cancel();
      _cancelAllAutomaticImageRetries();
    });
    unawaited(_loadBatteryOptimizationSetting());
    return const ChatState.initial();
  }

  AirGridMeshService get _mesh => ref.read(meshServiceProvider);
  TransportService get _transport => ref.read(transportServiceProvider);
  PlayServicesAvailability get _playServices => ref.read(playServicesProvider);
  MeshForegroundService get _foreground => ref.read(foregroundServiceProvider);
  LocalIdentityStore get _identity => ref.read(localIdentityStoreProvider);
  MessageRepository get _repo => ref.read(messageRepositoryProvider);
  KnownContactStore get _contactStore => ref.read(knownContactStoreProvider);
  LocalReportStore get _reportStore => ref.read(localReportStoreProvider);
  PrivacySettingsStore get _privacyStore =>
      ref.read(privacySettingsStoreProvider);
  BatterySettingsStore get _batteryStore =>
      ref.read(batterySettingsStoreProvider);

  Future<void> _loadBatteryOptimizationSetting() async {
    if (_batterySettingLoaded) return;
    _batterySettingLoaded = true;
    final batteryOptimizationEnabled = await _batteryStore
        .getBatteryOptimizationEnabled();
    state = state.copyWith(
      batteryOptimizationEnabled: batteryOptimizationEnabled,
    );
  }

  Future<void> startMesh({bool forceRestart = false}) async {
    if (_isStarting || (state.meshStarted && !forceRestart)) {
      return;
    }
    _isStarting = true;
    _stoppedByBatteryOptimization = false;
    state = state.copyWith(isMeshStarting: true);

    try {
      await _loadBatteryOptimizationSetting();
      await _messageSub?.cancel();
      await _peerSub?.cancel();
      await _locationSub?.cancel();
      await _transportEventSub?.cancel();
      await _statusSub?.cancel();
      await _contactsSub?.cancel();
      await _foregroundExitSub?.cancel();

      final playServices = await _playServices.checkAvailability();
      if (!playServices.available) {
        state = state.copyWith(
          meshStarted: false,
          isMeshStarting: false,
          isAdvertising: false,
          isDiscovering: false,
          peers: [],
          playServicesAvailable: false,
          playServicesCode: playServices.code,
          playServicesMessage: playServices.displayMessage,
          playServicesCanResolve: playServices.canResolve,
          lastEvent: playServices.displayMessage,
        );
        return;
      }

      state = state.copyWith(
        playServicesAvailable: true,
        playServicesCode: playServices.code,
        playServicesMessage: playServices.displayMessage,
        playServicesCanResolve: playServices.canResolve,
      );

      _foregroundExitSub = _foreground.exitRequests.listen((_) {
        unawaited(stopMesh());
      });

      if (await _foreground.consumePendingExitAction()) {
        await stopMesh();
        return;
      }

      if (forceRestart && state.meshStarted) {
        state = state.copyWith(
          isAdvertising: false,
          isDiscovering: false,
          peers: [],
          lastEvent: 'Refreshing mesh connection',
        );
        await _transport.stop();
      }

      await _foreground.startMeshService();

      // Listen for transport-level start-failure (e.g. missing Play Services).
      _transportEventSub = _transport.events.listen((event) {
        if (event is TransportStartFailed) {
          state = state.copyWith(
            meshStarted: false,
            isAdvertising: false,
            isDiscovering: false,
            playServicesAvailable: false,
            lastEvent: 'Transport error: ${event.reason}',
          );
        }
      });

      await _transport.start(
        _identity.nodeId,
        _identity.displayName ?? 'Unknown',
      );

      state = state.copyWith(
        meshStarted: true,
        isAdvertising: true,
        isDiscovering: true,
        lastEvent: forceRestart ? 'Mesh refreshed' : 'Mesh started',
      );

      // Announce our public key to any peers already connected at startup.
      await _mesh.sendKeyAnnounce();

      // Load the persisted privacy mode.
      final privacyMode = await _privacyStore.getPrivacyMode();
      state = state.copyWith(privacyMode: privacyMode);

      _messageSub = _mesh.messageStream.listen((msg) async {
        // Drop messages from blocked contacts.
        if (state.blockedNodeIds.contains(msg.senderNodeId)) return;
        // Drop messages from non-trusted contacts in trusted-contacts-only mode.
        if (state.privacyMode == PrivacyMode.trustedContactsOnly &&
            !msg.isLocal &&
            !state.trustedNodeIds.contains(msg.senderNodeId)) {
          return;
        }
        if (state.messages.any((m) => m.id == msg.id)) {
          return;
        }
        final messageToSave = _withReadStateForIncomingMessage(msg);
        final updated = ([
          messageToSave,
          ...state.messages,
        ]).take(AirGridConstants.kChatMaxMessages).toList();
        final unread = _updatedUnreadCountsFor(messageToSave);
        state = state.copyWith(messages: updated, unreadPrivateCounts: unread);
        _restoreAutomaticImageRetryWatch(messageToSave);
        await _repo.save(messageToSave);
        // Schedule background/debounced pruning so bursts don't run deletes repeatedly.
        _schedulePrune();
        if (_shouldNotifyForPrivateMessage(msg)) {
          unawaited(
            _foreground.showPrivateMessageNotification(
              msg.peerName ?? msg.senderName,
            ),
          );
        }
        // If this private message arrives while the sender's thread is already
        // open, send a read receipt immediately instead of waiting for
        // selectConversation to be called again.
        final sel = state.selectedConversation;
        final peerNodeId = msg.peerNodeId;
        if (messageToSave.conversationType == 'private' &&
            !messageToSave.isLocal &&
            peerNodeId != null &&
            sel is PrivateConversation &&
            sel.peerNodeId == peerNodeId) {
          unawaited(_sendReadReceiptsFor(peerNodeId));
        }
      });

      _statusSub = _mesh.statusStream.listen((event) {
        _applyStatusUpdate(event.messageId, event.status);
        _handleAutomaticImageRetryStatus(event.messageId, event.status);
      });

      _contactsSub = _mesh.knownContactsStream.listen((contacts) {
        state = state.copyWith(knownContacts: contacts);
      });

      _locationSub = _mesh.locationStream.listen((location) {
        if (state.blockedNodeIds.contains(location.nodeId)) return;
        // Drop location from non-trusted contacts in trusted-contacts-only mode.
        if (state.privacyMode == PrivacyMode.trustedContactsOnly &&
            !state.trustedNodeIds.contains(location.nodeId)) {
          return;
        }
        final locations = Map<String, PeerLocation>.from(state.peerLocations)
          ..[location.nodeId] = location;
        state = state.copyWith(peerLocations: locations);
      });

      // Load persisted history only on initial start, not on force-restart.
      // Set up the live subscription first so no messages are missed during load.
      if (!forceRestart) {
        final history = await _repo.loadRecent();
        if (history.isNotEmpty) {
          final existingIds = state.messages.map((m) => m.id).toSet();
          final fresh = history
              .where((m) => !existingIds.contains(m.id))
              .toList();
          if (fresh.isNotEmpty) {
            final merged = [...state.messages, ...fresh];
            state = state.copyWith(
              messages: merged.take(AirGridConstants.kChatMaxMessages).toList(),
              unreadPrivateCounts: _unreadCountsFromMessages(merged),
            );
            _restoreAutomaticImageRetryWatches(state.messages);
          }
        }
        // Schedule background prune after loading history to enforce retention.
        _schedulePrune(immediate: true);
      }

      _peerSub = _mesh.peerStream.listen((peers) async {
        final currentEndpoints = peers.map((p) => p.endpointId).toSet();
        final hasNewPeers = currentEndpoints
            .difference(_connectedPeerEndpoints)
            .isNotEmpty;
        _connectedPeerEndpoints = currentEndpoints;

        if (hasNewPeers) {
          // Re-announce key whenever a new peer connects so they can cache it.
          await _mesh.sendKeyAnnounce();
        }

        // Filter out blocked peers before updating visible state.
        final blocked = state.blockedNodeIds;
        final trusted = state.trustedNodeIds;
        final isTrustedOnly =
            state.privacyMode == PrivacyMode.trustedContactsOnly;
        final visiblePeers = peers
            .where(
              (p) =>
                  (p.nodeId == null || !blocked.contains(p.nodeId!)) &&
                  (!isTrustedOnly ||
                      p.nodeId == null ||
                      trusted.contains(p.nodeId!)),
            )
            .toList();

        final selectedConversation = _resolveSelectedConversation(visiblePeers);
        final activeNodeIds = visiblePeers
            .map((p) => p.nodeId)
            .whereType<String>()
            .toSet();
        final peerLocations = Map<String, PeerLocation>.from(
          state.peerLocations,
        )..removeWhere((nodeId, _) => !activeNodeIds.contains(nodeId));
        state = state.copyWith(
          peers: visiblePeers,
          peerLocations: peerLocations,
          lastEvent: '${visiblePeers.length} peer(s) connected',
          selectedConversation: selectedConversation,
        );
        final localLocation = state.localLocation;
        if (hasNewPeers &&
            state.isLocationSharing &&
            visiblePeers.isNotEmpty &&
            localLocation != null) {
          unawaited(_shareLocation(localLocation, force: true));
        }
      });
    } catch (e) {
      await _transport.stop();
      await _foreground.stopMeshService();
      state = state.copyWith(
        meshStarted: false,
        isAdvertising: false,
        isDiscovering: false,
        peers: [],
        lastEvent: 'Mesh startup failed: $e',
      );
    } finally {
      _isStarting = false;
      state = state.copyWith(isMeshStarting: false);
    }
  }

  Future<void> refreshMeshAfterResume() async {
    if (!state.meshStarted) {
      return;
    }
    await startMesh(forceRestart: true);
  }

  Future<void> handleAppLifecycleState(AppLifecycleState lifecycleState) async {
    switch (lifecycleState) {
      case AppLifecycleState.resumed:
        await _loadBatteryOptimizationSetting();
        if (_stoppedByBatteryOptimization) {
          _stoppedByBatteryOptimization = false;
          await startMesh();
        } else {
          await refreshMeshAfterResume();
        }
        return;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
        await _loadBatteryOptimizationSetting();
        if (_foregroundCriticalActions > 0) {
          return;
        }
        if (state.batteryOptimizationEnabled && state.meshStarted) {
          _stoppedByBatteryOptimization = true;
          await stopMesh();
        }
        return;
      case AppLifecycleState.hidden:
        return;
    }
  }

  /// Marks a temporary foreground action where background lifecycle transitions
  /// should not stop mesh (for example opening image picker UI).
  void beginForegroundCriticalAction() {
    _foregroundCriticalActions++;
  }

  /// Ends a temporary foreground action started by
  /// [beginForegroundCriticalAction].
  void endForegroundCriticalAction() {
    if (_foregroundCriticalActions > 0) {
      _foregroundCriticalActions--;
    }
  }

  /// Waits for the mesh to come back online after temporary lifecycle churn.
  ///
  /// Returns true when the mesh becomes ready before [timeout] expires.
  Future<bool> waitForMeshReady({
    Duration timeout = const Duration(seconds: 15),
    Duration pollInterval = const Duration(milliseconds: 150),
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      if (!state.meshStarted && !_isStarting) {
        unawaited(startMesh());
      }

      if (state.meshStarted) {
        return true;
      }

      await Future<void>.delayed(pollInterval);
    }

    return state.meshStarted;
  }

  /// Waits for a specific peer/contact to appear online, then gives the
  /// connection a short settle window before the send proceeds.
  Future<bool> waitForPeerOnline(
    String nodeId, {
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 200),
    Duration settleDelay = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final peerReady = state.peers.any((peer) => peer.nodeId == nodeId);
      final contactReady = state.knownContacts.any(
        (contact) =>
            contact.nodeId == nodeId && contact.isDirectlyConnected,
      );

      if (peerReady || contactReady) {
        await Future<void>.delayed(settleDelay);
        return true;
      }

      if (!state.meshStarted && !_isStarting) {
        unawaited(startMesh());
      }

      await Future<void>.delayed(pollInterval);
    }

    return state.peers.any((peer) => peer.nodeId == nodeId) ||
        state.knownContacts.any(
          (contact) =>
              contact.nodeId == nodeId && contact.isDirectlyConnected,
        );
  }

  Future<void> stopMesh() async {
    _isStarting = false;
    _connectedPeerEndpoints = {};
    await _messageSub?.cancel();
    await _peerSub?.cancel();
    await _locationSub?.cancel();
    await _positionSub?.cancel();
    await _transportEventSub?.cancel();
    await _statusSub?.cancel();
    await _contactsSub?.cancel();
    await _foregroundExitSub?.cancel();
    _cancelAllAutomaticImageRetries();
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _foregroundExitSub = null;
    _lastLocationPublishAt = null;
    await _transport.stop();
    await _foreground.stopMeshService();
    state = state.copyWith(
      meshStarted: false,
      isMeshStarting: false,
      isAdvertising: false,
      isDiscovering: false,
      peers: [],
      isLocationSharing: false,
      clearLocalLocation: true,
      clearLocationStatus: true,
      lastEvent: 'Mesh stopped',
    );
  }

  Future<void> setAdvertisingEnabled(bool enabled) async {
    if (!state.meshStarted || !state.playServicesAvailable) return;
    if (enabled == state.isAdvertising) return;

    try {
      if (enabled) {
        await _transport.startAdvertising();
      } else {
        await _transport.stopAdvertising();
      }
      state = state.copyWith(
        isAdvertising: enabled,
        lastEvent: enabled ? 'Available enabled' : 'Available disabled',
      );
    } catch (e) {
      state = state.copyWith(lastEvent: 'Available toggle failed: $e');
    }
  }

  Future<void> setDiscoveryEnabled(bool enabled) async {
    if (!state.meshStarted || !state.playServicesAvailable) return;
    if (enabled == state.isDiscovering) return;

    try {
      if (enabled) {
        await _transport.startDiscovery();
      } else {
        await _transport.stopDiscovery();
      }
      state = state.copyWith(
        isDiscovering: enabled,
        lastEvent: enabled ? 'Scanning enabled' : 'Scanning disabled',
      );
    } catch (e) {
      state = state.copyWith(lastEvent: 'Scanning toggle failed: $e');
    }
  }

  void _schedulePrune({bool immediate = false}) {
    // Cancel any pending timer.
    _pruneTimer?.cancel();

    if (immediate) {
      // Best-effort non-blocking cleanup after startup.
      unawaited(_performPrune());
      return;
    }

    _pruneTimer = Timer(AirGridConstants.kChatPruneDebounce, () {
      unawaited(_performPrune());
    });
  }

  Future<void> _performPrune() async {
    try {
      await _repo.prune(
        maxMessages: AirGridConstants.kChatMaxMessages,
        maxAge: AirGridConstants.kChatMaxAge,
      );
    } catch (_) {
      // Swallow any errors; pruning is best-effort.
    }
  }

  /// Clear all persisted chats and reset in-memory state synchronously
  /// from the user's perspective (the repository operation is awaited).
  Future<void> clearAllChats() async {
    await _repo.clearAll();
    _pruneTimer?.cancel();
    _pruneTimer = null;
    state = state.copyWith(
      messages: const [],
      unreadPrivateCounts: const {},
      selectedConversation: const PublicConversation(),
    );
  }

  Future<void> startLocationSharing() async {
    if (state.isLocationSharing) return;
    if (!state.meshStarted) {
      state = state.copyWith(locationStatus: 'Start the mesh first.');
      return;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      state = state.copyWith(locationStatus: 'Turn on device location.');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      state = state.copyWith(locationStatus: 'Location permission denied.');
      return;
    }

    state = state.copyWith(
      isLocationSharing: true,
      locationStatus: 'Eco location sharing on',
    );

    _lastLocationPublishAt = null;
    final current = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: _locationAccuracy,
        distanceFilter: _locationUpdateDistanceFilterMeters,
      ),
    );
    await _publishPosition(current, force: true);

    await _positionSub?.cancel();
    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: _locationAccuracy,
            distanceFilter: _locationUpdateDistanceFilterMeters,
          ),
        ).listen(
          (position) => unawaited(_publishPosition(position)),
          onError: (_) {
            state = state.copyWith(
              isLocationSharing: false,
              locationStatus: 'Location updates stopped.',
            );
          },
        );
  }

  Future<void> stopLocationSharing() async {
    await _positionSub?.cancel();
    _positionSub = null;
    _lastLocationPublishAt = null;
    state = state.copyWith(
      isLocationSharing: false,
      clearLocalLocation: true,
      locationStatus: 'Location sharing off',
    );
  }

  /// Sends a public message to all connected peers.
  /// Returns [true] if the send succeeded, [false] if it failed.
  Future<bool> sendMessage(String content) async {
    final validation = MessageContentValidator.validateLocal(content);
    if (!validation.isValid) return false;

    try {
      await _mesh.sendMessage(validation.sanitizedValue!);
      return true;
    } on StateError catch (e) {
      // Rate limiting error - provide user feedback
      state = state.copyWith(lastEvent: e.message);
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Sends a private message to [peer].
  /// Returns a [PrivateSendResult] indicating outcome.
  Future<PrivateSendResult> sendPrivateMessage(
    MeshPeer peer,
    String content, {
    bool allowPlaintextFallback = false,
  }) async {
    final validation = MessageContentValidator.validateLocal(content);
    if (!validation.isValid) return PrivateSendResult.failed;

    try {
      return await _mesh.sendPrivateMessage(
        peer,
        validation.sanitizedValue!,
        allowPlaintextFallback: allowPlaintextFallback,
      );
    } catch (_) {
      return PrivateSendResult.failed;
    }
  }

  /// Sends a private message to a [KnownContact] who may not be directly
  /// connected. Always encrypted; no plaintext fallback.
  Future<PrivateSendResult> sendPrivateMessageToContact(
    KnownContact contact,
    String content,
  ) async {
    final validation = MessageContentValidator.validateLocal(content);
    if (!validation.isValid) return PrivateSendResult.failed;

    try {
      return await _mesh.sendPrivateMessageToContact(
        contact,
        validation.sanitizedValue!,
      );
    } catch (_) {
      return PrivateSendResult.failed;
    }
  }

  Future<PrivateSendResult> sendPrivateImage(
    MeshPeer peer,
    ImageAttachmentPayload image, {
    bool allowPlaintextFallback = false,
    String? messageId,
    String? packetId,
    bool emitLocalMessage = true,
  }) async {
    try {
      return await _mesh.sendPrivateImage(
        peer,
        image,
        allowPlaintextFallback: allowPlaintextFallback,
        messageId: messageId,
        packetId: packetId,
        emitLocalMessage: emitLocalMessage,
      );
    } catch (_) {
      return PrivateSendResult.failed;
    }
  }

  Future<PrivateSendResult> sendPrivateImageToContact(
    KnownContact contact,
    ImageAttachmentPayload image,
    {
    String? messageId,
    String? packetId,
    bool emitLocalMessage = true,
  }
  ) async {
    try {
      return await _mesh.sendPrivateImageToContact(
        contact,
        image,
        messageId: messageId,
        packetId: packetId,
        emitLocalMessage: emitLocalMessage,
      );
    } catch (_) {
      return PrivateSendResult.failed;
    }
  }

  Future<PrivateSendResult> sendPrivateAudio(
    MeshPeer peer,
    AudioAttachmentPayload audio, {
    bool allowPlaintextFallback = false,
    String? messageId,
    String? packetId,
    bool emitLocalMessage = true,
  }) async {
    try {
      return await _mesh.sendPrivateAudio(
        peer,
        audio,
        allowPlaintextFallback: allowPlaintextFallback,
        messageId: messageId,
        packetId: packetId,
        emitLocalMessage: emitLocalMessage,
      );
    } catch (_) {
      return PrivateSendResult.failed;
    }
  }

  Future<PrivateSendResult> sendPrivateAudioToContact(
    KnownContact contact,
    AudioAttachmentPayload audio,
    {
    String? messageId,
    String? packetId,
    bool emitLocalMessage = true,
  }
  ) async {
    try {
      return await _mesh.sendPrivateAudioToContact(
        contact,
        audio,
        messageId: messageId,
        packetId: packetId,
        emitLocalMessage: emitLocalMessage,
      );
    } catch (_) {
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
    try {
      return await _mesh.sendPrivateFile(
        peer,
        file,
        allowPlaintextFallback: allowPlaintextFallback,
        messageId: messageId,
        packetId: packetId,
        emitLocalMessage: emitLocalMessage,
        onProgress: onProgress,
      );
    } catch (_) {
      return PrivateSendResult.failed;
    }
  }

  Future<PrivateSendResult> sendPrivateFileToContact(
    KnownContact contact,
    FileAttachmentPayload file,
    {
      String? messageId,
      String? packetId,
      bool emitLocalMessage = true,
      void Function(double progress)? onProgress,
    }
  ) async {
    try {
      return await _mesh.sendPrivateFileToContact(
        contact,
        file,
        messageId: messageId,
        packetId: packetId,
        emitLocalMessage: emitLocalMessage,
        onProgress: onProgress,
      );
    } catch (_) {
      return PrivateSendResult.failed;
    }
  }

  void updateOutgoingFileProgress(String messageId, double progress) {
    final idx = state.messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;
    final existing = state.messages[idx];
    if (!existing.isLocal ||
        existing.conversationType != 'private' ||
        existing.messageKind != 'file') {
      return;
    }

    final clamped = progress.clamp(0.0, 1.0);
    final updated = existing.copyWith(
      mediaTransferProgress: clamped,
    );
    final newMessages = List<AirGridMessage>.from(state.messages)
      ..[idx] = updated;
    state = state.copyWith(messages: newMessages);
  }

  Future<PrivateSendResult> retryImageMessage(
    AirGridMessage message,
  ) async {
    _cancelAutomaticImageRetry(message.id);
    return _retryImageMessageInternal(
      message,
      markFailedOnTerminal: true,
    );
  }

  Future<PrivateSendResult> _retryImageMessageInternal(
    AirGridMessage message, {
    required bool markFailedOnTerminal,
  }) async {
    if (!message.isLocal ||
        message.conversationType != 'private' ||
        message.messageKind != 'image' ||
        message.peerNodeId == null) {
      return PrivateSendResult.failed;
    }

    final payload = await _rebuildImageAttachment(message);
    if (payload == null) {
      return PrivateSendResult.failed;
    }

    if (!await waitForMeshReady()) {
      return PrivateSendResult.failed;
    }

    if (!await waitForPeerOnline(
      message.peerNodeId!,
      timeout: imageRetryPeerOnlineTimeout,
      pollInterval: imageRetryPeerOnlinePollInterval,
      settleDelay: imageRetryPeerOnlineSettleDelay,
    )) {
      return PrivateSendResult.peerUnavailable;
    }

    _forceStatusUpdate(message.id, DeliveryStatus.pending);

    var result = await _sendRetryImageAttempt(
      message: message,
      payload: payload,
      peer: state.peers.cast<MeshPeer?>().firstWhere(
        (p) => p?.nodeId == message.peerNodeId,
        orElse: () => null,
      ),
      contact: state.knownContacts.cast<KnownContact?>().firstWhere(
        (c) => c?.nodeId == message.peerNodeId,
        orElse: () => null,
      ),
      packetId: const Uuid().v4(),
    );

    if (result == PrivateSendResult.failed ||
        result == PrivateSendResult.peerUnavailable ||
        result == PrivateSendResult.needsPlaintextConfirmation) {
      await Future<void>.delayed(imageRetrySecondAttemptDelay);
      await waitForPeerOnline(
        message.peerNodeId!,
        timeout: imageRetrySecondAttemptTimeout,
        pollInterval: imageRetryPeerOnlinePollInterval,
        settleDelay: imageRetrySecondAttemptSettleDelay,
      );

      result = await _sendRetryImageAttempt(
        message: message,
        payload: payload,
        peer: state.peers.cast<MeshPeer?>().firstWhere(
          (p) => p?.nodeId == message.peerNodeId,
          orElse: () => null,
        ),
        contact: state.knownContacts.cast<KnownContact?>().firstWhere(
          (c) => c?.nodeId == message.peerNodeId,
          orElse: () => null,
        ),
        packetId: const Uuid().v4(),
      );
    }

    if (result == PrivateSendResult.failed ||
        result == PrivateSendResult.peerUnavailable ||
        result == PrivateSendResult.needsPlaintextConfirmation) {
      if (markFailedOnTerminal) {
        _forceStatusUpdate(message.id, DeliveryStatus.failed);
      }
    }
    return result;
  }

  Future<PrivateSendResult> _sendRetryImageAttempt({
    required AirGridMessage message,
    required ImageAttachmentPayload payload,
    required MeshPeer? peer,
    required KnownContact? contact,
    required String packetId,
  }) async {
    if (contact != null) {
      return _mesh.sendPrivateImageToContact(
        contact,
        payload,
        messageId: message.id,
        packetId: packetId,
        emitLocalMessage: false,
      );
    }

    if (peer != null) {
      return _mesh.sendPrivateImage(
        peer,
        payload,
        messageId: message.id,
        packetId: packetId,
        emitLocalMessage: false,
      );
    }

    return PrivateSendResult.peerUnavailable;
  }

  /// Updates the selected conversation thread.
  void selectConversation(ConversationTarget target) {
    if (target is PrivateConversation) {
      if (state.blockedNodeIds.contains(target.peerNodeId)) {
        state = state.copyWith(
          selectedConversation: const PublicConversation(),
        );
        return;
      }
      if (state.privacyMode == PrivacyMode.trustedContactsOnly &&
          !state.trustedNodeIds.contains(target.peerNodeId)) {
        state = state.copyWith(
          selectedConversation: const PublicConversation(),
        );
        return;
      }
      final unread = Map<String, int>.from(state.unreadPrivateCounts)
        ..remove(target.peerNodeId);
      final messages = state.messages
          .map(
            (m) =>
                m.conversationType == 'private' &&
                    !m.isLocal &&
                    m.peerNodeId == target.peerNodeId
                ? m.copyWith(isRead: true)
                : m,
          )
          .toList();
      state = state.copyWith(
        messages: messages,
        selectedConversation: target,
        unreadPrivateCounts: unread,
      );
      unawaited(_repo.markPrivateThreadRead(target.peerNodeId));
      unawaited(_sendReadReceiptsFor(target.peerNodeId));
      return;
    }
    state = state.copyWith(selectedConversation: target);
  }

  Map<String, int> _updatedUnreadCountsFor(AirGridMessage msg) {
    if (msg.conversationType != 'private' || msg.isLocal) {
      return state.unreadPrivateCounts;
    }
    if (msg.isRead) {
      return state.unreadPrivateCounts;
    }

    final peerNodeId = msg.peerNodeId;
    if (peerNodeId == null || peerNodeId.isEmpty) {
      return state.unreadPrivateCounts;
    }

    // Do not increment unread count for blocked contacts.
    if (state.blockedNodeIds.contains(peerNodeId)) {
      return state.unreadPrivateCounts;
    }

    final selected = state.selectedConversation;
    if (selected is PrivateConversation && selected.peerNodeId == peerNodeId) {
      return state.unreadPrivateCounts;
    }

    final unread = Map<String, int>.from(state.unreadPrivateCounts);
    unread[peerNodeId] = (unread[peerNodeId] ?? 0) + 1;
    return unread;
  }

  AirGridMessage _withReadStateForIncomingMessage(AirGridMessage msg) {
    if (msg.conversationType != 'private' || msg.isLocal) return msg;
    final peerNodeId = msg.peerNodeId;
    final selected = state.selectedConversation;
    final isOpen =
        peerNodeId != null &&
        selected is PrivateConversation &&
        selected.peerNodeId == peerNodeId;
    return msg.copyWith(isRead: isOpen);
  }

  Map<String, int> _unreadCountsFromMessages(List<AirGridMessage> messages) {
    final unread = <String, int>{};
    for (final msg in messages) {
      if (msg.conversationType != 'private' || msg.isLocal || msg.isRead) {
        continue;
      }
      final peerNodeId = msg.peerNodeId;
      if (peerNodeId == null ||
          peerNodeId.isEmpty ||
          state.blockedNodeIds.contains(peerNodeId)) {
        continue;
      }
      final selected = state.selectedConversation;
      if (selected is PrivateConversation &&
          selected.peerNodeId == peerNodeId) {
        continue;
      }
      unread[peerNodeId] = (unread[peerNodeId] ?? 0) + 1;
    }
    return unread;
  }

  bool _shouldNotifyForPrivateMessage(AirGridMessage msg) {
    if (msg.conversationType != 'private' || msg.isLocal) {
      return false;
    }
    // Do not notify for messages from blocked contacts.
    final peerNodeId = msg.peerNodeId;
    if (peerNodeId != null && state.blockedNodeIds.contains(peerNodeId)) {
      return false;
    }
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    return lifecycleState != AppLifecycleState.resumed;
  }

  ConversationTarget _resolveSelectedConversation(List<MeshPeer> peers) {
    final selected = state.selectedConversation;
    if (selected is! PrivateConversation) {
      return selected;
    }

    final hasSelectedPeer = peers.any((p) => p.nodeId == selected.peerNodeId);
    if (hasSelectedPeer) {
      return selected;
    }

    for (final peer in peers) {
      if (peer.nodeId == null) continue;
      if (_samePeerName(peer.displayName, selected.peerName)) {
        return PrivateConversation(
          peerNodeId: peer.nodeId!,
          peerName: peer.displayName,
        );
      }
    }

    return selected;
  }

  bool _samePeerName(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  /// Blocks the contact identified by [nodeId].
  ///
  /// Immediately prunes all visible state for that node (peer list, peer
  /// locations, unread counts, and selected conversation).
  Future<void> blockUser(String nodeId) async {
    await ref.read(knownContactStoreProvider).block(nodeId);
    final peers = state.peers.where((p) => p.nodeId != nodeId).toList();
    final peerLocations = Map<String, PeerLocation>.from(state.peerLocations)
      ..remove(nodeId);
    final unread = Map<String, int>.from(state.unreadPrivateCounts)
      ..remove(nodeId);
    final sel = state.selectedConversation;
    final selectedConversation =
        sel is PrivateConversation && sel.peerNodeId == nodeId
        ? const PublicConversation()
        : sel;
    state = state.copyWith(
      peers: peers,
      peerLocations: peerLocations,
      unreadPrivateCounts: unread,
      selectedConversation: selectedConversation,
    );
  }

  /// Unblocks the contact identified by [nodeId].
  Future<void> unblockUser(String nodeId) async {
    await ref.read(knownContactStoreProvider).unblock(nodeId);
  }

  /// Marks the contact identified by [nodeId] as trusted.
  Future<void> trustContact(String nodeId) async {
    await _contactStore.trust(nodeId);
  }

  /// Removes trust for the contact identified by [nodeId].
  Future<void> untrustContact(String nodeId) async {
    await _contactStore.untrust(nodeId);
  }

  /// Hides [messageId] from the current session view (in-memory only).
  void hideMessage(String messageId) {
    state = state.copyWith(
      hiddenMessageIds: {...state.hiddenMessageIds, messageId},
    );
  }

  /// Persists [mode] and updates state.
  Future<void> setPrivacyMode(PrivacyMode mode) async {
    await _privacyStore.setPrivacyMode(mode);
    state = state.copyWith(privacyMode: mode);
  }

  Future<void> setBatteryOptimizationEnabled(bool enabled) async {
    await _batteryStore.setBatteryOptimizationEnabled(enabled);
    state = state.copyWith(batteryOptimizationEnabled: enabled);
  }

  /// Submits a report about a user.
  Future<void> reportUser({
    required String reportedNodeId,
    required String reportedDisplayName,
    required ReportReason reason,
    String? notes,
  }) async {
    final report = LocalReport(
      timestamp: DateTime.now(),
      reporterNodeId: _identity.nodeId,
      reportedNodeId: reportedNodeId,
      reportedDisplayName: reportedDisplayName,
      reason: reason,
      notes: notes,
    );
    await _reportStore.add(report);
  }

  /// Submits a report about a specific message.
  Future<void> reportMessage({
    required AirGridMessage message,
    required ReportReason reason,
    String? notes,
  }) async {
    final report = LocalReport(
      timestamp: DateTime.now(),
      reporterNodeId: _identity.nodeId,
      reportedNodeId: message.senderNodeId,
      reportedDisplayName: message.senderName,
      messageId: message.id,
      messageContentSnapshot: message.content,
      reason: reason,
      notes: notes,
    );
    await _reportStore.add(report);
  }

  /// Returns all saved reports as exportable plain text.
  Future<String> exportReports() async {
    return _reportStore.exportText();
  }

  Future<void> _publishPosition(Position position, {bool force = false}) async {
    final location = PeerLocation(
      nodeId: _identity.nodeId,
      displayName: _identity.displayName ?? 'Unknown',
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeters: position.accuracy,
      headingDegrees: position.heading.isNaN ? null : position.heading,
      updatedAt: DateTime.now(),
    );
    await _shareLocation(location, force: force);
  }

  Future<void> _shareLocation(
    PeerLocation location, {
    bool force = false,
  }) async {
    state = state.copyWith(
      localLocation: location,
      locationStatus: state.peers.isEmpty
          ? 'Location ready, waiting for peers'
          : 'Eco location shared ${_formatLocationTime(location)}',
    );

    if (state.peers.isEmpty) return;

    final lastPublish = _lastLocationPublishAt;
    final now = DateTime.now();
    if (!force &&
        lastPublish != null &&
        now.difference(lastPublish) < _locationUpdateMinInterval) {
      return;
    }

    _lastLocationPublishAt = now;
    await _mesh.sendLocationUpdate(location);
  }

  String _formatLocationTime(PeerLocation location) {
    final time = location.updatedAt;
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return 'at $hour:$minute';
  }

  /// Advances the in-memory delivery status of [messageId] to [newStatus] if
  /// the transition is valid, then persists the change.
  void _applyStatusUpdate(String messageId, DeliveryStatus newStatus) {
    final idx = state.messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;
    final existing = state.messages[idx];
    // Delivery ticks are only meaningful for our own outgoing private messages.
    if (!existing.isLocal || existing.conversationType != 'private') return;
    if (!canAdvanceStatus(existing.deliveryStatus, newStatus)) return;
    final updated = existing.copyWith(deliveryStatus: newStatus);
    final newMessages = List<AirGridMessage>.from(state.messages)
      ..[idx] = updated;
    state = state.copyWith(messages: newMessages);
    unawaited(_repo.updateStatus(messageId, newStatus));
  }

  void _handleAutomaticImageRetryStatus(
    String messageId,
    DeliveryStatus newStatus,
  ) {
    if (newStatus == DeliveryStatus.delivered ||
        newStatus == DeliveryStatus.read ||
        newStatus == DeliveryStatus.failed) {
      _cancelAutomaticImageRetry(messageId);
      return;
    }

    if (newStatus != DeliveryStatus.sent) {
      return;
    }

    final message = _messageById(messageId);
    if (message == null) {
      return;
    }

    _restoreAutomaticImageRetryWatch(message);
  }

  void _forceStatusUpdate(String messageId, DeliveryStatus newStatus) {
    final idx = state.messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;
    final existing = state.messages[idx];
    if (!existing.isLocal || existing.conversationType != 'private') return;
    final updated = existing.copyWith(
      deliveryStatus: newStatus,
      mediaTransferProgress:
          newStatus == DeliveryStatus.pending ? existing.mediaTransferProgress : null,
    );
    final newMessages = List<AirGridMessage>.from(state.messages)
      ..[idx] = updated;
    state = state.copyWith(messages: newMessages);
    unawaited(_repo.updateStatus(messageId, newStatus));
  }

  AirGridMessage? _messageById(String messageId) {
    final idx = state.messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) {
      return null;
    }
    return state.messages[idx];
  }

  bool _isAutomaticImageRetryCandidate(AirGridMessage message) {
    return message.isLocal &&
        message.conversationType == 'private' &&
        message.messageKind == 'image' &&
        message.peerNodeId != null &&
        (message.deliveryStatus == DeliveryStatus.pending ||
            message.deliveryStatus == DeliveryStatus.sent);
  }

  bool _canRestoreAutomaticImageRetryWatch(AirGridMessage message) {
    if (!_isAutomaticImageRetryCandidate(message)) {
      return false;
    }

    final age = DateTime.now().difference(message.timestamp);
    if (age > automaticImageRetryStartupGrace) {
      return false;
    }

    return _hasRecoverableImagePayload(message);
  }

  bool _hasRecoverableImagePayload(AirGridMessage message) {
    final tempPath = message.mediaTempPath;
    if (tempPath != null && tempPath.isNotEmpty && File(tempPath).existsSync()) {
      return true;
    }

    final preview = message.mediaPreviewBase64;
    return preview != null && preview.isNotEmpty;
  }

  void _restoreAutomaticImageRetryWatches(Iterable<AirGridMessage> messages) {
    for (final message in messages) {
      if (_canRestoreAutomaticImageRetryWatch(message)) {
        _scheduleAutomaticImageRetry(message.id, resetAttempts: true);
      }
    }
  }

  void _restoreAutomaticImageRetryWatch(AirGridMessage message) {
    if (_isAutomaticImageRetryCandidate(message)) {
      _scheduleAutomaticImageRetry(message.id);
      return;
    }

    if (message.deliveryStatus == DeliveryStatus.delivered ||
        message.deliveryStatus == DeliveryStatus.read ||
        message.deliveryStatus == DeliveryStatus.failed) {
      _cancelAutomaticImageRetry(message.id);
    }
  }

  void _scheduleAutomaticImageRetry(
    String messageId, {
    bool resetAttempts = false,
    Duration? delay,
  }) {
    final message = _messageById(messageId);
    if (message == null || !_isAutomaticImageRetryCandidate(message)) {
      _cancelAutomaticImageRetry(messageId);
      return;
    }

    final retryState = _automaticImageRetries.putIfAbsent(
      messageId,
      _AutomaticImageRetryState.new,
    );
    if (resetAttempts) {
      retryState.attempts = 0;
    }
    retryState.cancel();
    retryState.timer = Timer(
      delay ?? automaticImageAckTimeout,
      () => unawaited(_handleAutomaticImageRetryTimeout(messageId)),
    );
  }

  Future<void> _handleAutomaticImageRetryTimeout(String messageId) async {
    final retryState = _automaticImageRetries[messageId];
    if (retryState == null || retryState.inFlight) {
      return;
    }

    final message = _messageById(messageId);
    if (message == null || !_isAutomaticImageRetryCandidate(message)) {
      _cancelAutomaticImageRetry(messageId);
      return;
    }

    if (!_hasRecoverableImagePayload(message)) {
      _cancelAutomaticImageRetry(messageId);
      _forceStatusUpdate(messageId, DeliveryStatus.failed);
      return;
    }

    if (retryState.attempts >= automaticImageRetryMaxAttempts) {
      _cancelAutomaticImageRetry(messageId);
      _forceStatusUpdate(messageId, DeliveryStatus.failed);
      return;
    }

    retryState.inFlight = true;
    retryState.attempts++;

    final result = await _retryImageMessageInternal(
      message,
      markFailedOnTerminal: false,
    );

    retryState.inFlight = false;
    final refreshed = _messageById(messageId);
    if (refreshed == null) {
      _cancelAutomaticImageRetry(messageId);
      return;
    }

    if (refreshed.deliveryStatus == DeliveryStatus.delivered ||
        refreshed.deliveryStatus == DeliveryStatus.read ||
        refreshed.deliveryStatus == DeliveryStatus.failed) {
      _cancelAutomaticImageRetry(messageId);
      return;
    }

    if (result == PrivateSendResult.sentEncrypted ||
        result == PrivateSendResult.sentPlaintext) {
      _scheduleAutomaticImageRetry(messageId, delay: automaticImageAckTimeout);
      return;
    }

    if (retryState.attempts >= automaticImageRetryMaxAttempts ||
        !_hasRecoverableImagePayload(refreshed)) {
      _cancelAutomaticImageRetry(messageId);
      _forceStatusUpdate(messageId, DeliveryStatus.failed);
      return;
    }

    _scheduleAutomaticImageRetry(
      messageId,
      delay: automaticImageRetryBackoff,
    );
  }

  void _cancelAutomaticImageRetry(String messageId) {
    final retryState = _automaticImageRetries.remove(messageId);
    retryState?.cancel();
  }

  void _cancelAllAutomaticImageRetries() {
    for (final retryState in _automaticImageRetries.values) {
      retryState.cancel();
    }
    _automaticImageRetries.clear();
  }

  Future<ImageAttachmentPayload?> _rebuildImageAttachment(
    AirGridMessage message,
  ) async {
    final tempPath = message.mediaTempPath;
    Uint8List bytes;
    if (tempPath != null && tempPath.isNotEmpty && File(tempPath).existsSync()) {
      try {
        bytes = await File(tempPath).readAsBytes();
      } catch (_) {
        return null;
      }
    } else if (message.mediaPreviewBase64 != null &&
        message.mediaPreviewBase64!.isNotEmpty) {
      try {
        bytes = base64Decode(message.mediaPreviewBase64!);
      } catch (_) {
        return null;
      }
    } else {
      return null;
    }

    return ImageAttachmentPayload(
      transferId: message.mediaTransferId ?? message.id,
      mimeType: message.mediaMimeType ?? 'image/jpeg',
      byteLength: message.mediaByteLength ?? bytes.length,
      width: message.mediaWidth,
      height: message.mediaHeight,
      dataBase64: base64Encode(bytes),
      localTempPath: tempPath,
    );
  }

  Future<void> _sendReadReceiptsFor(String peerNodeId) async {
    if (!state.meshStarted) return;
    if (state.blockedNodeIds.contains(peerNodeId)) return;
    final ids = state.messages
        .where(
          (m) =>
              m.conversationType == 'private' &&
              !m.isLocal &&
              m.peerNodeId == peerNodeId,
        )
        .map((m) => m.id)
        .toList();
    if (ids.isEmpty) return;
    await _mesh.sendReadReceipts(peerNodeId, ids);
  }
}
