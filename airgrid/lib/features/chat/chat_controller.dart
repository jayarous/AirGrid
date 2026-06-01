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
import 'package:airgrid/data/storage/chat_list_preferences_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/storage/public_walkie_settings_store.dart';
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
import 'package:airgrid/features/chat/automatic_image_retry_controller.dart';
import 'package:airgrid/features/chat/chat_state.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:airgrid/features/chat/walkie_session_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:just_audio/just_audio.dart';
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

/// Override in main.dart after [SharedPrefsPublicWalkieSettingsStore.create()] completes.
final publicWalkieSettingsStoreProvider = Provider<PublicWalkieSettingsStore>(
  (ref) => InMemoryPublicWalkieSettingsStore(),
);

final batterySettingsStoreProvider = Provider<BatterySettingsStore>(
  (ref) => throw UnimplementedError(),
);

final chatListPreferencesStoreProvider = Provider<ChatListPreferencesStore>(
  (ref) => InMemoryChatListPreferencesStore(),
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
  AudioPlayer? _publicWalkiePlayer;
  bool _isStarting = false;
  bool _isDisposed = false;
  int _foregroundCriticalActions = 0;
  bool _batterySettingLoaded = false;
  bool _publicWalkieSettingLoaded = false;
  bool _stoppedByBatteryOptimization = false;
  DateTime? _lastLocationPublishAt;

  /// Endpoint IDs of currently connected peers, tracked to detect new joins.
  var _connectedPeerEndpoints = <String>{};
  Timer? _pruneTimer;

  AutomaticImageRetryController get _automaticImageRetry =>
      _automaticImageRetryController ??= AutomaticImageRetryController(
        isDisposed: () => _isDisposed,
        messageById: _messageById,
        forceStatusUpdate: _forceStatusUpdate,
        retryAttempt: (message) async {
          final result = await _retryImageMessageInternal(
            message,
            markFailedOnTerminal: false,
          );
          return result == PrivateSendResult.sentEncrypted ||
              result == PrivateSendResult.sentPlaintext;
        },
        config: () => AutomaticImageRetryConfig(
          ackTimeout: automaticImageAckTimeout,
          backoff: automaticImageRetryBackoff,
          startupGrace: automaticImageRetryStartupGrace,
          maxAttempts: automaticImageRetryMaxAttempts,
        ),
      );

  AutomaticImageRetryController? _automaticImageRetryController;

  WalkieSessionController get _walkieSession =>
      _walkieSessionController ??= WalkieSessionController(
        readState: () => state,
        writeState: (newState) => state = newState,
        sendPrivateMessage: sendPrivateMessage,
        isTrustedNode: (nodeId) => state.trustedNodeIds.contains(nodeId),
        isWalkieAlwaysOn: (nodeId) => _contactStore.isWalkieAlwaysOn(nodeId),
      );

  WalkieSessionController? _walkieSessionController;

  @override
  ChatState build() {
    _isDisposed = false;
    // Register disposal callback to prevent subscription/timer leaks
    ref.onDispose(() {
      _isDisposed = true;
      _messageSub?.cancel();
      _peerSub?.cancel();
      _locationSub?.cancel();
      _positionSub?.cancel();
      _transportEventSub?.cancel();
      _statusSub?.cancel();
      _contactsSub?.cancel();
      _foregroundExitSub?.cancel();
      _publicWalkiePlayer?.dispose();
      _pruneTimer?.cancel();
      _cancelAllAutomaticImageRetries();
    });
    unawaited(_loadBatteryOptimizationSetting());
    unawaited(_loadPublicWalkieSetting());
    unawaited(_loadChatListPreferences());
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
  PublicWalkieSettingsStore get _publicWalkieStore =>
      ref.read(publicWalkieSettingsStoreProvider);
  BatterySettingsStore get _batteryStore =>
      ref.read(batterySettingsStoreProvider);
    ChatListPreferencesStore get _chatListPrefs =>
      ref.read(chatListPreferencesStoreProvider);

  Future<void> _loadBatteryOptimizationSetting() async {
    if (_batterySettingLoaded) return;
    _batterySettingLoaded = true;
    final batteryStore = _batteryStore;
    final batteryOptimizationEnabled = await batteryStore
        .getBatteryOptimizationEnabled();
    if (_isDisposed) return;
    state = state.copyWith(
      batteryOptimizationEnabled: batteryOptimizationEnabled,
    );
  }

  Future<void> _loadPublicWalkieSetting() async {
    if (_publicWalkieSettingLoaded) return;
    _publicWalkieSettingLoaded = true;
    final publicWalkieStore = _publicWalkieStore;
    final enabled = await publicWalkieStore.getStayOnlineEnabled();
    if (_isDisposed) return;
    state = state.copyWith(publicWalkieStayOnline: enabled);
  }

  Future<void> _loadChatListPreferences() async {
    final chatListPrefs = _chatListPrefs;
    final showOnlineOnly = await chatListPrefs.getShowOnlineOnly();
    final showClosedChats = await chatListPrefs.getShowClosedChats();
    final showFriendsOnly = await chatListPrefs.getShowFriendsOnly();
    if (_isDisposed) return;
    state = state.copyWith(
      showOnlineOnly: showOnlineOnly,
      showClosedChats: showClosedChats,
      showFriendsOnly: showFriendsOnly,
    );
  }

  Future<void> _handleWalkiePlaybackMessage(AirGridMessage message) async {
    state = state.copyWith(clearWalkieLastError: true);

    final path = message.mediaTempPath;
    if (path == null || path.isEmpty) {
      state = state.copyWith(
        walkieLastError: 'Incoming public walkie audio unavailable',
      );
      await discardWalkieMessage(message.id, deleteTempFile: false);
      return;
    }

    try {
      final player = _publicWalkiePlayer ??= AudioPlayer();
      await player.stop();
      await player.setFilePath(path);
      await player.play();
      await discardWalkieMessage(message.id);
    } catch (_) {
      state = state.copyWith(
        walkieLastError: 'Failed to play incoming public walkie',
      );
      await discardWalkieMessage(message.id);
    }
  }

  bool _shouldAutoPlayPrivateWalkie(AirGridMessage message) {
    if (message.conversationType != 'private' || message.isLocal) return false;
    if (message.messageKind != 'audio' || message.content != '[walkie]') {
      return false;
    }
    if (!_contactStore.isWalkieAlwaysOn(message.senderNodeId)) {
      return false;
    }
    final activePeerId = state.walkieSessionActivePeerNodeId;
    final invitePeerId = state.walkieInvitePeerNodeId;
    return activePeerId == message.senderNodeId ||
        invitePeerId == message.senderNodeId;
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
        if (_isWalkieMessage(msg) && msg.isLocal) {
          return;
        }
        final walkieControl = WalkieControlMessage.fromContent(msg.content);
        if (walkieControl != null && msg.isLocal) {
          return;
        }
        if (walkieControl != null) {
          _walkieSession.handleIncomingControlMessage(msg, walkieControl);
          return;
        }
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
        final incomingPrivateNodeId = msg.peerNodeId;
        if (msg.conversationType == 'private' &&
            !msg.isLocal &&
            incomingPrivateNodeId != null &&
            _contactStore.isChatClosed(incomingPrivateNodeId)) {
          await _contactStore.reopenChat(incomingPrivateNodeId);
        }
        final messageToSave = _withReadStateForIncomingMessage(msg);
        final isWalkieMessage = _isWalkieMessage(messageToSave);
        final updated = ([
          messageToSave,
          ...state.messages,
        ]).take(AirGridConstants.kChatMaxMessages).toList();
        final unread = isWalkieMessage
            ? state.unreadPrivateCounts
            : _updatedUnreadCountsFor(messageToSave);
        state = state.copyWith(messages: updated, unreadPrivateCounts: unread);
        _restoreAutomaticImageRetryWatch(messageToSave);
        if (!isWalkieMessage) {
          await _repo.save(messageToSave);
        }
        final shouldPlayPublicWalkie =
            messageToSave.conversationType == 'public' &&
            messageToSave.messageKind == 'audio' &&
            messageToSave.content == '[walkie]' &&
            !messageToSave.isLocal &&
            state.publicWalkieStayOnline;
        final shouldPlayPrivateWalkie =
            messageToSave.conversationType == 'private' &&
            messageToSave.messageKind == 'audio' &&
            messageToSave.content == '[walkie]' &&
            !messageToSave.isLocal &&
            _shouldAutoPlayPrivateWalkie(messageToSave);
        if (shouldPlayPublicWalkie || shouldPlayPrivateWalkie) {
          unawaited(_handleWalkiePlaybackMessage(messageToSave));
        }
        // Schedule background/debounced pruning so bursts don't run deletes repeatedly.
        _schedulePrune();
        if (!isWalkieMessage && _shouldNotifyForPrivateMessage(msg)) {
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
              .where((m) => !_isWalkieMessage(m) && !existingIds.contains(m.id))
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

  Future<void> announceLocalProfile() async {
    if (!state.meshStarted) {
      return;
    }
    await _mesh.sendKeyAnnounce();
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
      walkieIsTransmitting: false,
      walkieIsSending: false,
      clearWalkieLastError: true,
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

  /// Broadcast a walkie-talkie voice clip on the public channel.
  Future<void> sendPublicWalkieAudio(AudioAttachmentPayload audio) async {
    await _mesh.sendPublicAudio(audio);
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
    try {
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
    } catch (_) {
      return PrivateSendResult.failed;
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
        walkiePeerNodeId: target.peerNodeId,
        unreadPrivateCounts: unread,
      );
      unawaited(_repo.markPrivateThreadRead(target.peerNodeId));
      unawaited(_sendReadReceiptsFor(target.peerNodeId));
      return;
    }
    state = state.copyWith(
      selectedConversation: target,
      clearWalkiePeerNodeId: true,
    );
  }

  void setWalkiePeerNodeId(String? nodeId) {
    state = state.copyWith(
      walkiePeerNodeId: nodeId,
      clearWalkiePeerNodeId: nodeId == null,
    );
  }

  void setWalkieTransmitting({
    required bool isTransmitting,
    String? peerNodeId,
  }) {
    state = state.copyWith(
      walkieIsTransmitting: isTransmitting,
      walkiePeerNodeId: peerNodeId,
    );
  }

  void setWalkieSending({required bool isSending}) {
    state = state.copyWith(walkieIsSending: isSending);
  }

  void setWalkieLastError(String? error) {
    state = state.copyWith(
      walkieLastError: error,
      clearWalkieLastError: error == null,
    );
  }

  Future<bool> sendWalkieInvite(MeshPeer peer) async {
    return _walkieSession.sendInvite(peer);
  }

  Future<bool> acceptWalkieInvite() async {
    return _walkieSession.acceptInvite();
  }

  Future<bool> declineWalkieInvite() async {
    return _walkieSession.declineInvite();
  }

  Future<bool> cancelWalkieInvite() async {
    return _walkieSession.cancelInvite();
  }

  Future<bool> endWalkieSession() async {
    return _walkieSession.endSession();
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

  bool _isWalkieMessage(AirGridMessage msg) =>
      msg.messageKind == 'audio' && msg.content == '[walkie]';

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

  Future<void> setWalkieAlwaysOn(String nodeId, bool enabled) async {
    await _contactStore.setWalkieAlwaysOn(nodeId, enabled);
  }

  /// Hides [messageId] from the current session view (in-memory only).
  void hideMessage(String messageId) {
    state = state.copyWith(
      hiddenMessageIds: {...state.hiddenMessageIds, messageId},
    );
  }

  /// Removes an in-memory walkie message and best-effort deletes its temp file.
  Future<void> discardWalkieMessage(
    String messageId, {
    bool deleteTempFile = true,
  }) async {
    final idx = state.messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;
    final existing = state.messages[idx];
    if (!_isWalkieMessage(existing)) return;

    final mediaTempPath = existing.mediaTempPath;
    final newMessages = List<AirGridMessage>.from(state.messages)
      ..removeAt(idx);
    final newHiddenIds = Set<String>.from(state.hiddenMessageIds)
      ..remove(messageId);
    state = state.copyWith(messages: newMessages, hiddenMessageIds: newHiddenIds);

    if (!deleteTempFile) return;
    if (mediaTempPath == null || mediaTempPath.isEmpty) return;
    try {
      final file = File(mediaTempPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cleanup only.
    }
  }

  /// Persists [mode] and updates state.
  Future<void> setPrivacyMode(PrivacyMode mode) async {
    await _privacyStore.setPrivacyMode(mode);
    state = state.copyWith(privacyMode: mode);
  }

  Future<void> setPublicWalkieStayOnline(bool enabled) async {
    await _publicWalkieStore.setStayOnlineEnabled(enabled);
    state = state.copyWith(publicWalkieStayOnline: enabled);
  }

  Future<void> setShowOnlineOnly(bool enabled) async {
    await _chatListPrefs.setShowOnlineOnly(enabled);
    state = state.copyWith(showOnlineOnly: enabled);
  }

  Future<void> setShowClosedChats(bool enabled) async {
    await _chatListPrefs.setShowClosedChats(enabled);
    state = state.copyWith(showClosedChats: enabled);
  }

  Future<void> setShowFriendsOnly(bool enabled) async {
    await _chatListPrefs.setShowFriendsOnly(enabled);
    state = state.copyWith(showFriendsOnly: enabled);
  }

  Future<void> closePrivateChat(String nodeId) async {
    await _contactStore.closeChat(nodeId);
    final sel = state.selectedConversation;
    if (sel is PrivateConversation && sel.peerNodeId == nodeId) {
      state = state.copyWith(selectedConversation: const PublicConversation());
    }
  }

  Future<void> reopenPrivateChat(String nodeId) async {
    await _contactStore.reopenChat(nodeId);
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
    _automaticImageRetry.handleStatus(messageId, newStatus);
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

  void _restoreAutomaticImageRetryWatches(Iterable<AirGridMessage> messages) {
    _automaticImageRetry.restoreWatches(messages);
  }

  void _restoreAutomaticImageRetryWatch(AirGridMessage message) {
    _automaticImageRetry.restoreWatch(message);
  }

  void _cancelAutomaticImageRetry(String messageId) {
    _automaticImageRetry.cancel(messageId);
  }

  void _cancelAllAutomaticImageRetries() {
    _automaticImageRetry.cancelAll();
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
