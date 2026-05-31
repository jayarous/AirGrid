import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_transport.dart';

class _NoopMessageRepository implements MessageRepository {
  @override
  Future<void> clearAll() async {}

  @override
  Future<List<AirGridMessage>> loadRecent({int limit = 1000}) async => [];

  @override
  Future<void> markPrivateThreadRead(String peerNodeId) async {}

  @override
  Future<int> prune({
    required int maxMessages,
    required Duration maxAge,
  }) async => 0;

  @override
  Future<void> save(AirGridMessage message) async {}

  @override
  Future<void> updateStatus(String messageId, DeliveryStatus status) async {}
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
  required LocalIdentityStore identity,
  FakeTransport? transport,
  FakeForegroundService? foreground,
}) {
  return ProviderContainer(
    overrides: [
      localIdentityStoreProvider.overrideWithValue(identity),
      messageRepositoryProvider.overrideWithValue(_NoopMessageRepository()),
      transportServiceProvider.overrideWithValue(transport ?? FakeTransport()),
      playServicesProvider.overrideWithValue(
        FakePlayServices(const PlayServicesStatus.available()),
      ),
      foregroundServiceProvider.overrideWithValue(
        foreground ?? FakeForegroundService(),
      ),
      cryptoServiceProvider.overrideWithValue(CryptoService()),
      knownContactStoreProvider.overrideWithValue(InMemoryKnownContactStore()),
      localReportStoreProvider.overrideWithValue(InMemoryLocalReportStore()),
      privacySettingsStoreProvider.overrideWithValue(
        InMemoryPrivacySettingsStore(),
      ),
      batterySettingsStoreProvider.overrideWithValue(
        InMemoryBatterySettingsStore(),
      ),
    ],
  );
}

void main() {
  test('walkie state setters update and clear transient state', () async {
    final container = _container(identity: await _identity());
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);

    controller.setWalkiePeerNodeId('peer-1');
    controller.setWalkieTransmitting(isTransmitting: true, peerNodeId: 'peer-1');
    controller.setWalkieSending(isSending: true);
    controller.setWalkieLastError('mesh offline');

    var state = container.read(chatControllerProvider);
    expect(state.walkiePeerNodeId, 'peer-1');
    expect(state.walkieIsTransmitting, isTrue);
    expect(state.walkieIsSending, isTrue);
    expect(state.walkieLastError, 'mesh offline');

    controller.setWalkieTransmitting(isTransmitting: false);
    controller.setWalkieSending(isSending: false);
    controller.setWalkieLastError(null);

    state = container.read(chatControllerProvider);
    expect(state.walkieIsTransmitting, isFalse);
    expect(state.walkieIsSending, isFalse);
    expect(state.walkieLastError, isNull);
  });

  test('selectConversation syncs walkiePeerNodeId for private threads', () async {
    final container = _container(identity: await _identity());
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);

    controller.selectConversation(
      const PrivateConversation(peerNodeId: 'peer-42', peerName: 'Alex'),
    );

    var state = container.read(chatControllerProvider);
    expect(state.walkiePeerNodeId, 'peer-42');

    controller.selectConversation(const PublicConversation());

    state = container.read(chatControllerProvider);
    expect(state.walkiePeerNodeId, isNull);
  });

  test('stopMesh clears walkie active flags and error', () async {
    final transport = FakeTransport();
    final foreground = FakeForegroundService();
    final container = _container(
      identity: await _identity(),
      transport: transport,
      foreground: foreground,
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    controller.setWalkieTransmitting(isTransmitting: true, peerNodeId: 'peer-9');
    controller.setWalkieSending(isSending: true);
    controller.setWalkieLastError('failed');

    await controller.stopMesh();

    final state = container.read(chatControllerProvider);
    expect(state.walkieIsTransmitting, isFalse);
    expect(state.walkieIsSending, isFalse);
    expect(state.walkieLastError, isNull);
    expect(transport.stopCount, 1);
    expect(foreground.stopCount, 1);
  });

  test('sendWalkieInvite sets outgoing invite state', () async {
    final transport = FakeTransport();
    final container = _container(identity: await _identity(), transport: transport);
    addTearDown(container.dispose);

    transport.connectPeer('endpoint-1', name: 'Alex', nodeId: 'peer-1');

    final controller = container.read(chatControllerProvider.notifier);
    final peer = MeshPeer(
      endpointId: 'endpoint-1',
      displayName: 'Alex',
      connectedAt: DateTime.now(),
      nodeId: 'peer-1',
      encryptionReady: false,
    );

    final ok = await controller.sendWalkieInvite(peer);

    expect(ok, isTrue);
    final state = container.read(chatControllerProvider);
    expect(state.walkieInviteSessionId, isNotNull);
    expect(state.walkieInvitePeerNodeId, 'peer-1');
    expect(state.walkieInviteIsIncoming, isFalse);
    expect(transport.sentPayloads, isNotEmpty);
  });
}
