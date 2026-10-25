import 'dart:async';

import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/rider_mode_event.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/crypto_identity.dart';
import '../helpers/fake_transport.dart';
import '../helpers/test_node_ids.dart';

/// Inbound private packets are bound to the key pinned for their sender.
///
/// A packet's own `senderPublicKey` proves that somebody holds that key, not
/// that they are the node id on the header. So once a key is pinned for a
/// node, a packet under that node id must decrypt with the pinned key; one
/// that carries a different key is refused and surfaced as a key change,
/// never silently accepted or allowed to replace the pin.
final _localNodeId = testNodeId('local');

/// A peer with a real keypair that can encrypt to the local node.
class _Peer {
  _Peer(this.identity, this.crypto);

  final CryptoTestIdentity identity;
  final CryptoService crypto;

  String get nodeId => identity.nodeId;
  String get publicKey => identity.publicKeyBase64;

  static Future<_Peer> create(
    String name,
    LocalIdentityStore local, {
    String? nodeId,
  }) async {
    var identity = await CryptoTestIdentity.generate(name);
    if (nodeId != null) {
      identity = CryptoTestIdentity(
        nodeId: nodeId,
        displayName: name,
        privateKeyBase64: identity.privateKeyBase64,
        publicKeyBase64: identity.publicKeyBase64,
      );
    }
    final crypto = CryptoService();
    await crypto.loadLocalKeyPair(
      identity.privateKeyBase64,
      identity.publicKeyBase64,
    );
    crypto.cacheKey(local.nodeId, local.publicKeyBase64!);
    return _Peer(identity, crypto);
  }

  /// A version-2 private packet to the local node, encrypted with this
  /// peer's key but claiming to be from [asNodeId] carrying [carriedKey].
  /// Defaults describe an honest packet.
  Future<AirGridPacket> packet({
    required String messageId,
    required String plaintext,
    String? asNodeId,
    String? carriedKey,
    String packetType = 'chat',
    int? version = CryptoService.kEncryptionVersion,
  }) async {
    final senderNodeId = asNodeId ?? nodeId;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final aad = version == CryptoService.kEncryptionVersion
        ? CryptoService.associatedData(
            messageId: messageId,
            senderNodeId: senderNodeId,
            recipientNodeId: _localNodeId,
            packetType: packetType,
            timestamp: timestamp,
          )
        : const <int>[];
    final cipher = await crypto.encryptContent(
      plaintext,
      _localNodeId,
      aad: aad,
    );
    return AirGridPacket(
      messageId: messageId,
      senderNodeId: senderNodeId,
      senderName: identity.displayName,
      timestamp: timestamp,
      content: cipher!,
      seenByNodes: [senderNodeId],
      hopLimit: 8,
      packetType: packetType,
      senderPublicKey: carriedKey ?? publicKey,
      encryptionVersion: version,
      conversationType: 'private',
      recipientNodeId: _localNodeId,
    );
  }

  AirGridPacket announce() => AirGridPacket(
    messageId: 'ka-$nodeId',
    senderNodeId: nodeId,
    senderName: identity.displayName,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    content: '',
    seenByNodes: [nodeId],
    hopLimit: 8,
    packetType: 'key_announce',
    senderPublicKey: publicKey,
  );
}

