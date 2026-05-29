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
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/privacy_mode.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_transport.dart';

class _StubMessageRepository implements MessageRepository {
  @override
  Future<void> clearAll() async {}

  @override
  Future<List<AirGridMessage>> loadRecent({int limit = 1000}) async => [];

  @override
  Future<int> prune({
    required int maxMessages,
    required Duration maxAge,
  }) async => 0;

  @override
  Future<void> save(AirGridMessage message) async {}

  @override
  Future<void> updateStatus(String messageId, DeliveryStatus status) async {}

  @override
  Future<void> markPrivateThreadRead(String peerNodeId) async {}
}

Future<LocalIdentityStore> _identity() async {
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': 'local-node-test',
    'airgrid_display_name': 'TestUser',
  });
  FlutterSecureStorage.setMockInitialValues({});
  return LocalIdentityStore.create();
}

KnownContact _contact(String nodeId, {bool isTrusted = false}) {
  return KnownContact(
    nodeId: nodeId,
    displayName: nodeId,
    publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    lastSeenAt: DateTime(2024, 1, 1),
    isTrusted: isTrusted,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'selectConversation rejects untrusted peer in trusted-only mode',
    () async {
      final identity = await _identity();
      final playServices = FakePlayServices(
        const PlayServicesStatus.available(),
      );
      final foreground = FakeForegroundService();

      final container = ProviderContainer(
        overrides: [
          localIdentityStoreProvider.overrideWithValue(identity),
          messageRepositoryProvider.overrideWithValue(_StubMessageRepository()),
          transportServiceProvider.overrideWithValue(FakeTransport()),
          playServicesProvider.overrideWithValue(playServices),
          foregroundServiceProvider.overrideWithValue(foreground),
          cryptoServiceProvider.overrideWithValue(CryptoService()),
          knownContactStoreProvider.overrideWithValue(
            InMemoryKnownContactStore(),
          ),
          localReportStoreProvider.overrideWithValue(
            InMemoryLocalReportStore(),
          ),
          privacySettingsStoreProvider.overrideWithValue(
            InMemoryPrivacySettingsStore(
              initialMode: PrivacyMode.trustedContactsOnly,
            ),
          ),
          batterySettingsStoreProvider.overrideWithValue(
            InMemoryBatterySettingsStore(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(chatControllerProvider.notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        privacyMode: PrivacyMode.trustedContactsOnly,
        knownContacts: [_contact('trusted-node', isTrusted: true)],
      );

      notifier.selectConversation(
        const PrivateConversation(peerNodeId: 'untrusted-node', peerName: 'X'),
      );

      final selected = container
          .read(chatControllerProvider)
          .selectedConversation;
      expect(selected, isA<PublicConversation>());
    },
  );

  test('hideMessage excludes message from filteredMessages', () async {
    final identity = await _identity();
    final playServices = FakePlayServices(const PlayServicesStatus.available());
    final foreground = FakeForegroundService();

    final container = ProviderContainer(
      overrides: [
        localIdentityStoreProvider.overrideWithValue(identity),
        messageRepositoryProvider.overrideWithValue(_StubMessageRepository()),
        transportServiceProvider.overrideWithValue(FakeTransport()),
        playServicesProvider.overrideWithValue(playServices),
        foregroundServiceProvider.overrideWithValue(foreground),
        cryptoServiceProvider.overrideWithValue(CryptoService()),
        knownContactStoreProvider.overrideWithValue(
          InMemoryKnownContactStore(),
        ),
        localReportStoreProvider.overrideWithValue(InMemoryLocalReportStore()),
        privacySettingsStoreProvider.overrideWithValue(
          InMemoryPrivacySettingsStore(),
        ),
        batterySettingsStoreProvider.overrideWithValue(
          InMemoryBatterySettingsStore(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final msg = AirGridMessage(
      id: 'm1',
      senderNodeId: 'peer',
      senderName: 'Peer',
      content: 'hello',
      timestamp: DateTime(2024, 1, 1, 12),
      isLocal: false,
      conversationType: 'public',
    );

    final notifier = container.read(chatControllerProvider.notifier);
    // ignore: invalid_use_of_protected_member
    notifier.state = notifier.state.copyWith(messages: [msg]);

    notifier.hideMessage('m1');

    final filtered = container.read(chatControllerProvider).filteredMessages;
    expect(filtered, isEmpty);
  });
}
