import 'dart:async';
import 'dart:convert';

import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/core/rider_audio_bridge.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/chat_list_preferences_store.dart';
import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/storage/public_walkie_settings_store.dart';
import 'package:airgrid/data/storage/rider_mode_settings_store.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:airgrid/features/rider/rider_mode_controller.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_services.dart';
import 'fake_transport.dart';

/// Everything a controller-level lifecycle test needs: the chat and rider
/// controllers wired to fakes, one trusted peer with a real key, and the
/// platform channels the rider path touches stubbed out.
class LifecycleHarness {
  LifecycleHarness._({
    required this.container,
    required this.transport,
    required this.foreground,
    required this.identity,
    required this.contacts,
    required this.recorder,
    required this.peerNodeId,
  });

  final ProviderContainer container;
  final FakeTransport transport;
  final FakeForegroundService foreground;
  final LocalIdentityStore identity;
  final InMemoryKnownContactStore contacts;
  final FakeAudioRecorder recorder;

  /// A trusted contact whose X25519 key the local crypto service holds, so
  /// encrypted rider control can be sent to them once they connect.
  final String peerNodeId;

  static const peerEndpointId = 'ep-peer';

  ChatController get chat => container.read(chatControllerProvider.notifier);
  RiderModeController get rider =>
      container.read(riderModeControllerProvider.notifier);

  static Future<LifecycleHarness> create({
    bool batteryOptimizationEnabled = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'airgrid_node_id': 'local-node',
      'airgrid_display_name': 'Jay',
    });
    FlutterSecureStorage.setMockInitialValues({});
    final identity = await LocalIdentityStore.create();

    final crypto = CryptoService();
    await crypto.loadLocalKeyPair(
      identity.privateKeyBase64!,
      identity.publicKeyBase64!,
    );
    const peerNodeId = 'peer-node';
    final peerKeyPair = await X25519().newKeyPair();
    final peerKey = base64Encode((await peerKeyPair.extractPublicKey()).bytes);
    crypto.cacheKey(peerNodeId, peerKey);

    final contacts = InMemoryKnownContactStore();
    await contacts.upsert(
      KnownContact(
        nodeId: peerNodeId,
        displayName: 'Peer',
        publicKeyBase64: peerKey,
        lastSeenAt: DateTime.now(),
      ),
    );
    await contacts.trust(peerNodeId);

    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final recorder = FakeAudioRecorder();
    final container = ProviderContainer(
      overrides: [
        localIdentityStoreProvider.overrideWithValue(identity),
        messageRepositoryProvider.overrideWithValue(_NoopMessageRepository()),
        transportServiceProvider.overrideWithValue(transport),
        playServicesProvider.overrideWithValue(
          FakePlayServices(
            const PlayServicesStatus(
              available: true,
              code: 'ok',
              message: '',
              canResolve: false,
            ),
          ),
        ),
        foregroundServiceProvider.overrideWithValue(foreground),
        cryptoServiceProvider.overrideWithValue(crypto),
        knownContactStoreProvider.overrideWithValue(contacts),
        localReportStoreProvider.overrideWithValue(InMemoryLocalReportStore()),
        privacySettingsStoreProvider.overrideWithValue(
          InMemoryPrivacySettingsStore(),
        ),
        publicWalkieSettingsStoreProvider.overrideWithValue(
          InMemoryPublicWalkieSettingsStore(),
        ),
        batterySettingsStoreProvider.overrideWithValue(
          InMemoryBatterySettingsStore(
            initialEnabled: batteryOptimizationEnabled,
          ),
        ),
        chatListPreferencesStoreProvider.overrideWithValue(
          InMemoryChatListPreferencesStore(),
        ),
        riderModeSettingsStoreProvider.overrideWithValue(
          InMemoryRiderModeSettingsStore(),
        ),
        riderAudioPlaybackProvider.overrideWithValue(NoopRiderAudioPlayback()),
        riderRecorderProvider.overrideWithValue(recorder),
        entitlementStoreProvider.overrideWithValue(
          InMemoryEntitlementStore(initial: plusTestEntitlement()),
        ),
      ],
    );

    _stubMicrophonePermission();

    return LifecycleHarness._(
      container: container,
      transport: transport,
      foreground: foreground,
      identity: identity,
      contacts: contacts,
      recorder: recorder,
      peerNodeId: peerNodeId,
    );
  }

  /// Starts the mesh and connects the trusted peer, returning once the chat
  /// state lists them.
  Future<void> startMeshWithPeer() async {
    await chat.startMesh();
    transport.connectPeer(peerEndpointId, name: 'Peer', nodeId: peerNodeId);
    await settle();
    expect(
      container.read(chatControllerProvider).peers.map((p) => p.nodeId),
      [peerNodeId],
      reason: 'the peer must be visible before a session can start',
    );
  }

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> dispose() async {
    container.dispose();
    await foreground.dispose();
    transport.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permissionChannel, null);
  }

  static const _permissionChannel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );

  /// permission_handler asks the platform for the microphone before a ride;
  /// grant whatever it asks for.
  static void _stubMicrophonePermission() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permissionChannel, (call) async {
          switch (call.method) {
            case 'requestPermissions':
              final asked = (call.arguments as List).cast<int>();
              return {for (final p in asked) p: 1};
            case 'checkPermissionStatus':
              return 1;
            default:
              return null;
          }
        });
  }
}

/// A recorder that never touches the record plugin.
class FakeAudioRecorder extends AudioRecorder {
  final _frames = StreamController<Uint8List>.broadcast();
  bool recording = false;
  int startCount = 0;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    startCount++;
    recording = true;
    return _frames.stream;
  }

  @override
  Future<bool> isRecording() async => recording;

  @override
  Future<String?> stop() async {
    recording = false;
    return null;
  }

  @override
  Future<void> cancel() async {
    recording = false;
  }

  @override
  Future<void> dispose() async {
    recording = false;
    await _frames.close();
  }
}

class _NoopMessageRepository implements MessageRepository {
  @override
  Future<List<AirGridMessage>> loadRecent({int limit = 1000}) async => [];

  @override
  Future<void> save(AirGridMessage message) async {}

  @override
  Future<void> updateStatus(String messageId, DeliveryStatus status) async {}

  @override
  Future<void> markPrivateThreadRead(String peerNodeId) async {}

  @override
  Future<int> prune({
    required int maxMessages,
    required Duration maxAge,
  }) async => 0;

  @override
  Future<void> clearAll() async {}
}
