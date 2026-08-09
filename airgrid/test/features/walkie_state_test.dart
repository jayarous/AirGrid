import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:airgrid/features/chat/walkie_session_controller.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_transport.dart';
import '../helpers/packet_decoder.dart';

const _localNodeId = '11111111-1111-4111-8111-111111111111';
const _privatePeerNodeId = '22222222-2222-4222-8222-222222222222';

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
    'airgrid_node_id': _localNodeId,
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
      // These cases exercise walkie mechanics, not the paywall, so they run as
      // a subscriber. Free-tier gate behaviour is covered by
      // plus_gate_enforcement_test.dart.
      entitlementStoreProvider.overrideWithValue(
        InMemoryEntitlementStore(initial: plusTestEntitlement()),
      ),
    ],
  );
}

void _receiveWalkieControl(
  FakeTransport transport, {
  required String fromEndpointId,
  required String senderNodeId,
  required String senderName,
  required String recipientNodeId,
  required String action,
  required String sessionId,
}) {
  final packet = AirGridPacket(
    messageId: 'control-$action-$sessionId',
    senderNodeId: senderNodeId,
    senderName: senderName,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    content: WalkieControlMessage(
      action: action,
      sessionId: sessionId,
    ).toWire(),
    seenByNodes: [senderNodeId],
    hopLimit: AirGridConstants.kHopLimit,
    packetType: 'chat',
    conversationType: 'private',
    recipientNodeId: recipientNodeId,
  );

  transport.receiveBytes(fromEndpointId, TransportCodec.encode(packet));
}

