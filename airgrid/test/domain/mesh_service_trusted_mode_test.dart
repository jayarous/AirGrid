import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/storage/privacy_settings_store.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/models/privacy_mode.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_transport.dart';
import '../helpers/test_node_ids.dart';

Future<LocalIdentityStore> _identity() async {
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': testNodeId('local'),
    'airgrid_display_name': 'Local',
  });
  FlutterSecureStorage.setMockInitialValues({});
  return LocalIdentityStore.create();
}

AirGridPacket _chatPacket(String senderNodeId, {String id = 'chat-1'}) {
  return AirGridPacket(
    messageId: id,
    senderNodeId: senderNodeId,
    senderName: 'Remote',
    timestamp: DateTime.now().millisecondsSinceEpoch,
    content: 'hello',
    seenByNodes: [senderNodeId],
    hopLimit: 8,
    packetType: 'chat',
  );
}

AirGridPacket _locationPacket(String senderNodeId, {String id = 'loc-1'}) {
  return AirGridPacket(
    messageId: id,
    senderNodeId: senderNodeId,
    senderName: 'Remote',
    timestamp: DateTime.now().millisecondsSinceEpoch,
    content:
      '{"nodeId":"$senderNodeId","displayName":"Remote","latitude":1.0,"longitude":1.0,"updatedAt":1704067200000}',
    seenByNodes: [senderNodeId],
    hopLimit: 8,
    packetType: 'location_update',
  );
}

AirGridPacket _keyAnnouncePacket(String senderNodeId, String publicKey) {
  return AirGridPacket(
    messageId: 'ka-1',
    senderNodeId: senderNodeId,
    senderName: 'Remote',
    timestamp: DateTime.now().millisecondsSinceEpoch,
    content: publicKey,
    senderPublicKey: publicKey,
    seenByNodes: [senderNodeId],
    hopLimit: 8,
    packetType: 'key_announce',
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('trusted-only: drops inbound chat from non-trusted sender', () async {
    final transport = FakeTransport();
    final identity = await _identity();
    final contactStore = InMemoryKnownContactStore();
    final privacy = InMemoryPrivacySettingsStore(
      initialMode: PrivacyMode.trustedContactsOnly,
    );
    final mesh = AirGridMeshService(
      transport,
      identity,
      CryptoService(),
      jitterOverrideMs: 0,
      contactStore: contactStore,
      privacyStore: privacy,
    );
    addTearDown(mesh.dispose);

    final received = <dynamic>[];
    final sub = mesh.messageStream.listen(received.add);
    addTearDown(sub.cancel);

    transport.connectPeer('ep-a');
    await Future<void>.delayed(Duration.zero);

    final sender = testNodeId('sender-a');
    transport.receiveBytes('ep-a', TransportCodec.encode(_chatPacket(sender)));
    await Future<void>.delayed(Duration.zero);

    expect(received, isEmpty);
  });

  test('trusted-only: allows key_announce from non-trusted sender', () async {
    final transport = FakeTransport();
    final identity = await _identity();
    final contactStore = InMemoryKnownContactStore();
    final privacy = InMemoryPrivacySettingsStore(
      initialMode: PrivacyMode.trustedContactsOnly,
    );
    final mesh = AirGridMeshService(
      transport,
      identity,
      CryptoService(),
      jitterOverrideMs: 0,
      contactStore: contactStore,
      privacyStore: privacy,
    );
    addTearDown(mesh.dispose);

    transport.connectPeer('ep-a');
    await Future<void>.delayed(Duration.zero);

    final sender = testNodeId('sender-b');
    transport.receiveBytes(
      'ep-a',
      TransportCodec.encode(
        _keyAnnouncePacket(
          sender,
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(contactStore.contacts.any((c) => c.nodeId == sender), isTrue);
  });

  test('trusted-only: sendPrivateMessage returns notTrusted for untrusted peer', () async {
    final transport = FakeTransport();
    final identity = await _identity();
    final contactStore = InMemoryKnownContactStore();
    final privacy = InMemoryPrivacySettingsStore(
      initialMode: PrivacyMode.trustedContactsOnly,
    );
    final mesh = AirGridMeshService(
      transport,
      identity,
      CryptoService(),
      jitterOverrideMs: 0,
      contactStore: contactStore,
      privacyStore: privacy,
    );
    addTearDown(mesh.dispose);

    final peer = MeshPeer(
      endpointId: 'ep-peer',
      displayName: 'Peer',
      connectedAt: DateTime.now(),
      nodeId: testNodeId('peer-node'),
    );

    await contactStore.upsert(
      KnownContact(
        nodeId: peer.nodeId!,
        displayName: 'Peer',
        publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        lastSeenAt: DateTime.now(),
      ),
    );

    final result = await mesh.sendPrivateMessage(peer, 'hello');
    expect(result, PrivateSendResult.notTrusted);
  });

  test('trusted-only: sendPrivateMessageToContact returns notTrusted', () async {
    final transport = FakeTransport();
    final identity = await _identity();
    final contactStore = InMemoryKnownContactStore();
    final privacy = InMemoryPrivacySettingsStore(
      initialMode: PrivacyMode.trustedContactsOnly,
    );
    final mesh = AirGridMeshService(
      transport,
      identity,
      CryptoService(),
      jitterOverrideMs: 0,
      contactStore: contactStore,
      privacyStore: privacy,
    );
    addTearDown(mesh.dispose);

    final contact = KnownContact(
      nodeId: testNodeId('contact-node'),
      displayName: 'Contact',
      publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      lastSeenAt: DateTime.now(),
      lastEndpointId: 'ep-contact',
      isTrusted: false,
    );

    final result = await mesh.sendPrivateMessageToContact(contact, 'hello');
    expect(result, PrivateSendResult.notTrusted);
  });

  test('everyoneNearby: accepts inbound location from non-trusted sender', () async {
    final transport = FakeTransport();
    final identity = await _identity();
    final mesh = AirGridMeshService(
      transport,
      identity,
      CryptoService(),
      jitterOverrideMs: 0,
      contactStore: InMemoryKnownContactStore(),
      privacyStore: InMemoryPrivacySettingsStore(
        initialMode: PrivacyMode.everyoneNearby,
      ),
    );
    addTearDown(mesh.dispose);

    final received = <dynamic>[];
    final sub = mesh.locationStream.listen(received.add);
    addTearDown(sub.cancel);

    transport.connectPeer('ep-a');
    await Future<void>.delayed(Duration.zero);

    final sender = testNodeId('sender-c');
    transport.receiveBytes('ep-a', TransportCodec.encode(_locationPacket(sender)));
    await Future<void>.delayed(Duration.zero);

    expect(received, isNotEmpty);
  });
}
