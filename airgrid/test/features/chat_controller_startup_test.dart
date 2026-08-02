import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/chat_list_preferences_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/storage/public_walkie_settings_store.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_transport.dart';

class _RecordingMessageRepository implements MessageRepository {
  final List<AirGridMessage> history;
  final List<AirGridMessage> saved = [];
  final List<({int maxMessages, Duration maxAge})> pruneCalls = [];
  int clearAllCount = 0;

  _RecordingMessageRepository({this.history = const []});

  @override
  Future<List<AirGridMessage>> loadRecent({int limit = 1000}) async =>
      history.take(limit).toList();

  @override
  Future<void> save(AirGridMessage message) async {
    saved.add(message);
  }

  @override
  Future<void> updateStatus(String messageId, DeliveryStatus status) async {}

  @override
  Future<void> markPrivateThreadRead(String peerNodeId) async {}

  @override
  Future<int> prune({
    required int maxMessages,
    required Duration maxAge,
  }) async {
    pruneCalls.add((maxMessages: maxMessages, maxAge: maxAge));
    return 0;
  }

  @override
  Future<void> clearAll() async {
    clearAllCount++;
  }
}

AirGridMessage _msg(int index) {
  return AirGridMessage(
    id: 'history-$index',
    senderNodeId: 'node-$index',
    senderName: 'Peer $index',
    content: 'Message $index',
    timestamp: DateTime(2026, 1, 1, 12, index % 60),
    isLocal: false,
  );
}

AirGridMessage _privateMsg({
  required String id,
  required String peerNodeId,
  bool isRead = false,
}) {
  return AirGridMessage(
    id: id,
    senderNodeId: peerNodeId,
    senderName: 'Peer $peerNodeId',
    content: 'Private message',
    timestamp: DateTime(2026, 1, 1, 12),
    isLocal: false,
    conversationType: 'private',
    peerNodeId: peerNodeId,
    peerName: 'Peer $peerNodeId',
    isRead: isRead,
  );
}

Future<LocalIdentityStore> _identity() async {
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': 'local-node',
    'airgrid_display_name': 'Jay',
  });
  FlutterSecureStorage.setMockInitialValues({});
  return LocalIdentityStore.create();
}

ProviderContainer _container({
  required FakeTransport transport,
  required FakePlayServices playServices,
  required FakeForegroundService foreground,
  required LocalIdentityStore identity,
  _RecordingMessageRepository? repository,
  BatterySettingsStore? batteryStore,
  KnownContactStore? contactStore,
  ChatListPreferencesStore? chatListPreferencesStore,
}) {
  return ProviderContainer(
    overrides: [
      localIdentityStoreProvider.overrideWithValue(identity),
      messageRepositoryProvider.overrideWithValue(
        repository ?? _RecordingMessageRepository(),
      ),
      transportServiceProvider.overrideWithValue(transport),
      playServicesProvider.overrideWithValue(playServices),
      foregroundServiceProvider.overrideWithValue(foreground),
      cryptoServiceProvider.overrideWithValue(CryptoService()),
      knownContactStoreProvider.overrideWithValue(
        contactStore ?? InMemoryKnownContactStore(),
      ),
      localReportStoreProvider.overrideWithValue(InMemoryLocalReportStore()),
      privacySettingsStoreProvider.overrideWithValue(
        InMemoryPrivacySettingsStore(),
      ),
      publicWalkieSettingsStoreProvider.overrideWithValue(
        InMemoryPublicWalkieSettingsStore(),
      ),
      batterySettingsStoreProvider.overrideWithValue(
        batteryStore ?? InMemoryBatterySettingsStore(),
      ),
      chatListPreferencesStoreProvider.overrideWithValue(
        chatListPreferencesStore ?? InMemoryChatListPreferencesStore(),
      ),
    ],
  );
}