void main() {
  test('walkie state setters update and clear transient state', () async {
    final container = _container(identity: await _identity());
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);

    controller.setWalkiePeerNodeId(_privatePeerNodeId);
    controller.setWalkieTransmitting(
      isTransmitting: true,
      peerNodeId: _privatePeerNodeId,
    );
    controller.setWalkieSending(isSending: true);
    controller.setWalkieLastError('mesh offline');

    var state = container.read(chatControllerProvider);
    expect(state.walkie.peerNodeId, _privatePeerNodeId);
    expect(state.walkie.isTransmitting, isTrue);
    expect(state.walkie.isSending, isTrue);
    expect(state.walkie.lastError, 'mesh offline');

    controller.setWalkieTransmitting(isTransmitting: false);
    controller.setWalkieSending(isSending: false);
    controller.setWalkieLastError(null);

    state = container.read(chatControllerProvider);
    expect(state.walkie.isTransmitting, isFalse);
    expect(state.walkie.isSending, isFalse);
    expect(state.walkie.lastError, isNull);
  });

  test(
    'selectConversation syncs walkie.peerNodeId for private threads',
    () async {
      final container = _container(identity: await _identity());
      addTearDown(container.dispose);

      final controller = container.read(chatControllerProvider.notifier);

      controller.selectConversation(
        const PrivateConversation(peerNodeId: 'peer-42', peerName: 'Alex'),
      );

      var state = container.read(chatControllerProvider);
      expect(state.walkie.peerNodeId, 'peer-42');

      controller.selectConversation(const PublicConversation());

      state = container.read(chatControllerProvider);
      expect(state.walkie.peerNodeId, isNull);
    },
  );

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
    controller.setWalkieTransmitting(
      isTransmitting: true,
      peerNodeId: 'peer-9',
    );
    controller.setWalkieSending(isSending: true);
    controller.setWalkieLastError('failed');

    await controller.stopMesh();

    final state = container.read(chatControllerProvider);
    expect(state.walkie.isTransmitting, isFalse);
    expect(state.walkie.isSending, isFalse);
    expect(state.walkie.lastError, isNull);
    expect(transport.stopCount, 1);
    expect(foreground.stopCount, 1);
  });

  test(
    'selectConversation keeps the walkie target while a session is live',
    () async {
      final transport = FakeTransport();
      final container = _container(
        identity: await _identity(),
        transport: transport,
      );
      addTearDown(container.dispose);

      final controller = container.read(chatControllerProvider.notifier);
      await controller.startMesh();
      transport.connectPeer(
        'endpoint-1',
        name: 'Alex',
        nodeId: _privatePeerNodeId,
      );
      await Future<void>.delayed(Duration.zero);

      final peer = MeshPeer(
        endpointId: 'endpoint-1',
        displayName: 'Alex',
        connectedAt: DateTime.now(),
        nodeId: _privatePeerNodeId,
        encryptionReady: false,
      );

      expect(await controller.sendWalkieInvite(peer), isTrue);
      final sessionId = container
          .read(chatControllerProvider)
          .walkie
          .inviteSessionId!;

      _receiveWalkieControl(
        transport,
        fromEndpointId: 'endpoint-1',
        senderNodeId: _privatePeerNodeId,
        senderName: 'Alex',
        recipientNodeId: _localNodeId,
        action: 'accept',
        sessionId: sessionId,
      );
      await Future<void>.delayed(Duration.zero);

      var state = container.read(chatControllerProvider);
      expect(state.walkie.sessionActivePeerNodeId, _privatePeerNodeId);

      // Stepping over to the public channel must not wipe the target of a
      // session that is still live - doing so made the walkie screen ask the
      // user to pick a peer they had already invited and had accepted.
      controller.selectConversation(const PublicConversation());

      state = container.read(chatControllerProvider);
      expect(state.walkie.sessionActivePeerNodeId, _privatePeerNodeId);
      expect(state.walkie.peerNodeId, _privatePeerNodeId);
    },
  );

  test('sendWalkieInvite sets outgoing invite state', () async {
    final transport = FakeTransport();
    final container = _container(
      identity: await _identity(),
      transport: transport,
    );
    addTearDown(container.dispose);

    transport.connectPeer(
      'endpoint-1',
      name: 'Alex',
      nodeId: _privatePeerNodeId,
    );

    final controller = container.read(chatControllerProvider.notifier);
    final peer = MeshPeer(
      endpointId: 'endpoint-1',
      displayName: 'Alex',
      connectedAt: DateTime.now(),
      nodeId: _privatePeerNodeId,
      encryptionReady: false,
    );

    final ok = await controller.sendWalkieInvite(peer);

    expect(ok, isTrue);
    final state = container.read(chatControllerProvider);
    expect(state.walkie.inviteSessionId, isNotNull);
    expect(state.walkie.invitePeerNodeId, _privatePeerNodeId);
    expect(state.walkie.inviteIsIncoming, isFalse);
    expect(transport.sentPayloads, isNotEmpty);
  });

  test(
    'acceptWalkieInvite activates incoming private walkie session',
    () async {
      final transport = FakeTransport();
      final container = _container(
        identity: await _identity(),
        transport: transport,
      );
      addTearDown(container.dispose);

      final controller = container.read(chatControllerProvider.notifier);
      await controller.startMesh();
      transport.connectPeer(
        'endpoint-1',
        name: 'Alex',
        nodeId: _privatePeerNodeId,
      );
      await Future<void>.delayed(Duration.zero);

      _receiveWalkieControl(
        transport,
        fromEndpointId: 'endpoint-1',
        senderNodeId: _privatePeerNodeId,
        senderName: 'Alex',
        recipientNodeId: _localNodeId,
        action: 'invite',
        sessionId: 'session-1',
      );
      await Future<void>.delayed(Duration.zero);

      var state = container.read(chatControllerProvider);
      expect(state.walkie.invitePeerNodeId, _privatePeerNodeId);
      expect(state.walkie.inviteIsIncoming, isTrue);

      final ok = await controller.acceptWalkieInvite();

      expect(ok, isTrue);
      state = container.read(chatControllerProvider);
      expect(state.walkie.sessionActivePeerNodeId, _privatePeerNodeId);
      expect(state.walkie.peerNodeId, _privatePeerNodeId);
      expect(state.walkie.invitePeerNodeId, isNull);
      expect(
        decodeSentPackets(
          transport,
        ).where((packet) => packet.content.contains('"action":"accept"')),
        isNotEmpty,
      );
    },
  );

  test('incoming accept activates outgoing private walkie session', () async {
    final transport = FakeTransport();
    final container = _container(
      identity: await _identity(),
      transport: transport,
    );
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    transport.connectPeer(
      'endpoint-1',
      name: 'Alex',
      nodeId: _privatePeerNodeId,
    );
    await Future<void>.delayed(Duration.zero);

    final peer = MeshPeer(
      endpointId: 'endpoint-1',
      displayName: 'Alex',
      connectedAt: DateTime.now(),
      nodeId: _privatePeerNodeId,
      encryptionReady: false,
    );
    expect(await controller.sendWalkieInvite(peer), isTrue);
    final sessionId = container
        .read(chatControllerProvider)
        .walkie
        .inviteSessionId;
    expect(sessionId, isNotNull);

    _receiveWalkieControl(
      transport,
      fromEndpointId: 'endpoint-1',
      senderNodeId: _privatePeerNodeId,
      senderName: 'Alex',
      recipientNodeId: _localNodeId,
      action: 'accept',
      sessionId: sessionId!,
    );
    await Future<void>.delayed(Duration.zero);

    final state = container.read(chatControllerProvider);
    expect(state.walkie.sessionActivePeerNodeId, _privatePeerNodeId);
    expect(state.walkie.peerNodeId, _privatePeerNodeId);
    expect(state.walkie.invitePeerNodeId, isNull);

    // selectedConversation is deliberately NOT asserted here. The accept
    // arrives from the remote peer, and switching the local user's open
    // conversation in response would yank them out of whatever they were
    // reading. Session activation is what this test is about, and that is
    // covered by sessionActivePeerNodeId above; the walkie screen reads that
    // field rather than selectedConversation.
  });

  test('incoming end clears active private walkie session', () async {
    final transport = FakeTransport();
    final container = _container(
      identity: await _identity(),
      transport: transport,
    );
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    transport.connectPeer(
      'endpoint-1',
      name: 'Alex',
      nodeId: _privatePeerNodeId,
    );
    await Future<void>.delayed(Duration.zero);

    final peer = MeshPeer(
      endpointId: 'endpoint-1',
      displayName: 'Alex',
      connectedAt: DateTime.now(),
      nodeId: _privatePeerNodeId,
      encryptionReady: false,
    );
    expect(await controller.sendWalkieInvite(peer), isTrue);
    final sessionId = container
        .read(chatControllerProvider)
        .walkie
        .inviteSessionId;
    expect(sessionId, isNotNull);
    _receiveWalkieControl(
      transport,
      fromEndpointId: 'endpoint-1',
      senderNodeId: _privatePeerNodeId,
      senderName: 'Alex',
      recipientNodeId: _localNodeId,
      action: 'accept',
      sessionId: sessionId!,
    );
    await Future<void>.delayed(Duration.zero);

    controller.setWalkieTransmitting(
      isTransmitting: true,
      peerNodeId: _privatePeerNodeId,
    );
    controller.setWalkieSending(isSending: true);
    _receiveWalkieControl(
      transport,
      fromEndpointId: 'endpoint-1',
      senderNodeId: _privatePeerNodeId,
      senderName: 'Alex',
      recipientNodeId: _localNodeId,
      action: 'end',
      sessionId: sessionId,
    );
    await Future<void>.delayed(Duration.zero);

    final state = container.read(chatControllerProvider);
    expect(state.walkie.sessionActivePeerNodeId, isNull);
    expect(state.walkie.invitePeerNodeId, isNull);
    expect(state.walkie.isTransmitting, isFalse);
    expect(state.walkie.isSending, isFalse);
    expect(state.walkie.lastError, 'Alex ended the walkie session');
  });

  test('peer disconnect clears active private walkie session', () async {
    final transport = FakeTransport();
    final container = _container(
      identity: await _identity(),
      transport: transport,
    );
    addTearDown(container.dispose);

    final controller = container.read(chatControllerProvider.notifier);
    await controller.startMesh();
    transport.connectPeer(
      'endpoint-1',
      name: 'Alex',
      nodeId: _privatePeerNodeId,
    );
    await Future<void>.delayed(Duration.zero);

    final peer = MeshPeer(
      endpointId: 'endpoint-1',
      displayName: 'Alex',
      connectedAt: DateTime.now(),
      nodeId: _privatePeerNodeId,
      encryptionReady: false,
    );
    expect(await controller.sendWalkieInvite(peer), isTrue);
    final sessionId = container
        .read(chatControllerProvider)
        .walkie
        .inviteSessionId;
    expect(sessionId, isNotNull);
    _receiveWalkieControl(
      transport,
      fromEndpointId: 'endpoint-1',
      senderNodeId: _privatePeerNodeId,
      senderName: 'Alex',
      recipientNodeId: _localNodeId,
      action: 'accept',
      sessionId: sessionId!,
    );
    await Future<void>.delayed(Duration.zero);

    controller.setWalkieTransmitting(
      isTransmitting: true,
      peerNodeId: _privatePeerNodeId,
    );
    controller.setWalkieSending(isSending: true);
    transport.disconnectPeer('endpoint-1');
    await Future<void>.delayed(Duration.zero);

    final state = container.read(chatControllerProvider);
    expect(state.peers, isEmpty);
    expect(state.walkie.sessionActivePeerNodeId, isNull);
    expect(state.walkie.invitePeerNodeId, isNull);
    expect(state.walkie.isTransmitting, isFalse);
    expect(state.walkie.isSending, isFalse);
    expect(state.walkie.lastError, 'Private walkie peer disconnected');
  });

  test(
    'private walkie audio can use direct fallback after accepted session',
    () async {
      final transport = FakeTransport();
      final container = _container(
        identity: await _identity(),
        transport: transport,
      );
      addTearDown(container.dispose);

      final controller = container.read(chatControllerProvider.notifier);
      await controller.startMesh();
      transport.connectPeer(
        'endpoint-1',
        name: 'Alex',
        nodeId: _privatePeerNodeId,
      );
      await Future<void>.delayed(Duration.zero);

      final peer = MeshPeer(
        endpointId: 'endpoint-1',
        displayName: 'Alex',
        connectedAt: DateTime.now(),
        nodeId: _privatePeerNodeId,
        encryptionReady: false,
      );
      expect(await controller.sendWalkieInvite(peer), isTrue);
      final sessionId = container
          .read(chatControllerProvider)
          .walkie
          .inviteSessionId;
      expect(sessionId, isNotNull);
      _receiveWalkieControl(
        transport,
        fromEndpointId: 'endpoint-1',
        senderNodeId: _privatePeerNodeId,
        senderName: 'Alex',
        recipientNodeId: _localNodeId,
        action: 'accept',
        sessionId: sessionId!,
      );
      await Future<void>.delayed(Duration.zero);

      final result = await controller.sendPrivateAudio(
        peer,
        const AudioAttachmentPayload(
          transferId: 'walkie-transfer-1',
          mimeType: 'audio/m4a',
          byteLength: 4,
          durationMs: 1200,
          source: AudioAttachmentPayload.sourceWalkie,
          dataBase64: 'AQIDBA==',
        ),
        allowPlaintextFallback: true,
      );

      expect(result, PrivateSendResult.sentPlaintext);
      final audioPackets = decodeSentPackets(
        transport,
      ).where((packet) => packet.packetType == 'audio').toList();
      expect(audioPackets, hasLength(1));
      expect(audioPackets.single.conversationType, 'private');
      expect(audioPackets.single.recipientNodeId, _privatePeerNodeId);
      expect(audioPackets.single.encryptionVersion, isNull);
      expect(audioPackets.single.content, contains('"source":"walkie"'));
    },
  );
}
