import 'dart:convert';

import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/local_report_store.dart';
import 'package:airgrid/data/storage/message_repository.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_transport.dart';

class _RecordingMessageRepository implements MessageRepository {
  _RecordingMessageRepository({this.history = const []});

  final List<AirGridMessage> history;
  final List<(String, DeliveryStatus)> updatedStatuses = [];

  @override
  Future<void> clearAll() async {}

  @override
  Future<List<AirGridMessage>> loadRecent({int limit = 1000}) async {
    return history.take(limit).toList();
  }

  @override
  Future<int> prune({
    required int maxMessages,
    required Duration maxAge,
  }) async => 0;

  @override
  Future<void> save(AirGridMessage message) async {}

  @override
  Future<void> updateStatus(String messageId, DeliveryStatus status) async {
    updatedStatuses.add((messageId, status));
  }

  @override
  Future<void> markPrivateThreadRead(String peerNodeId) async {}
}

Future<LocalIdentityStore> _identity() async {
  const localNodeId = '22222222-2222-4222-8222-222222222222';
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': localNodeId,
    'airgrid_display_name': 'TestUser',
  });
  FlutterSecureStorage.setMockInitialValues({});
  return LocalIdentityStore.create();
}

Future<CryptoService> _loadedCrypto(LocalIdentityStore identity) async {
  final crypto = CryptoService();
  await crypto.loadLocalKeyPair(
    identity.privateKeyBase64!,
    identity.publicKeyBase64!,
  );
  return crypto;
}

Future<({
  CryptoService local,
  CryptoService remote,
  String remotePublicKey,
})> _makeReceiptCrypto(LocalIdentityStore identity, String remoteNodeId) async {
  final algorithm = X25519();
  final remoteKeyPair = await algorithm.newKeyPair();
  final remotePublic = await remoteKeyPair.extractPublicKey();
  final remotePrivate = await remoteKeyPair.extractPrivateKeyBytes();
  final remotePublicKey = base64Encode(remotePublic.bytes);

  final local = CryptoService();
  await local.loadLocalKeyPair(
    identity.privateKeyBase64!,
    identity.publicKeyBase64!,
  );
  local.cacheKey(remoteNodeId, remotePublicKey);

  final remote = CryptoService();
  await remote.loadLocalKeyPair(base64Encode(remotePrivate), remotePublicKey);
  remote.cacheKey(identity.nodeId, identity.publicKeyBase64!);

  return (local: local, remote: remote, remotePublicKey: remotePublicKey);
}

KnownContact _directContact(String nodeId, String publicKeyBase64) {
  return KnownContact(
    nodeId: nodeId,
    displayName: nodeId,
    publicKeyBase64: publicKeyBase64,
    lastSeenAt: DateTime.now(),
    lastEndpointId: 'ep-1',
  );
}

AirGridMessage _localImageMessage({
  required String id,
  required String peerNodeId,
  required DateTime timestamp,
  DeliveryStatus deliveryStatus = DeliveryStatus.sent,
}) {
  return AirGridMessage(
    id: id,
    senderNodeId: '22222222-2222-4222-8222-222222222222',
    senderName: 'TestUser',
    content: '[photo]',
    timestamp: timestamp,
    isLocal: true,
    conversationType: 'private',
    peerNodeId: peerNodeId,
    peerName: 'Peer $peerNodeId',
    deliveryStatus: deliveryStatus,
    messageKind: 'image',
    mediaMimeType: 'image/png',
    mediaByteLength: 3,
    mediaWidth: 1,
    mediaHeight: 1,
    mediaTransferId: 'transfer-$id',
    mediaPreviewBase64: base64Encode([1, 2, 3]),
  );
}

