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
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/models/peer_location.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_transport.dart';
import '../helpers/test_node_ids.dart';

// ---------------------------------------------------------------------------
// Helpers shared across tests
// ---------------------------------------------------------------------------

final _aliceNodeId = testNodeId('alice');
final _bobNodeId = testNodeId('bob');

class _StubMessageRepository implements MessageRepository {
  _StubMessageRepository();

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

Future<LocalIdentityStore> _identity() async {
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': 'local-node-test',
    'airgrid_display_name': 'TestUser',
  });
  FlutterSecureStorage.setMockInitialValues({});
  return LocalIdentityStore.create();
}

ProviderContainer _makeContainer({
  required FakeTransport transport,
  required InMemoryKnownContactStore contactStore,
  required LocalIdentityStore identity,
}) {
  final playServices = FakePlayServices(
    const PlayServicesStatus(
      available: true,
      code: 'available',
      message: 'OK',
      canResolve: false,
    ),
  );
  final foreground = FakeForegroundService();

  return ProviderContainer(
    overrides: [
      localIdentityStoreProvider.overrideWithValue(identity),
      messageRepositoryProvider.overrideWithValue(_StubMessageRepository()),
      transportServiceProvider.overrideWithValue(transport),
      playServicesProvider.overrideWithValue(playServices),
      foregroundServiceProvider.overrideWithValue(foreground),
      cryptoServiceProvider.overrideWithValue(CryptoService()),
      knownContactStoreProvider.overrideWithValue(contactStore),
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

KnownContact _contact(String nodeId, {bool isBlocked = false}) {
  return KnownContact(
    nodeId: nodeId,
    displayName: nodeId,
    publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    lastSeenAt: DateTime(2024, 1, 1),
    isBlocked: isBlocked,
  );
}

AirGridMessage _publicMsg(String senderNodeId, {String id = 'msg-1'}) {
  return AirGridMessage(
    id: id,
    senderNodeId: senderNodeId,
    senderName: senderNodeId,
    content: 'hello',
    timestamp: DateTime(2024, 1, 1, 12),
    isLocal: false,
    conversationType: 'public',
    peerNodeId: null,
  );
}

AirGridMessage _privateMsg(
  String senderNodeId,
  String peerNodeId, {
  String id = 'pm-1',
}) {
  return AirGridMessage(
    id: id,
    senderNodeId: senderNodeId,
    senderName: senderNodeId,
    content: 'private hello',
    timestamp: DateTime(2024, 1, 1, 12),
    isLocal: false,
    conversationType: 'private',
    peerNodeId: peerNodeId,
  );
}

AirGridMessage _localPrivateMsg(String peerNodeId, {String id = 'local-pm-1'}) {
  return AirGridMessage(
    id: id,
    senderNodeId: 'local-node-test',
    senderName: 'TestUser',
    content: 'local private hello',
    timestamp: DateTime(2024, 1, 1, 12),
    isLocal: true,
    conversationType: 'private',
    peerNodeId: peerNodeId,
  );
}

PeerLocation _location(String nodeId) {
  return PeerLocation(
    nodeId: nodeId,
    displayName: nodeId,
    latitude: 1.0,
    longitude: 1.0,
    updatedAt: DateTime(2024, 1, 1),
  );
}

MeshPeer _peer(String endpointId, String nodeId) {
  return MeshPeer(
    endpointId: endpointId,
    displayName: nodeId,
    connectedAt: DateTime(2024, 1, 1),
    nodeId: nodeId,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  // ── filteredMessages hides blocked senders ──────────────────────────────
  group('filteredMessages', () {
    test('hides blocked sender from public conversation', () async {
      final contactStore = InMemoryKnownContactStore();

      final transport = FakeTransport();
      final container = _makeContainer(
        transport: transport,
        contactStore: contactStore,
        identity: await _identity(),
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      final aliceMsg = _publicMsg(_aliceNodeId, id: 'alice-pub');
      final bobMsg = _publicMsg(_bobNodeId, id: 'bob-pub');

      // Inject messages + blocked contact directly into state.
      final notifier = container.read(chatControllerProvider.notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        messages: [aliceMsg, bobMsg],
        knownContacts: [
          _contact(_aliceNodeId, isBlocked: true),
          _contact(_bobNodeId),
        ],
      );

      final state = container.read(chatControllerProvider);
      final ids = state.filteredMessages.map((m) => m.id).toList();

      expect(ids, contains('bob-pub'));
      expect(ids, isNot(contains('alice-pub')));

      transport.dispose();
      await contactStore.dispose();
    });

    test('hides blocked sender from private conversation', () async {
      final contactStore = InMemoryKnownContactStore();

      final transport = FakeTransport();
      final container = _makeContainer(
        transport: transport,
        contactStore: contactStore,
        identity: await _identity(),
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      // Private message where alice is the peer (sent by alice to us).
      final alicePrivateMsg = _privateMsg(
        _aliceNodeId,
        _aliceNodeId,
        id: 'alice-priv',
      );

      final notifier = container.read(chatControllerProvider.notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        messages: [alicePrivateMsg],
        knownContacts: [_contact(_aliceNodeId, isBlocked: true)],
        selectedConversation: PrivateConversation(
          peerNodeId: _aliceNodeId,
          peerName: 'Alice',
        ),
      );

      final state = container.read(chatControllerProvider);
      final ids = state.filteredMessages.map((m) => m.id).toList();

      expect(ids, isNot(contains('alice-priv')));

      transport.dispose();
      await contactStore.dispose();
    });

    test('hides local private history with blocked peer', () async {
      final contactStore = InMemoryKnownContactStore();

      final transport = FakeTransport();
      final container = _makeContainer(
        transport: transport,
        contactStore: contactStore,
        identity: await _identity(),
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      final localToAlice = _localPrivateMsg(_aliceNodeId, id: 'local-alice');

      final notifier = container.read(chatControllerProvider.notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        messages: [localToAlice],
        knownContacts: [_contact(_aliceNodeId, isBlocked: true)],
        selectedConversation: PrivateConversation(
          peerNodeId: _aliceNodeId,
          peerName: 'Alice',
        ),
      );

      final ids = container
          .read(chatControllerProvider)
          .filteredMessages
          .map((m) => m.id)
          .toList();

      expect(ids, isNot(contains('local-alice')));

      transport.dispose();
      await contactStore.dispose();
    });
  });

  // ── blockUser prunes state ───────────────────────────────────────────────
  group('blockUser', () {
    test('removes peer from peers list', () async {
      final contactStore = InMemoryKnownContactStore();
      await contactStore.upsert(_contact(_aliceNodeId));

      final transport = FakeTransport();
      final container = _makeContainer(
        transport: transport,
        contactStore: contactStore,
        identity: await _identity(),
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      // Inject alice as a peer directly into state.
      final notifier = container.read(chatControllerProvider.notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        peers: [_peer('ep-alice', _aliceNodeId)],
      );

      await notifier.blockUser(_aliceNodeId);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(chatControllerProvider);
      expect(
        state.peers.where((p) => p.nodeId == _aliceNodeId),
        isEmpty,
        reason: 'blocked peer must be removed from peers list',
      );

      transport.dispose();
      await contactStore.dispose();
    });

    test('removes peer location from peerLocations', () async {
      final contactStore = InMemoryKnownContactStore();
      await contactStore.upsert(_contact(_aliceNodeId));

      final transport = FakeTransport();
      final container = _makeContainer(
        transport: transport,
        contactStore: contactStore,
        identity: await _identity(),
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      final notifier = container.read(chatControllerProvider.notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        peerLocations: {_aliceNodeId: _location(_aliceNodeId)},
      );

      await notifier.blockUser(_aliceNodeId);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(chatControllerProvider);
      expect(
        state.peerLocations.containsKey(_aliceNodeId),
        isFalse,
        reason: 'blocked peer location must be removed',
      );

      transport.dispose();
      await contactStore.dispose();
    });

    test('clears unread count for blocked peer', () async {
      final contactStore = InMemoryKnownContactStore();
      await contactStore.upsert(_contact(_aliceNodeId));

      final transport = FakeTransport();
      final container = _makeContainer(
        transport: transport,
        contactStore: contactStore,
        identity: await _identity(),
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      final notifier = container.read(chatControllerProvider.notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        unreadPrivateCounts: {_aliceNodeId: 5, _bobNodeId: 3},
      );

      await notifier.blockUser(_aliceNodeId);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(chatControllerProvider);
      expect(state.unreadPrivateCounts.containsKey(_aliceNodeId), isFalse);
      expect(state.unreadPrivateCounts[_bobNodeId], equals(3));

      transport.dispose();
      await contactStore.dispose();
    });

    test(
      'switches selected conversation to public when blocking active peer',
      () async {
        final contactStore = InMemoryKnownContactStore();
        await contactStore.upsert(_contact(_aliceNodeId));

        final transport = FakeTransport();
        final container = _makeContainer(
          transport: transport,
          contactStore: contactStore,
          identity: await _identity(),
        );
        addTearDown(container.dispose);
        await Future<void>.delayed(Duration.zero);

        final notifier = container.read(chatControllerProvider.notifier);
        notifier.selectConversation(
          PrivateConversation(peerNodeId: _aliceNodeId, peerName: 'Alice'),
        );
        expect(
          container.read(chatControllerProvider).selectedConversation,
          isA<PrivateConversation>(),
        );

        await notifier.blockUser(_aliceNodeId);
        await Future<void>.delayed(Duration.zero);

        final state = container.read(chatControllerProvider);
        expect(
          state.selectedConversation,
          isA<PublicConversation>(),
          reason: 'blocking active private conv should switch to public',
        );

        transport.dispose();
        await contactStore.dispose();
      },
    );

    test(
      'does not switch conversation when blocking a different peer',
      () async {
        final contactStore = InMemoryKnownContactStore();
        await contactStore.upsert(_contact(_aliceNodeId));
        await contactStore.upsert(_contact(_bobNodeId));

        final transport = FakeTransport();
        final container = _makeContainer(
          transport: transport,
          contactStore: contactStore,
          identity: await _identity(),
        );
        addTearDown(container.dispose);
        await Future<void>.delayed(Duration.zero);

        final notifier = container.read(chatControllerProvider.notifier);
        notifier.selectConversation(
          PrivateConversation(peerNodeId: _bobNodeId, peerName: 'Bob'),
        );

        await notifier.blockUser(_aliceNodeId);
        await Future<void>.delayed(Duration.zero);

        final state = container.read(chatControllerProvider);
        expect(
          state.selectedConversation,
          isA<PrivateConversation>(),
          reason: 'conversation with Bob should stay when Alice is blocked',
        );

        transport.dispose();
        await contactStore.dispose();
      },
    );
  });

  // ── unblockUser updates store ────────────────────────────────────────────
  group('unblockUser', () {
    test('unblocks the contact in the store', () async {
      final contactStore = InMemoryKnownContactStore();
      await contactStore.upsert(_contact(_aliceNodeId, isBlocked: true));

      final transport = FakeTransport();
      final container = _makeContainer(
        transport: transport,
        contactStore: contactStore,
        identity: await _identity(),
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      await container
          .read(chatControllerProvider.notifier)
          .unblockUser(_aliceNodeId);
      await Future<void>.delayed(Duration.zero);

      expect(contactStore.isBlocked(_aliceNodeId), isFalse);

      transport.dispose();
      await contactStore.dispose();
    });
  });

  // ── blockedNodeIds derived getter ────────────────────────────────────────
  group('blockedNodeIds', () {
    test('returns node IDs of all blocked contacts', () async {
      final contactStore = InMemoryKnownContactStore();

      final transport = FakeTransport();
      final container = _makeContainer(
        transport: transport,
        contactStore: contactStore,
        identity: await _identity(),
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      // Inject knownContacts directly into state.
      final notifier = container.read(chatControllerProvider.notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        knownContacts: [
          _contact(_aliceNodeId, isBlocked: true),
          _contact(_bobNodeId),
        ],
      );

      final state = container.read(chatControllerProvider);
      expect(state.blockedNodeIds, contains(_aliceNodeId));
      expect(state.blockedNodeIds, isNot(contains(_bobNodeId)));

      transport.dispose();
      await contactStore.dispose();
    });
  });

  group('selectConversation', () {
    test('refuses blocked private conversation', () async {
      final contactStore = InMemoryKnownContactStore();

      final transport = FakeTransport();
      final container = _makeContainer(
        transport: transport,
        contactStore: contactStore,
        identity: await _identity(),
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      final notifier = container.read(chatControllerProvider.notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        knownContacts: [_contact(_aliceNodeId, isBlocked: true)],
      );

      notifier.selectConversation(
        PrivateConversation(peerNodeId: _aliceNodeId, peerName: 'Alice'),
      );

      expect(
        container.read(chatControllerProvider).selectedConversation,
        isA<PublicConversation>(),
      );

      transport.dispose();
      await contactStore.dispose();
    });
  });
}
