import 'package:airgrid/core/constants.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/transport/packet_fragmenter.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/crypto_identity.dart';
import '../helpers/mesh_harness.dart';
import '../helpers/packet_decoder.dart';

void main() {
  // ── Group 1: Multi-node topology ──────────────────────────────────────────

  group('multi-node topology', () {
    late FakeMeshHarness harness;

    setUp(() => harness = FakeMeshHarness());
    tearDown(() => harness.dispose());

    // ── Test 1 ──────────────────────────────────────────────────────────────
    test('3-node line: public broadcast reaches C', () async {
      final identA = await CryptoTestIdentity.generate('Alice');
      final identB = await CryptoTestIdentity.generate('Bob');
      final identC = await CryptoTestIdentity.generate('Carol');

      final nodeA = await harness.addNode(identA);
      await harness.addNode(identB);
      final nodeC = await harness.addNode(identC);

      await harness.connect(identA.nodeId, identB.nodeId);
      await harness.connect(identB.nodeId, identC.nodeId);

      final receivedByC = <dynamic>[];
      final sub = nodeC.service.messageStream.listen(receivedByC.add);

      await nodeA.service.sendMessage('Hello mesh');
      await harness.settle();

      expect(receivedByC, hasLength(1));
      expect(receivedByC.first.content, 'Hello mesh');
      expect(receivedByC.first.senderName, 'Alice');
      // C received proves B relayed (sentPayloads is cleared by settle).

      await sub.cancel();
    });

    // ── Test 2 ──────────────────────────────────────────────────────────────
    test('3-node line: encrypted private relayed to C via B', () async {
      final identA = await CryptoTestIdentity.generate('Alice');
      final identB = await CryptoTestIdentity.generate('Bob');
      final identC = await CryptoTestIdentity.generate('Carol');

      final nodeA = await harness.addNode(identA);
      final nodeB = await harness.addNode(identB);
      final nodeC = await harness.addNode(identC);

      await harness.connect(identA.nodeId, identB.nodeId);
      await harness.connect(identB.nodeId, identC.nodeId);
      // After both connects A has C's key via relayed key_announce.

      final receivedByB = <dynamic>[];
      final receivedByC = <dynamic>[];
      final subB = nodeB.service.messageStream.listen(receivedByB.add);
      final subC = nodeC.service.messageStream.listen(receivedByC.add);

      final contactC = nodeA.service.knownContacts.firstWhere(
        (c) => c.nodeId == identC.nodeId,
      );

      final result = await nodeA.service.sendPrivateMessageToContact(
        contactC,
        'secret',
      );
      expect(result, PrivateSendResult.sentEncrypted);

      await harness.settle();

      // C decrypts and displays the message.
      expect(receivedByC.where((m) => m.content == 'secret'), hasLength(1));
      // B is a relay: B cannot decrypt, so B emits nothing.
      // C receiving proves B forwarded the encrypted packet.
      expect(receivedByB.where((m) => m.content == 'secret'), isEmpty);

      await subB.cancel();
      await subC.cancel();
    });

    // ── Test 3 ──────────────────────────────────────────────────────────────
    test('3-node line: delivery receipt returns to A via B', () async {
      final identA = await CryptoTestIdentity.generate('Alice');
      final identB = await CryptoTestIdentity.generate('Bob');
      final identC = await CryptoTestIdentity.generate('Carol');

      final nodeA = await harness.addNode(identA);
      await harness.addNode(identB);
      await harness.addNode(identC);

      await harness.connect(identA.nodeId, identB.nodeId);
      await harness.connect(identB.nodeId, identC.nodeId);

      final statuses = <({String messageId, DeliveryStatus status})>[];
      final statusSub = nodeA.service.statusStream.listen(statuses.add);

      final contactC = nodeA.service.knownContacts.firstWhere(
        (c) => c.nodeId == identC.nodeId,
      );

      final result = await nodeA.service.sendPrivateMessageToContact(
        contactC,
        'hello',
      );
      expect(result, PrivateSendResult.sentEncrypted);
      await harness.settle();

      // A should have received a 'delivered' status update.
      // (The receipt from C is encrypted with A's key — _sendDeliveryReceipt
      // caches the senderPublicKey from the original packet automatically.)
      expect(
        statuses.where((s) => s.status == DeliveryStatus.delivered),
        hasLength(1),
      );

      await statusSub.cancel();
    });

    // ── Test 4 ──────────────────────────────────────────────────────────────
    test(
      '4-node crowd relay: D receives encrypted private exactly once',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');
        final identD = await CryptoTestIdentity.generate('Dave');

        final nodeA = await harness.addNode(identA);
        await harness.addNode(identB);
        await harness.addNode(identC);
        final nodeD = await harness.addNode(identD);

        // A→{B, C}→D: A broadcasts through two independent relay paths.
        await harness.connect(identA.nodeId, identB.nodeId);
        await harness.connect(identA.nodeId, identC.nodeId);
        await harness.connect(identB.nodeId, identD.nodeId);
        await harness.connect(identC.nodeId, identD.nodeId);

        final receivedByD = <dynamic>[];
        final subD = nodeD.service.messageStream.listen(receivedByD.add);

        // A has D as a known contact (key arrived via B then C relay).
        final contactD = nodeA.service.knownContacts.firstWhere(
          (c) => c.nodeId == identD.nodeId,
        );

        final result = await nodeA.service.sendPrivateMessageToContact(
          contactD,
          'crowd',
        );
        expect(result, PrivateSendResult.sentEncrypted);
        await harness.settle();

        // Despite arriving via two paths, D should emit exactly one message.
        expect(receivedByD.where((m) => m.content == 'crowd'), hasLength(1));

        await subD.cancel();
      },
    );

    // ── Test 5 ──────────────────────────────────────────────────────────────
    test('large fragmented encrypted relay: C reassembles via B', () async {
      final identA = await CryptoTestIdentity.generate('Alice');
      final identB = await CryptoTestIdentity.generate('Bob');
      final identC = await CryptoTestIdentity.generate('Carol');

      final nodeA = await harness.addNode(identA);
      await harness.addNode(identB);
      final nodeC = await harness.addNode(identC);

      await harness.connect(identA.nodeId, identB.nodeId);
      await harness.connect(identB.nodeId, identC.nodeId);

      final receivedByC = <dynamic>[];
      final subC = nodeC.service.messageStream.listen(receivedByC.add);

      // 4000-character plaintext ensures the encrypted + encoded packet
      // exceeds kFragmentThreshold (4096 bytes) and is split into fragments.
      final bigContent = 'X' * 4000;
      final contactC = nodeA.service.knownContacts.firstWhere(
        (c) => c.nodeId == identC.nodeId,
      );
      await nodeA.service.sendPrivateMessageToContact(contactC, bigContent);
      await harness.settle();

      // C reassembles and decrypts to produce exactly one message.
      // (C receiving proves B forwarded the fragments; sentPayloads is
      //  cleared by settle so we cannot inspect B's outbox post-settle.)
      expect(receivedByC, hasLength(1));
      expect(receivedByC.first.content, bigContent);

      await subC.cancel();
    });
  });

  // ── Group 2: Routing rule stress tests ────────────────────────────────────

  group('routing rules', () {
    late FakeMeshHarness harness;

    setUp(() => harness = FakeMeshHarness());
    tearDown(() => harness.dispose());

    // ── Test 6 ──────────────────────────────────────────────────────────────
    test('hopLimit=1: delivered but not forwarded', () async {
      final identA = await CryptoTestIdentity.generate('Alice');
      final identB = await CryptoTestIdentity.generate('Bob');
      final identC = await CryptoTestIdentity.generate('Carol');

      await harness.addNode(identA);
      final nodeB = await harness.addNode(identB);
      final nodeC = await harness.addNode(identC);

      await harness.connect(identA.nodeId, identB.nodeId);
      await harness.connect(identB.nodeId, identC.nodeId);

      final receivedByB = <dynamic>[];
      final receivedByC = <dynamic>[];
      final subB = nodeB.service.messageStream.listen(receivedByB.add);
      final subC = nodeC.service.messageStream.listen(receivedByC.add);

      // Inject a packet with hopLimit=1 directly at B.
      final dying = AirGridPacket(
        messageId: 'dying-001',
        senderNodeId: identA.nodeId,
        senderName: 'Alice',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: 'last-hop',
        seenByNodes: [identA.nodeId],
        hopLimit: 1,
      );
      nodeB.transport.receiveBytes(
        harness.epId(identB.nodeId, identA.nodeId),
        TransportCodec.encode(dying),
      );
      await harness.settle();

      // B displays the message.
      expect(receivedByB.where((m) => m.content == 'last-hop'), hasLength(1));
      // B must NOT forward (hop limit drops to 0 → RelayController returns
      // shouldRelay=false for newHopLimit=0).
      expect(
        packetsSentTo(
          nodeB.transport,
          harness.epId(identB.nodeId, identC.nodeId),
        ),
        isEmpty,
      );
      // C never receives it.
      expect(receivedByC, isEmpty);

      await subB.cancel();
      await subC.cancel();
    });

    // ── Test 7 ──────────────────────────────────────────────────────────────
    test('hopLimit=0: packet dropped at receive gate', () async {
      final identA = await CryptoTestIdentity.generate('Alice');
      final identB = await CryptoTestIdentity.generate('Bob');

      await harness.addNode(identA);
      final nodeB = await harness.addNode(identB);

      await harness.connect(identA.nodeId, identB.nodeId);

      final receivedByB = <dynamic>[];
      final subB = nodeB.service.messageStream.listen(receivedByB.add);

      final dead = AirGridPacket(
        messageId: 'dead-001',
        senderNodeId: identA.nodeId,
        senderName: 'Alice',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: 'dropped',
        seenByNodes: [identA.nodeId],
        hopLimit: 0,
      );
      nodeB.transport.receiveBytes(
        harness.epId(identB.nodeId, identA.nodeId),
        TransportCodec.encode(dead),
      );
      await harness.settle();

      expect(receivedByB, isEmpty);
      expect(nodeB.transport.sentPayloads, isEmpty);

      await subB.cancel();
    });

    // ── Test 8 ──────────────────────────────────────────────────────────────
    test('duplicate suppression: same public packet delivered twice', () async {
      final identA = await CryptoTestIdentity.generate('Alice');
      final identB = await CryptoTestIdentity.generate('Bob');
      final identC = await CryptoTestIdentity.generate('Carol');

      await harness.addNode(identA);
      final nodeB = await harness.addNode(identB);
      await harness.addNode(identC);

      await harness.connect(identA.nodeId, identB.nodeId);
      await harness.connect(identB.nodeId, identC.nodeId);

      final receivedByB = <dynamic>[];
      final subB = nodeB.service.messageStream.listen(receivedByB.add);

      final bytes = TransportCodec.encode(
        AirGridPacket(
          messageId: 'dup-001',
          senderNodeId: identA.nodeId,
          senderName: 'Alice',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          content: 'duplicate',
          seenByNodes: [identA.nodeId],
          hopLimit: 6,
        ),
      );
      final fromEp = harness.epId(identB.nodeId, identA.nodeId);
      // Deliver same packet twice to B.
      nodeB.transport.receiveBytes(fromEp, bytes);
      nodeB.transport.receiveBytes(fromEp, bytes);
      await harness.settle();

      // B emits and relays exactly once.
      expect(receivedByB, hasLength(1));
      final relayed = packetsSentTo(
        nodeB.transport,
        harness.epId(identB.nodeId, identC.nodeId),
      );
      expect(relayed.where((p) => p.messageId == 'dup-001'), hasLength(1));

      await subB.cancel();
    });

    // ── Test 9 ──────────────────────────────────────────────────────────────
    test(
      'fragment chunk dedup: same chunk twice → single reassembly',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        await harness.addNode(identA);
        await harness.addNode(identB);
        final nodeC = await harness.addNode(identC);

        await harness.connect(identA.nodeId, identB.nodeId);
        await harness.connect(identB.nodeId, identC.nodeId);

        final receivedByC = <dynamic>[];
        final subC = nodeC.service.messageStream.listen(receivedByC.add);

        // Build a small 2-fragment public packet to test dedup.
        final original = AirGridPacket(
          messageId: 'orig-001',
          senderNodeId: identA.nodeId,
          senderName: 'Alice',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          content: 'A' * 500,
          seenByNodes: [identA.nodeId],
          hopLimit: 6,
        );
        // Fragment with a very small threshold to force splitting.
        final frags = PacketFragmenter.fragment(original, threshold: 200);
        expect(frags.length, greaterThan(1));

        final frag0Bytes = TransportCodec.encode(frags[0]);
        final fromEp = harness.epId(identC.nodeId, identB.nodeId);

        // Deliver chunk 0 twice (dedup test), then all remaining chunks once.
        nodeC.transport.receiveBytes(fromEp, frag0Bytes);
        nodeC.transport.receiveBytes(fromEp, frag0Bytes); // duplicate chunk 0
        for (int i = 1; i < frags.length; i++) {
          nodeC.transport.receiveBytes(fromEp, TransportCodec.encode(frags[i]));
        }
        await harness.settle();

        // C should assemble and emit exactly one message.
        expect(receivedByC, hasLength(1));
        expect(receivedByC.first.content, 'A' * 500);

        await subC.cancel();
      },
    );

    // ── Test 10 ─────────────────────────────────────────────────────────────
    // Receipt dedup happens at relay nodes (_relayedReceiptCache), not at the
    // recipient.  Verify that a relay node forwards the same receipt only once.
    test(
      'receipt relay dedup: relay node forwards same receipt only once',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        await harness.addNode(identA);
        final nodeB = await harness.addNode(identB);
        await harness.addNode(identC);

        await harness.connect(identA.nodeId, identB.nodeId);
        await harness.connect(identB.nodeId, identC.nodeId);

        // Build an encrypted delivery_receipt from C addressed to A.
        // encryptionVersion=1 is required so the relay (B) forwards it;
        // plaintext private packets for a non-local recipient are dropped.
        // The content doesn't need to be a real ciphertext for the relay test.
        final receiptBytes = TransportCodec.encode(
          AirGridPacket(
            messageId: 'rcpt-relay-001',
            senderNodeId: identC.nodeId,
            senderName: 'Carol',
            timestamp: DateTime.now().millisecondsSinceEpoch,
            content: 'fake-encrypted-receipt',
            seenByNodes: [identC.nodeId],
            hopLimit: 8,
            packetType: 'delivery_receipt',
            senderPublicKey: identC.publicKeyBase64,
            encryptionVersion: 1,
            conversationType: 'private',
            recipientNodeId: identA.nodeId,
          ),
        );

        // Deliver the same receipt twice to B (as if arriving from C).
        final fromEpAtB = harness.epId(identB.nodeId, identC.nodeId);
        nodeB.transport.receiveBytes(fromEpAtB, receiptBytes);
        nodeB.transport.receiveBytes(fromEpAtB, receiptBytes); // duplicate
        await harness.settle();

        // B should have forwarded to A exactly once (_relayedReceiptCache dedup).
        final sentToA = packetsSentTo(
          nodeB.transport,
          harness.epId(identB.nodeId, identA.nodeId),
        ).where((p) => p.packetType == 'delivery_receipt');
        expect(sentToA, hasLength(1));
      },
    );

    // ── Test 11 ─────────────────────────────────────────────────────────────
    test(
      'key_announce dedup: same announce relayed once, contact upserted once',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        await harness.addNode(identA);
        final nodeB = await harness.addNode(identB);
        await harness.addNode(identC);

        // Use connectSilent so no automatic key_announce occurs.
        await harness.connectSilent(identA.nodeId, identB.nodeId);
        await harness.connectSilent(identB.nodeId, identC.nodeId);

        final kaBytes = TransportCodec.encode(
          AirGridPacket(
            messageId: 'ka-001',
            senderNodeId: identC.nodeId,
            senderName: 'Carol',
            timestamp: DateTime.now().millisecondsSinceEpoch,
            content: '',
            seenByNodes: [identC.nodeId],
            hopLimit: 7,
            packetType: 'key_announce',
            senderPublicKey: identC.publicKeyBase64,
          ),
        );

        final fromEpAtB = harness.epId(identB.nodeId, identC.nodeId);
        // Deliver the same key_announce twice to B.
        nodeB.transport.receiveBytes(fromEpAtB, kaBytes);
        nodeB.transport.receiveBytes(fromEpAtB, kaBytes);
        await harness.settle();

        // B should relay to A exactly once (second is dedup'd).
        final relayedToA = packetsSentTo(
          nodeB.transport,
          harness.epId(identB.nodeId, identA.nodeId),
        );
        expect(
          relayedToA.where((p) => p.packetType == 'key_announce'),
          hasLength(1),
        );

        // B's known contacts should contain C exactly once.
        expect(
          nodeB.store.contacts.where((c) => c.nodeId == identC.nodeId),
          hasLength(1),
        );
      },
    );

    // ── Test 12 ─────────────────────────────────────────────────────────────
    test(
      'private packet dedup: same encrypted packet processed once',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');

        final nodeA = await harness.addNode(identA);
        final nodeB = await harness.addNode(identB);

        await harness.connect(identA.nodeId, identB.nodeId);

        // Build an encrypted private packet addressed to B from A.
        final cipher = await nodeA.crypto.encryptContent('hi', identB.nodeId);
        expect(cipher, isNotNull);

        final pktBytes = TransportCodec.encode(
          AirGridPacket(
            messageId: 'priv-001',
            senderNodeId: identA.nodeId,
            senderName: 'Alice',
            timestamp: DateTime.now().millisecondsSinceEpoch,
            content: cipher!,
            seenByNodes: [identA.nodeId],
            hopLimit: 8,
            senderPublicKey: identA.publicKeyBase64,
            encryptionVersion: 1,
            conversationType: 'private',
            recipientNodeId: identB.nodeId,
          ),
        );

        final receivedByB = <dynamic>[];
        final subB = nodeB.service.messageStream.listen(receivedByB.add);

        final fromEp = harness.epId(identB.nodeId, identA.nodeId);
        nodeB.transport.receiveBytes(fromEp, pktBytes);
        nodeB.transport.receiveBytes(fromEp, pktBytes); // duplicate
        await harness.settle();

        // B decrypts and emits exactly once.
        expect(receivedByB.where((m) => m.content == 'hi'), hasLength(1));
        // B sends exactly one delivery_receipt.
        final receipts = decodeSentPackets(
          nodeB.transport,
        ).where((p) => p.packetType == 'delivery_receipt').toList();
        expect(receipts, hasLength(1));

        await subB.cancel();
      },
    );

    // ── Test 13 ─────────────────────────────────────────────────────────────
    test(
      'source endpoint exclusion: relay does not echo back to sender',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        final nodeA = await harness.addNode(identA);
        final nodeB = await harness.addNode(identB);
        await harness.addNode(identC);

        await harness.connect(identA.nodeId, identB.nodeId);
        await harness.connect(identB.nodeId, identC.nodeId);

        await nodeA.service.sendMessage('echo-test');
        await harness.settle();

        // B must NOT send back to A's endpoint.
        final sentBackToA = packetsSentTo(
          nodeB.transport,
          harness.epId(identB.nodeId, identA.nodeId),
        );
        expect(sentBackToA.where((p) => p.packetType == 'chat'), isEmpty);
      },
    );

    // ── Test 14 ─────────────────────────────────────────────────────────────
    test(
      'relayed key_announce: A learns C with no endpoint (not directly connected)',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        final nodeA = await harness.addNode(identA);
        await harness.addNode(identB);
        await harness.addNode(identC);

        // A–B connected; B–C connected. C's key_announce reaches A via B relay.
        await harness.connect(identA.nodeId, identB.nodeId);
        await harness.connect(identB.nodeId, identC.nodeId);
        // The second connect triggers C's key_announce which B relays to A.

        final contactsA = nodeA.service.knownContacts;
        final cContact = contactsA.where((c) => c.nodeId == identC.nodeId);
        expect(cContact, hasLength(1));
        // Relayed key_announce: A has no direct endpoint for C.
        expect(cContact.first.lastEndpointId, isNull);
      },
    );

    // ── Test 15 ─────────────────────────────────────────────────────────────
    test(
      'plaintext private for wrong recipient: dropped at relay node',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        await harness.addNode(identA);
        final nodeB = await harness.addNode(identB);
        final nodeC = await harness.addNode(identC);

        await harness.connect(identA.nodeId, identB.nodeId);
        await harness.connect(identB.nodeId, identC.nodeId);

        // Build a plaintext private packet addressed to C; inject at B from A.
        final plaintextPrivate = AirGridPacket(
          messageId: 'pt-priv-001',
          senderNodeId: identA.nodeId,
          senderName: 'Alice',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          content: 'secret-plaintext',
          seenByNodes: [identA.nodeId],
          hopLimit: 8,
          conversationType: 'private',
          recipientNodeId: identC.nodeId,
          // encryptionVersion intentionally null → plaintext private
        );

        final receivedByC = <dynamic>[];
        final subC = nodeC.service.messageStream.listen(receivedByC.add);

        nodeB.transport.receiveBytes(
          harness.epId(identB.nodeId, identA.nodeId),
          TransportCodec.encode(plaintextPrivate),
        );
        await harness.settle();

        // B drops it (plaintext private for wrong recipient is never relayed).
        expect(
          packetsSentTo(
            nodeB.transport,
            harness.epId(identB.nodeId, identC.nodeId),
          ),
          isEmpty,
        );
        expect(receivedByC, isEmpty);

        await subC.cancel();
      },
    );
  });

  // ── Group 3: Encrypted relay semantics ────────────────────────────────────

  group('encrypted relay semantics', () {
    late FakeMeshHarness harness;

    setUp(() => harness = FakeMeshHarness());
    tearDown(() => harness.dispose());

    // ── Test 16 ─────────────────────────────────────────────────────────────
    test(
      'intermediate node forwards encrypted private without decrypting',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        final nodeA = await harness.addNode(identA);
        final nodeB = await harness.addNode(identB);
        final nodeC = await harness.addNode(identC);

        await harness.connect(identA.nodeId, identB.nodeId);
        await harness.connect(identB.nodeId, identC.nodeId);

        // B is an intermediate relay: it cannot decrypt C's messages.
        final receivedByB = <dynamic>[];
        final receivedByC = <dynamic>[];
        final subB = nodeB.service.messageStream.listen(receivedByB.add);
        final subC = nodeC.service.messageStream.listen(receivedByC.add);

        final contactC = nodeA.service.knownContacts.firstWhere(
          (c) => c.nodeId == identC.nodeId,
        );
        await nodeA.service.sendPrivateMessageToContact(contactC, 'private');
        await harness.settle();

        // B must not emit the message (it cannot decrypt it).
        expect(receivedByB, isEmpty);
        // C must receive the message, proving B forwarded it without decrypting.
        expect(receivedByC.where((m) => m.content == 'private'), hasLength(1));

        await subB.cancel();
        await subC.cancel();
      },
    );

    // ── Test 17 ─────────────────────────────────────────────────────────────
    test(
      'seenByNodes loop prevention: triangle settles without infinite relay',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        final nodeA = await harness.addNode(identA);
        final nodeB = await harness.addNode(identB);
        final nodeC = await harness.addNode(identC);

        // Triangle: A–B, B–C, A–C (each pair directly connected).
        await harness.connect(identA.nodeId, identB.nodeId);
        await harness.connect(identB.nodeId, identC.nodeId);
        await harness.connect(identA.nodeId, identC.nodeId);

        final receivedByA = <dynamic>[];
        final receivedByB = <dynamic>[];
        final receivedByC = <dynamic>[];
        final subA = nodeA.service.messageStream.listen(receivedByA.add);
        final subB = nodeB.service.messageStream.listen(receivedByB.add);
        final subC = nodeC.service.messageStream.listen(receivedByC.add);

        await nodeA.service.sendMessage('triangle');
        // settle() terminates naturally (maxRounds not exhausted).
        await harness.settle();

        // A emits locally; B and C each receive once via direct delivery from A
        // (the relayed copies from B→C and C→B are dedup'd by the message cache).
        expect(receivedByA.where((m) => m.content == 'triangle'), hasLength(1));
        expect(receivedByB.where((m) => m.content == 'triangle'), hasLength(1));
        expect(receivedByC.where((m) => m.content == 'triangle'), hasLength(1));

        await subA.cancel();
        await subB.cancel();
        await subC.cancel();
      },
    );

    // ── Test 18 ─────────────────────────────────────────────────────────────
    test(
      'seenByNodes accumulation: relay adds own nodeId before forwarding',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        final nodeA = await harness.addNode(identA);
        final nodeB = await harness.addNode(identB);
        await harness.addNode(identC);

        await harness.connect(identA.nodeId, identB.nodeId);
        await harness.connect(identB.nodeId, identC.nodeId);

        await nodeA.service.sendMessage('accumulate');

        // Snapshot B's outbound packets (to C) BEFORE settle clears them.
        // We capture after A's packet reaches B (round 1 of routing).
        // Drive round 1 manually: move A's payload → B, pause.
        final aPending = List.of(nodeA.transport.sentPayloads);
        nodeA.transport.sentPayloads.clear();
        for (final sent in aPending) {
          // A's only peer is B; deliver each packet as arriving from A's endpoint.
          nodeB.transport.receiveBytes(
            harness.epId(identB.nodeId, identA.nodeId),
            sent.bytes,
          );
        }
        await Future<void>.delayed(
          Duration.zero,
        ); // B processes → generates relay

        // Decode what B is about to relay to C.
        final relayedToC = packetsSentTo(
          nodeB.transport,
          harness.epId(identB.nodeId, identC.nodeId),
        );
        expect(relayedToC, isNotEmpty);
        final relayed = relayedToC.first;
        expect(relayed.seenByNodes, contains(identA.nodeId));
        expect(relayed.seenByNodes, contains(identB.nodeId));

        await harness.settle(); // clean up remaining packets
      },
    );
  });

  // ── Group 4: Store-and-forward ────────────────────────────────────────────

  group('store-and-forward', () {
    late FakeMeshHarness harness;

    setUp(() => harness = FakeMeshHarness());
    tearDown(() => harness.dispose());

    // ── Test 19 ─────────────────────────────────────────────────────────────
    test(
      'spool flush on direct connect: spooled message delivered when C connects',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identC = await CryptoTestIdentity.generate('Carol');

        final nodeA = await harness.addNode(identA);
        // C is not yet connected; A pre-loads C's key so it can encrypt.
        nodeA.crypto.cacheKey(identC.nodeId, identC.publicKeyBase64);

        final contactC = KnownContact(
          nodeId: identC.nodeId,
          displayName: identC.displayName,
          publicKeyBase64: identC.publicKeyBase64,
          lastSeenAt: DateTime.now(),
        );
        await nodeA.store.upsert(contactC);

        // Spool: A sends to C but C is offline (no connected peers).
        final result = await nodeA.service.sendPrivateMessageToContact(
          contactC,
          'spooled',
        );
        expect(result, PrivateSendResult.sentEncrypted);
        // No peers → nothing sent yet.
        expect(nodeA.transport.sentPayloads, isEmpty);

        // C comes online (direct connection to A).
        final nodeC = await harness.addNode(identC);
        final receivedByC = <dynamic>[];
        final subC = nodeC.service.messageStream.listen(receivedByC.add);

        await harness.connect(identA.nodeId, identC.nodeId);

        // After key_announce exchange A calls _markDirectPeerReady which
        // flushes the spool.
        expect(receivedByC.where((m) => m.content == 'spooled'), hasLength(1));

        await subC.cancel();
      },
    );

    // ── Test 20 ─────────────────────────────────────────────────────────────
    test(
      'relayed key_announce updates contact but does NOT flush spool (Phase 10)',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        final nodeA = await harness.addNode(identA);
        await harness.addNode(identB);
        final nodeC = await harness.addNode(identC);

        // Step 1: spool a message for C while A has NO connected peers.
        final contactC = KnownContact(
          nodeId: identC.nodeId,
          displayName: identC.displayName,
          publicKeyBase64: identC.publicKeyBase64,
          lastSeenAt: DateTime.now(),
        );
        await nodeA.store.upsert(contactC);
        nodeA.crypto.cacheKey(identC.nodeId, identC.publicKeyBase64);
        final spoolResult = await nodeA.service.sendPrivateMessageToContact(
          contactC,
          'spooled-relay',
        );
        expect(spoolResult, PrivateSendResult.sentEncrypted);
        // Confirmed: nothing was sent to the wire (A had no peers → spooled).
        expect(nodeA.transport.sentPayloads, isEmpty);

        // Step 2: A connects to B (spool flush fires only for B's nodeId,
        // not for C → nothing is flushed).
        await harness.connect(identA.nodeId, identB.nodeId);

        // Step 3: wire B–C without key exchange.
        await harness.connectSilent(identB.nodeId, identC.nodeId);

        final receivedByC = <dynamic>[];
        final subC = nodeC.service.messageStream.listen(receivedByC.add);

        // Step 4: C sends a key_announce which relays via B to A (not direct).
        await nodeC.service.sendKeyAnnounce();
        await harness.settle();

        // A should now know C (contact updated via relayed key_announce).
        expect(
          nodeA.service.knownContacts.where((c) => c.nodeId == identC.nodeId),
          isNotEmpty,
        );
        // C must NOT have received the spooled message: a relayed key_announce
        // (isDirect=false) does not trigger _markDirectPeerReady / _flushSpool.
        // Only a DIRECT key_announce flushes the spool (Phase 8 behaviour).
        expect(receivedByC, isEmpty);

        await subC.cancel();
      },
    );

    // ── Test 21 ─────────────────────────────────────────────────────────────
    test('spool TTL expiry: expired entries not delivered', () async {
      final identA = await CryptoTestIdentity.generate('Alice');
      final identC = await CryptoTestIdentity.generate('Carol');

      // Inject a mutable clock: start in the past so entries appear expired.
      final spoolAge = Duration(seconds: AirGridConstants.kSpoolTtlSeconds + 1);
      var fakeNow = DateTime.now().subtract(spoolAge);
      DateTime clock() => fakeNow;

      final nodeA = await harness.addNode(identA, spoolClock: clock);
      nodeA.crypto.cacheKey(identC.nodeId, identC.publicKeyBase64);

      final contactC = KnownContact(
        nodeId: identC.nodeId,
        displayName: identC.displayName,
        publicKeyBase64: identC.publicKeyBase64,
        lastSeenAt: DateTime.now(),
      );
      await nodeA.store.upsert(contactC);

      // Spool with clock in the past → entry is already expired by the time
      // we advance the clock.
      final result = await nodeA.service.sendPrivateMessageToContact(
        contactC,
        'will-expire',
      );
      expect(result, PrivateSendResult.sentEncrypted);

      // Advance clock to the present.
      fakeNow = DateTime.now();

      // C connects; _markDirectPeerReady triggers _flushSpool.
      final nodeC = await harness.addNode(identC);
      final receivedByC = <dynamic>[];
      final subC = nodeC.service.messageStream.listen(receivedByC.add);

      await harness.connect(identA.nodeId, identC.nodeId);

      // Expired entry should be pruned; C receives nothing.
      expect(receivedByC, isEmpty);

      await subC.cancel();
    });

    // ── Test 22 ─────────────────────────────────────────────────────────────
    test(
      'spool capacity: entries dropped once full; at most kSpoolMaxEntries delivered',
      () async {
        final identA = await CryptoTestIdentity.generate('Alice');
        final identC = await CryptoTestIdentity.generate('Carol');

        final nodeA = await harness.addNode(identA);
        nodeA.crypto.cacheKey(identC.nodeId, identC.publicKeyBase64);

        final contactC = KnownContact(
          nodeId: identC.nodeId,
          displayName: identC.displayName,
          publicKeyBase64: identC.publicKeyBase64,
          lastSeenAt: DateTime.now(),
        );
        await nodeA.store.upsert(contactC);

        // Spool kSpoolMaxEntries + 1 messages; the last one should be dropped.
        for (int i = 0; i < AirGridConstants.kSpoolMaxEntries + 1; i++) {
          await nodeA.service.sendPrivateMessageToContact(contactC, 'msg-$i');
          await Future<void>.delayed(Duration.zero);
        }

        final nodeC = await harness.addNode(identC);
        final receivedByC = <dynamic>[];
        final subC = nodeC.service.messageStream.listen(receivedByC.add);

        await harness.connect(identA.nodeId, identC.nodeId);

        expect(
          receivedByC.length,
          lessThanOrEqualTo(AirGridConstants.kSpoolMaxEntries),
        );

        await subC.cancel();
      },
    );
  });

  // ── Group 5: Phase 8 Regressions ─────────────────────────────────────────

  group('phase 8 regressions', () {
    // ── Test 23 ─────────────────────────────────────────────────────────────
    test(
      'known contacts persist across SharedPrefsKnownContactStore restart',
      () async {
        // Isolated from the harness so setMockInitialValues doesn't interfere.
        SharedPreferences.setMockInitialValues({});

        final store1 = await SharedPrefsKnownContactStore.create();
        final identC = await CryptoTestIdentity.generate('Carol');
        final contact = KnownContact(
          nodeId: identC.nodeId,
          displayName: identC.displayName,
          publicKeyBase64: identC.publicKeyBase64,
          lastSeenAt: DateTime.now(),
        );
        await store1.upsert(contact);
        await Future<void>.delayed(Duration.zero); // let _persist() complete
        await store1.dispose();

        // Open a second instance backed by the same SharedPreferences mock.
        final store2 = await SharedPrefsKnownContactStore.create();
        final loaded = store2.contacts.where((c) => c.nodeId == identC.nodeId);
        expect(loaded, hasLength(1));
        expect(loaded.first.displayName, 'Carol');
        await store2.dispose();
      },
    );

    // ── Test 24 ─────────────────────────────────────────────────────────────
    test('offline contact visible in knownContactsStream', () async {
      final harness = FakeMeshHarness();
      final identA = await CryptoTestIdentity.generate('Alice');
      final identC = await CryptoTestIdentity.generate('Carol');

      final nodeA = await harness.addNode(identA);
      // No connection to C — C is only in A's contact store.
      final contact = KnownContact(
        nodeId: identC.nodeId,
        displayName: identC.displayName,
        publicKeyBase64: identC.publicKeyBase64,
        lastSeenAt: DateTime.now(),
      );
      await nodeA.store.upsert(contact);

      expect(
        nodeA.service.knownContacts.where((c) => c.nodeId == identC.nodeId),
        hasLength(1),
      );
      expect(
        nodeA.service.knownContacts
            .firstWhere((c) => c.nodeId == identC.nodeId)
            .isDirectlyConnected,
        isFalse,
      );

      await harness.dispose();
    });

    // ── Test 25a ────────────────────────────────────────────────────────────
    test(
      'offline contact send (relay peers available): broadcasts encrypted packet',
      () async {
        final harness = FakeMeshHarness();
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');
        final identC = await CryptoTestIdentity.generate('Carol');

        final nodeA = await harness.addNode(identA);
        await harness.addNode(identB);
        // C is never added to harness — offline.

        // A knows C's key; C has no endpoint.
        nodeA.crypto.cacheKey(identC.nodeId, identC.publicKeyBase64);
        final contactC = KnownContact(
          nodeId: identC.nodeId,
          displayName: identC.displayName,
          publicKeyBase64: identC.publicKeyBase64,
          lastSeenAt: DateTime.now(),
        );
        await nodeA.store.upsert(contactC);

        await harness.connect(identA.nodeId, identB.nodeId);

        final result = await nodeA.service.sendPrivateMessageToContact(
          contactC,
          'relay-me',
        );
        expect(result, PrivateSendResult.sentEncrypted);

        // A broadcasts to all connected peers (B), since no direct endpoint for C.
        final sentToB = packetsSentTo(
          nodeA.transport,
          harness.epId(identA.nodeId, identB.nodeId),
        );
        expect(sentToB, isNotEmpty);
        // All sent packets are encrypted private for C.
        expect(
          sentToB.every(
            (p) =>
                p.encryptionVersion != null &&
                p.recipientNodeId == identC.nodeId,
          ),
          isTrue,
        );

        await harness.dispose();
      },
    );

    // ── Test 25b ────────────────────────────────────────────────────────────
    test('offline contact send (no peers): spools encrypted packet', () async {
      final harness = FakeMeshHarness();
      final identA = await CryptoTestIdentity.generate('Alice');
      final identC = await CryptoTestIdentity.generate('Carol');

      final nodeA = await harness.addNode(identA);
      nodeA.crypto.cacheKey(identC.nodeId, identC.publicKeyBase64);
      final contactC = KnownContact(
        nodeId: identC.nodeId,
        displayName: identC.displayName,
        publicKeyBase64: identC.publicKeyBase64,
        lastSeenAt: DateTime.now(),
      );
      await nodeA.store.upsert(contactC);
      // No peers connected.

      final result = await nodeA.service.sendPrivateMessageToContact(
        contactC,
        'spooled',
      );
      expect(result, PrivateSendResult.sentEncrypted);
      // Nothing sent to the wire.
      expect(nodeA.transport.sentPayloads, isEmpty);

      // Confirm spool by connecting C and observing delivery.
      final nodeC = await harness.addNode(identC);
      final receivedByC = <dynamic>[];
      final subC = nodeC.service.messageStream.listen(receivedByC.add);
      await harness.connect(identA.nodeId, identC.nodeId);
      expect(receivedByC.where((m) => m.content == 'spooled'), hasLength(1));

      await subC.cancel();
      await harness.dispose();
    });

    // ── Test 26 ─────────────────────────────────────────────────────────────
    test(
      'direct peer: needsPlaintextConfirmation when no key; sentPlaintext with allowFallback',
      () async {
        final harness = FakeMeshHarness();
        final identA = await CryptoTestIdentity.generate('Alice');
        final identB = await CryptoTestIdentity.generate('Bob');

        final nodeA = await harness.addNode(identA);
        await harness.addNode(identB);

        // Connect registering nodeIds but without key exchange.
        // This gives peer.nodeId a value while keeping encryptionReady=false,
        // so sendPrivateMessage returns needsPlaintextConfirmation (not peerUnavailable).
        await harness.connectSilentWithId(identA.nodeId, identB.nodeId);

        final peer = nodeA.service.peers.firstWhere(
          (p) => p.nodeId == identB.nodeId,
        );

        final resultNo = await nodeA.service.sendPrivateMessage(
          peer,
          'hi',
          allowPlaintextFallback: false,
        );
        expect(resultNo, PrivateSendResult.needsPlaintextConfirmation);

        final resultYes = await nodeA.service.sendPrivateMessage(
          peer,
          'hi',
          allowPlaintextFallback: true,
        );
        expect(resultYes, PrivateSendResult.sentPlaintext);

        await harness.dispose();
      },
    );

    // ── Test 27 ─────────────────────────────────────────────────────────────
    test(
      'sendPrivateMessageToContact: peerUnavailable when key missing from crypto',
      () async {
        final harness = FakeMeshHarness();
        final identA = await CryptoTestIdentity.generate('Alice');
        final identC = await CryptoTestIdentity.generate('Carol');

        final nodeA = await harness.addNode(identA);
        // Contact exists in store but key is NOT loaded into crypto service.
        final contactC = KnownContact(
          nodeId: identC.nodeId,
          displayName: identC.displayName,
          publicKeyBase64: identC.publicKeyBase64,
          lastSeenAt: DateTime.now(),
        );
        await nodeA.store.upsert(contactC);

        // sendPrivateMessageToContact re-caches the key from the contact, so
        // to simulate a genuinely missing key we provide an invalid base64 key.
        final badContact = KnownContact(
          nodeId: identC.nodeId,
          displayName: identC.displayName,
          publicKeyBase64: 'not-valid-base64!!!',
          lastSeenAt: DateTime.now(),
        );

        final result = await nodeA.service.sendPrivateMessageToContact(
          badContact,
          'should-fail',
        );
        expect(result, PrivateSendResult.peerUnavailable);

        await harness.dispose();
      },
    );
  });
}