ProviderContainer _container({
  required FakeTransport transport,
  required LocalIdentityStore identity,
  required CryptoService crypto,
  required MessageRepository repository,
  KnownContactStore? contactStore,
}) {
  return ProviderContainer(
    overrides: [
      localIdentityStoreProvider.overrideWithValue(identity),
      messageRepositoryProvider.overrideWithValue(repository),
      transportServiceProvider.overrideWithValue(transport),
      playServicesProvider.overrideWithValue(
        FakePlayServices(const PlayServicesStatus.available()),
      ),
      foregroundServiceProvider.overrideWithValue(FakeForegroundService()),
      cryptoServiceProvider.overrideWithValue(crypto),
      knownContactStoreProvider.overrideWithValue(
        contactStore ?? InMemoryKnownContactStore(),
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
}

void main() {
  const remoteNodeId = '11111111-1111-4111-8111-111111111111';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ChatController.automaticImageAckTimeout = const Duration(milliseconds: 20);
    ChatController.automaticImageRetryBackoff = const Duration(
      milliseconds: 5,
    );
    ChatController.automaticImageRetryStartupGrace = const Duration(minutes: 5);
    ChatController.automaticImageRetryMaxAttempts = 2;
    ChatController.imageRetryPeerOnlineTimeout = const Duration(
      milliseconds: 5,
    );
    ChatController.imageRetryPeerOnlinePollInterval = const Duration(
      milliseconds: 1,
    );
    ChatController.imageRetryPeerOnlineSettleDelay = const Duration(
      milliseconds: 1,
    );
    ChatController.imageRetrySecondAttemptDelay = const Duration(
      milliseconds: 1,
    );
    ChatController.imageRetrySecondAttemptTimeout = const Duration(
      milliseconds: 5,
    );
    ChatController.imageRetrySecondAttemptSettleDelay = const Duration(
      milliseconds: 1,
    );
  });

  tearDown(() {
    ChatController.automaticImageAckTimeout = const Duration(seconds: 12);
    ChatController.automaticImageRetryBackoff = const Duration(seconds: 4);
    ChatController.automaticImageRetryStartupGrace = const Duration(minutes: 10);
    ChatController.automaticImageRetryMaxAttempts = 2;
    ChatController.imageRetryPeerOnlineTimeout = const Duration(seconds: 10);
    ChatController.imageRetryPeerOnlinePollInterval = const Duration(
      milliseconds: 200,
    );
    ChatController.imageRetryPeerOnlineSettleDelay = const Duration(seconds: 3);
    ChatController.imageRetrySecondAttemptDelay = const Duration(
      milliseconds: 700,
    );
    ChatController.imageRetrySecondAttemptTimeout = const Duration(seconds: 4);
    ChatController.imageRetrySecondAttemptSettleDelay = const Duration(
      seconds: 1,
    );
  });

  test('startMesh restores recent outgoing image sends into automatic retry', () async {
    final identity = await _identity();
    final crypto = await _loadedCrypto(identity);
    final transport = FakeTransport()..connectPeer('ep-1');
    final repository = _RecordingMessageRepository(
      history: [
        _localImageMessage(
          id: 'img-restore',
          peerNodeId: 'peer-1',
          timestamp: DateTime.now(),
        ),
      ],
    );
    final container = _container(
      transport: transport,
      identity: identity,
      crypto: crypto,
      repository: repository,
    );
    addTearDown(container.dispose);

    final notifier = container.read(chatControllerProvider.notifier);
    await notifier.startMesh();
    // ignore: invalid_use_of_protected_member
    notifier.state = notifier.state.copyWith(
      knownContacts: [_directContact('peer-1', identity.publicKeyBase64!)],
    );

    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(transport.sentPayloads, isNotEmpty);
    expect(
      container.read(chatControllerProvider).messages.single.deliveryStatus,
      isNot(DeliveryStatus.failed),
    );

    await notifier.stopMesh();
  });

  test('automatic image retry marks failed only after retry budget is exhausted', () async {
    final identity = await _identity();
    final transport = FakeTransport();
    final repository = _RecordingMessageRepository(
      history: [
        _localImageMessage(
          id: 'img-fail',
          peerNodeId: 'peer-1',
          timestamp: DateTime.now(),
        ),
      ],
    );
    final container = _container(
      transport: transport,
      identity: identity,
      crypto: CryptoService(),
      repository: repository,
    );
    addTearDown(container.dispose);

    final notifier = container.read(chatControllerProvider.notifier);
    await notifier.startMesh();
    // ignore: invalid_use_of_protected_member
    notifier.state = notifier.state.copyWith(
      knownContacts: [_directContact('peer-1', identity.publicKeyBase64!)],
    );

    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(
      container.read(chatControllerProvider).messages.single.deliveryStatus,
      isNot(DeliveryStatus.failed),
    );

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      container.read(chatControllerProvider).messages.single.deliveryStatus,
      DeliveryStatus.failed,
    );
    expect(
      repository.updatedStatuses.where((entry) => entry.$2 == DeliveryStatus.failed),
      hasLength(1),
    );

    await notifier.stopMesh();
  });

  test('delivery receipt cancels automatic image retry before resend fires', () async {
    final identity = await _identity();
    final receiptCrypto = await _makeReceiptCrypto(identity, remoteNodeId);
    final transport = FakeTransport()..connectPeer('ep-1');
    final repository = _RecordingMessageRepository(
      history: [
        _localImageMessage(
          id: 'img-delivered',
          peerNodeId: remoteNodeId,
          timestamp: DateTime.now(),
        ),
      ],
    );
    final container = _container(
      transport: transport,
      identity: identity,
      crypto: receiptCrypto.local,
      repository: repository,
    );
    addTearDown(container.dispose);

    final notifier = container.read(chatControllerProvider.notifier);
    await notifier.startMesh();
    // ignore: invalid_use_of_protected_member
    notifier.state = notifier.state.copyWith(
      knownContacts: [
        _directContact(remoteNodeId, receiptCrypto.remotePublicKey),
      ],
    );

    final baselinePayloads = transport.sentPayloads.length;
    final encryptedReceiptMessageId = await receiptCrypto.remote.encryptContent(
      'img-delivered',
      identity.nodeId,
    );
    final receipt = AirGridPacket(
      messageId: 'receipt-img-delivered',
      senderNodeId: remoteNodeId,
      senderName: 'peer-1',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: encryptedReceiptMessageId!,
      seenByNodes: const ['peer-1'],
      hopLimit: 8,
      packetType: 'delivery_receipt',
      senderPublicKey: receiptCrypto.remotePublicKey,
      encryptionVersion: 1,
      conversationType: 'private',
      recipientNodeId: identity.nodeId,
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    transport.receiveBytes('ep-1', TransportCodec.encode(receipt));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      container.read(chatControllerProvider).messages.single.deliveryStatus,
      DeliveryStatus.delivered,
    );
    expect(transport.sentPayloads.length, baselinePayloads);

    await notifier.stopMesh();
  });
}