void main() {
  late FakeTransport transport;
  late LocalIdentityStore identity;
  late CryptoService localCrypto;
  late InMemoryKnownContactStore contacts;
  late AirGridMeshService mesh;
  late _Peer alice;
  late _Peer mallory;
  late List<AirGridMessage> messages;
  late List<dynamic> keyChanges;
  late List<StreamSubscription<dynamic>> subs;

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  void deliver(AirGridPacket packet) =>
      transport.receiveBytes('ep-1', TransportCodec.encode(packet));

  List<AirGridPacket> receiptsSentSince(int before) => transport.sentPayloads
      .skip(before)
      .map((p) => TransportCodec.decode(p.bytes))
      .whereType<AirGridPacket>()
      .where((p) => p.packetType == 'delivery_receipt')
      .toList();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'airgrid_node_id': _localNodeId,
      'airgrid_display_name': 'LocalUser',
    });
    FlutterSecureStorage.setMockInitialValues({});
    identity = await LocalIdentityStore.create();
    localCrypto = CryptoService();
    await localCrypto.loadLocalKeyPair(
      identity.privateKeyBase64!,
      identity.publicKeyBase64!,
    );
    contacts = InMemoryKnownContactStore();
    transport = FakeTransport();
    mesh = AirGridMeshService(
      transport,
      identity,
      localCrypto,
      jitterOverrideMs: 0,
      contactStore: contacts,
    );

    alice = await _Peer.create('Alice', identity);
    // Mallory's packets claim Alice's node id but are sealed with her own key.
    mallory = await _Peer.create('Mallory', identity, nodeId: alice.nodeId);

    messages = [];
    keyChanges = [];
    subs = [
      mesh.messageStream.listen(messages.add),
      mesh.keyChangeStream.listen(keyChanges.add),
    ];

    await settle();
    transport.connectPeer('ep-1');
    await settle();
    deliver(alice.announce());
    await settle();
  });

  tearDown(() async {
    for (final s in subs) {
      await s.cancel();
    }
    await mesh.dispose();
    transport.dispose();
  });

  test(
    'an honest packet under the pinned key is delivered and acked',
    () async {
      final before = transport.sentPayloads.length;
      deliver(await alice.packet(messageId: 'm-1', plaintext: 'hi'));
      await settle();

      expect(messages.map((m) => m.content), ['hi']);
      expect(receiptsSentSince(before), hasLength(1));
      expect(keyChanges, isEmpty);
    },
  );

  test(
    'a packet carrying a key other than the pinned one is refused',
    () async {
      final before = transport.sentPayloads.length;
      deliver(await mallory.packet(messageId: 'forged-1', plaintext: 'pwned'));
      await settle();

      expect(messages, isEmpty, reason: 'nothing is shown under Alice\'s name');
      expect(
        receiptsSentSince(before),
        isEmpty,
        reason: 'a receipt would confirm the forgery reached us',
      );
      expect(keyChanges, hasLength(1));
      expect(keyChanges.single.nodeId, alice.nodeId);
      expect(keyChanges.single.previousPublicKeyBase64, alice.publicKey);
      expect(keyChanges.single.newPublicKeyBase64, mallory.publicKey);
    },
  );

  test('the pinned key survives the forgery', () async {
    deliver(await mallory.packet(messageId: 'forged-1', plaintext: 'pwned'));
    await settle();

    expect(localCrypto.pinnedKeyBase64(alice.nodeId), alice.publicKey);
    final stored = contacts.contacts.firstWhere(
      (c) => c.nodeId == alice.nodeId,
    );
    expect(stored.publicKeyBase64, alice.publicKey);

    // Alice is unaffected: her next message still decrypts.
    deliver(await alice.packet(messageId: 'm-2', plaintext: 'still me'));
    await settle();
    expect(messages.map((m) => m.content), ['still me']);
  });

  test('a stream of forgeries under one key warns once', () async {
    for (var i = 0; i < 5; i++) {
      deliver(await mallory.packet(messageId: 'forged-$i', plaintext: 'x'));
    }
    await settle();

    expect(messages, isEmpty);
    expect(keyChanges, hasLength(1));
  });

  test('a replayed ciphertext under a fresh message id is dropped', () async {
    final genuine = await alice.packet(messageId: 'm-1', plaintext: 'once');
    deliver(genuine);
    await settle();
    expect(messages, hasLength(1));

    final before = transport.sentPayloads.length;
    deliver(genuine.copyWith(messageId: 'm-1-replayed'));
    await settle();

    expect(messages, hasLength(1), reason: 'the replay is not a new message');
    expect(receiptsSentSince(before), isEmpty);
    expect(
      keyChanges,
      isEmpty,
      reason: 'the key was right; the header was not',
    );
  });

  test('a re-addressed ciphertext is dropped', () async {
    // Alice sealed this for the local node; a relay rewrites the type.
    final genuine = await alice.packet(messageId: 'm-1', plaintext: 'chat');
    deliver(genuine.copyWith(packetType: 'image'));
    await settle();

    expect(messages, isEmpty);
  });

  test(
    'a legacy version-1 packet from the pinned key still decrypts',
    () async {
      deliver(
        await alice.packet(
          messageId: 'legacy-1',
          plaintext: 'old build',
          version: CryptoService.kLegacyEncryptionVersion,
        ),
      );
      await settle();

      expect(messages.map((m) => m.content), ['old build']);
    },
  );

  test('a legacy packet is held to the pinned key too', () async {
    deliver(
      await mallory.packet(
        messageId: 'legacy-forged',
        plaintext: 'pwned',
        version: CryptoService.kLegacyEncryptionVersion,
      ),
    );
    await settle();

    expect(messages, isEmpty);
    expect(keyChanges, hasLength(1));
  });

  test('a packet from a node with no pinned key pins on first use', () async {
    final carol = await _Peer.create('Carol', identity);
    deliver(await carol.packet(messageId: 'c-1', plaintext: 'new here'));
    await settle();

    expect(messages.map((m) => m.content), ['new here']);
    expect(localCrypto.pinnedKeyBase64(carol.nodeId), carol.publicKey);
    expect(keyChanges, isEmpty);
  });

  group('rider control', () {
    late List<RiderModeEvent> riderEvents;

    setUp(() async {
      riderEvents = [];
      subs.add(mesh.riderEvents.listen(riderEvents.add));
      // Alice's key_announce already created her contact; upsert keeps the
      // existing trust flag on purpose, so trust is granted explicitly.
      await contacts.trust(alice.nodeId);
      expect(
        contacts.contacts.firstWhere((c) => c.nodeId == alice.nodeId),
        isA<KnownContact>().having((c) => c.isTrusted, 'isTrusted', isTrue),
      );
    });

    test('a keepalive sealed with the trusted key is accepted', () async {
      deliver(
        await alice.packet(
          messageId: 'rk-1',
          plaintext: const RiderKeepalivePayload(sessionId: 's1').toWire(),
          packetType: 'rider_control',
        ),
      );
      await settle();

      expect(riderEvents, hasLength(1));
      expect(riderEvents.single, isA<RiderKeepaliveEvent>());
    });

    test(
      'one sealed with another key under the trusted id is ignored',
      () async {
        deliver(
          await mallory.packet(
            messageId: 'rk-forged',
            plaintext: const RiderKeepalivePayload(sessionId: 's1').toWire(),
            packetType: 'rider_control',
          ),
        );
        await settle();

        expect(riderEvents, isEmpty);
        expect(keyChanges, hasLength(1));
      },
    );
  });
}