void main() {
  test('startMesh gates startup when Play Services is unavailable', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(
      const PlayServicesStatus(
        available: false,
        code: 'missing',
        message: 'Google Play Services is missing.',
        canResolve: true,
      ),
    );
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    await container.read(chatControllerProvider.notifier).startMesh();
    final state = container.read(chatControllerProvider);

    expect(transport.startCount, 0);
    expect(foreground.startCount, 0);
    expect(state.meshStarted, isFalse);
    expect(state.isAdvertising, isFalse);
    expect(state.isDiscovering, isFalse);
    expect(state.playServicesAvailable, isFalse);
    expect(state.playServicesCode, 'missing');
    expect(state.lastEvent, contains('missing'));
  });

  test(
    'startMesh loads battery setting even when Play Services is unavailable',
    () async {
      final transport = FakeTransport();
      final foreground = FakeForegroundService();
      final playServices = FakePlayServices(
        const PlayServicesStatus(
          available: false,
          code: 'missing',
          message: 'Google Play Services is missing.',
          canResolve: true,
        ),
      );
      final container = _container(
        transport: transport,
        playServices: playServices,
        foreground: foreground,
        identity: await _identity(),
        batteryStore: InMemoryBatterySettingsStore(initialEnabled: false),
      );
      addTearDown(container.dispose);
      addTearDown(foreground.dispose);

      await container.read(chatControllerProvider.notifier).startMesh();
      final state = container.read(chatControllerProvider);

      expect(state.meshStarted, isFalse);
      expect(state.batteryOptimizationEnabled, isFalse);
    },
  );

  test('transport start failure leaves mesh offline and cleans up', () async {
    final transport = FakeTransport()..failStart = true;
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    await container.read(chatControllerProvider.notifier).startMesh();
    final state = container.read(chatControllerProvider);

    expect(transport.startCount, 1);
    expect(transport.stopCount, 1);
    expect(foreground.startCount, 1);
    expect(foreground.stopCount, 1);
    expect(state.meshStarted, isFalse);
    expect(state.isAdvertising, isFalse);
    expect(state.isDiscovering, isFalse);
    expect(state.lastEvent, contains('Mesh startup failed'));
  });

  test('startMesh loads at most 1000 messages and prunes retention', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final repository = _RecordingMessageRepository(
      history: List.generate(1005, _msg),
    );
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
      repository: repository,
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    await container.read(chatControllerProvider.notifier).startMesh();
    // Trigger provider build, then wait for async preference load.
    container.read(chatControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final state = container.read(chatControllerProvider);

    expect(state.messages, hasLength(1000));
    expect(repository.pruneCalls, hasLength(1));
    expect(repository.pruneCalls.single.maxMessages, 1000);
    expect(repository.pruneCalls.single.maxAge, const Duration(days: 30));
  });

  test('clearAllChats clears persisted and visible chat state', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final repository = _RecordingMessageRepository(history: [_msg(1), _msg(2)]);
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
      repository: repository,
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    controller.selectConversation(
      const PrivateConversation(peerNodeId: 'node-1', peerName: 'Peer 1'),
    );

    await controller.clearAllChats();
    final state = container.read(chatControllerProvider);

    expect(repository.clearAllCount, 1);
    expect(state.messages, isEmpty);
    expect(state.unreadPrivateCounts, isEmpty);
    expect(state.selectedConversation, isA<PublicConversation>());
  });

  test(
    'startMesh restores unread private counts from persisted history',
    () async {
      final transport = FakeTransport();
      final foreground = FakeForegroundService();
      final playServices = FakePlayServices(
        const PlayServicesStatus.available(),
      );
      final repository = _RecordingMessageRepository(
        history: [
          _privateMsg(id: 'unread-1', peerNodeId: 'node-alice'),
          _privateMsg(id: 'unread-2', peerNodeId: 'node-alice'),
          _privateMsg(id: 'read-1', peerNodeId: 'node-bob', isRead: true),
        ],
      );
      final container = _container(
        transport: transport,
        playServices: playServices,
        foreground: foreground,
        identity: await _identity(),
        repository: repository,
      );
      addTearDown(container.dispose);
      addTearDown(foreground.dispose);

      await container.read(chatControllerProvider.notifier).startMesh();
      final state = container.read(chatControllerProvider);

      expect(state.unreadPrivateCounts, {'node-alice': 2});
    },
  );

  test('battery optimization stops mesh when app pauses', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
      batteryStore: InMemoryBatterySettingsStore(initialEnabled: true),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    await controller.handleAppLifecycleState(AppLifecycleState.paused);
    final state = container.read(chatControllerProvider);

    expect(state.meshStarted, isFalse);
    expect(state.isAdvertising, isFalse);
    expect(state.isDiscovering, isFalse);
    expect(transport.stopCount, greaterThanOrEqualTo(1));
    expect(foreground.stopCount, greaterThanOrEqualTo(1));
  });

  test('battery optimization stops mesh when app becomes inactive', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
      batteryStore: InMemoryBatterySettingsStore(initialEnabled: true),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    await controller.handleAppLifecycleState(AppLifecycleState.inactive);
    final state = container.read(chatControllerProvider);

    expect(state.meshStarted, isFalse);
    expect(foreground.stopCount, greaterThanOrEqualTo(1));
  });

  test(
    'battery optimization restarts mesh on resume after auto-stop',
    () async {
      final transport = FakeTransport();
      final foreground = FakeForegroundService();
      final playServices = FakePlayServices(
        const PlayServicesStatus.available(),
      );
      final container = _container(
        transport: transport,
        playServices: playServices,
        foreground: foreground,
        identity: await _identity(),
        batteryStore: InMemoryBatterySettingsStore(initialEnabled: true),
      );
      addTearDown(container.dispose);
      addTearDown(foreground.dispose);

      final controller = container.read(chatControllerProvider.notifier);
      await controller.startMesh();
      await controller.handleAppLifecycleState(AppLifecycleState.paused);
      expect(container.read(chatControllerProvider).meshStarted, isFalse);

      await controller.handleAppLifecycleState(AppLifecycleState.resumed);
      final state = container.read(chatControllerProvider);

      expect(state.meshStarted, isTrue);
      expect(transport.startCount, 2);
      expect(foreground.startCount, 2);
    },
  );

  test('resume does not restart mesh after manual stop', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
      batteryStore: InMemoryBatterySettingsStore(initialEnabled: true),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    await controller.stopMesh();
    await controller.handleAppLifecycleState(AppLifecycleState.resumed);
    final state = container.read(chatControllerProvider);

    expect(state.meshStarted, isFalse);
    expect(transport.startCount, 1);
  });

  test('battery optimization off keeps mesh running when app pauses', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
      batteryStore: InMemoryBatterySettingsStore(initialEnabled: false),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    await controller.handleAppLifecycleState(AppLifecycleState.paused);
    final state = container.read(chatControllerProvider);

    expect(state.meshStarted, isTrue);
    expect(state.isAdvertising, isTrue);
    expect(state.isDiscovering, isTrue);
    expect(foreground.stopCount, 0);
  });

  test('can toggle advertising independently while mesh is running', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    await controller.setAdvertisingEnabled(false);
    expect(container.read(chatControllerProvider).isAdvertising, isFalse);
    expect(transport.stopAdvertisingCount, 1);

    await controller.setAdvertisingEnabled(true);
    expect(container.read(chatControllerProvider).isAdvertising, isTrue);
    expect(transport.startAdvertisingCount, 1);
  });

  test('can toggle discovery independently while mesh is running', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    await controller.setDiscoveryEnabled(false);
    expect(container.read(chatControllerProvider).isDiscovering, isFalse);
    expect(transport.stopDiscoveryCount, 1);

    await controller.setDiscoveryEnabled(true);
    expect(container.read(chatControllerProvider).isDiscovering, isTrue);
    expect(transport.startDiscoveryCount, 1);
  });

  test('chat list filter setters persist and update state', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final prefsStore = InMemoryChatListPreferencesStore(
      initialShowOnlineOnly: true,
      initialShowClosedChats: true,
    );
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
      chatListPreferencesStore: prefsStore,
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.setShowOnlineOnly(true);
    await controller.setShowClosedChats(true);
    final state = container.read(chatControllerProvider);
    expect(state.showOnlineOnly, isTrue);
    expect(state.showClosedChats, isTrue);
    expect(prefsStore.currentShowOnlineOnly, isTrue);
    expect(prefsStore.currentShowClosedChats, isTrue);
  });

  test(
    'closePrivateChat closes thread and resets selected conversation',
    () async {
      final transport = FakeTransport();
      final foreground = FakeForegroundService();
      final playServices = FakePlayServices(
        const PlayServicesStatus.available(),
      );
      final contacts = InMemoryKnownContactStore();
      await contacts.upsert(
        KnownContact(
          nodeId: 'node-1',
          displayName: 'Peer 1',
          publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          lastSeenAt: DateTime(2026, 1, 1),
        ),
      );
      final container = _container(
        transport: transport,
        playServices: playServices,
        foreground: foreground,
        identity: await _identity(),
        contactStore: contacts,
      );
      addTearDown(container.dispose);
      addTearDown(foreground.dispose);

      final controller = container.read(chatControllerProvider.notifier);
      controller.selectConversation(
        const PrivateConversation(peerNodeId: 'node-1', peerName: 'Peer 1'),
      );

      await controller.closePrivateChat('node-1');
      final state = container.read(chatControllerProvider);
      expect(contacts.isChatClosed('node-1'), isTrue);
      expect(state.selectedConversation, isA<PublicConversation>());

      await controller.reopenPrivateChat('node-1');
      expect(contacts.isChatClosed('node-1'), isFalse);
    },
  );

  test('concurrent stopMesh calls tear down exactly once', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(
      const PlayServicesStatus(
        available: true,
        code: 'available',
        message: 'available',
        canResolve: false,
      ),
    );
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    expect(foreground.startCount, 1);

    final stopsBefore = transport.stopCount;

    // On device, the foreground-service exit request, the pending-exit action
    // and direct UI teardown all raced here: each ran a full teardown, so one
    // logical stop produced three transport stops and three service stops.
    await Future.wait([
      controller.stopMesh(),
      controller.stopMesh(),
      controller.stopMesh(),
    ]);

    expect(foreground.stopCount, 1);
    expect(transport.stopCount, stopsBefore + 1);
    expect(container.read(chatControllerProvider).meshStarted, isFalse);
  });

  test('stopMesh remains callable after an earlier stop completes', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(
      const PlayServicesStatus(
        available: true,
        code: 'available',
        message: 'available',
        canResolve: false,
      ),
    );
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();

    // The reentrancy guard must not latch: a later, genuine stop still runs.
    await controller.stopMesh();
    await controller.stopMesh();

    expect(foreground.stopCount, 2);
  });

  test('concurrent stopMesh calls tear down exactly once', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(
      const PlayServicesStatus(
        available: true,
        code: 'available',
        message: 'available',
        canResolve: false,
      ),
    );
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    expect(foreground.startCount, 1);

    final stopsBefore = transport.stopCount;

    // On device, the foreground-service exit request, the pending-exit action
    // and direct UI teardown all raced here: each ran a full teardown, so one
    // logical stop produced three transport stops and three service stops.
    await Future.wait([
      controller.stopMesh(),
      controller.stopMesh(),
      controller.stopMesh(),
    ]);

    expect(foreground.stopCount, 1);
    expect(transport.stopCount, stopsBefore + 1);
    expect(container.read(chatControllerProvider).meshStarted, isFalse);
  });

  test('stopMesh remains callable after an earlier stop completes', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final playServices = FakePlayServices(
      const PlayServicesStatus(
        available: true,
        code: 'available',
        message: 'available',
        canResolve: false,
      ),
    );
    final container = _container(
      transport: transport,
      playServices: playServices,
      foreground: foreground,
      identity: await _identity(),
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();

    // The reentrancy guard must not latch: a later, genuine stop still runs.
    await controller.stopMesh();
    await controller.stopMesh();

    expect(foreground.stopCount, 2);
  });
}
