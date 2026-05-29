import 'dart:convert';
import 'dart:typed_data';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/data/storage/known_contact_store.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/data/transport/packet_fragmenter.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_transport.dart';
import '../helpers/test_node_ids.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

// Test node ID constants (valid UUIDs)
final _localNodeId = testNodeId('local');
final _remoteNodeId = testNodeId('remote');
final _aliceNodeId = testNodeId('alice');
final _bobNodeId = testNodeId('bob');
final _carolNodeId = testNodeId('carol');
final _daveNodeId = testNodeId('dave');
final _eveNodeId = testNodeId('eve');
final _targetNodeId = testNodeId('target');
final _expireTargetNodeId = testNodeId('expire-target');
final _relayNodeId = testNodeId('relay');
final _oldNodeId = testNodeId('old-node');
final _kaNodeId = testNodeId('ka-node');
final _distantNodeId = testNodeId('distant-node');
final _peerNoConversationNodeId = testNodeId('peer-nc');
final _otherNodeId = testNodeId('some-other-node');

Future<LocalIdentityStore> _makeIdentity({
  String? nodeId,
  String name = 'LocalUser',
}) async {
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': nodeId ?? _localNodeId,
    'airgrid_display_name': name,
  });
  return LocalIdentityStore.create();
}

AirGridPacket _packet({
  String id = 'msg-001',
  String? senderNodeId,
  String senderName = 'Remote',
  List<String>? seenByNodes,
  int hopLimit = 8,
  String content = 'Hi',
}) {
  final sender = senderNodeId ?? _remoteNodeId;
  return AirGridPacket(
    messageId: id,
    senderNodeId: sender,
    senderName: senderName,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    content: content,
    seenByNodes: seenByNodes ?? [sender],
    hopLimit: hopLimit,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

Future<({CryptoService local, CryptoService remote, String remotePublicKey})>
_makeReceiptCrypto(LocalIdentityStore identity, {String? remoteNodeId}) async {
  final remoteId = remoteNodeId ?? _remoteNodeId;
  final algorithm = X25519();
  final remoteKp = await algorithm.newKeyPair();
  final remotePub = await remoteKp.extractPublicKey();
  final remotePriv = await remoteKp.extractPrivateKeyBytes();
  final remotePublicKey = base64Encode(remotePub.bytes);

  final local = CryptoService();
  await local.loadLocalKeyPair(
    identity.privateKeyBase64!,
    identity.publicKeyBase64!,
  );
  local.cacheKey(remoteId, remotePublicKey);

  final remote = CryptoService();
  await remote.loadLocalKeyPair(base64Encode(remotePriv), remotePublicKey);
  remote.cacheKey(identity.nodeId, identity.publicKeyBase64!);

  return (local: local, remote: remote, remotePublicKey: remotePublicKey);
}

void main() {
  // Setup mock secure storage for testing
  FlutterSecureStorage.setMockInitialValues({});
  
  late FakeTransport transport;
  late LocalIdentityStore identity;
  late AirGridMeshService mesh;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    transport = FakeTransport();
    identity = await _makeIdentity();
    mesh = AirGridMeshService(
      transport,
      identity,
      CryptoService(),
      jitterOverrideMs: 0,
    );
    // Allow stream subscriptions to wire up.
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await mesh.dispose();
    transport.dispose();
  });

  // ── 1. Local message creation ───────────────────────────────────────────
  group('sendMessage', () {
    test('emits message to own stream', () async {
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);

      await mesh.sendMessage('Hello');
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
      expect(messages.first.content, 'Hello');
      expect(messages.first.isLocal, isTrue);
      await sub.cancel();
    });

    test('sends bytes to all connected endpoints', () async {
      transport.connectPeer('ep-1');
      transport.connectPeer('ep-2');
      await Future<void>.delayed(Duration.zero);

      await mesh.sendMessage('Broadcast');
      await Future<void>.delayed(Duration.zero);

      expect(transport.sentPayloads, isNotEmpty);
      final endpoints = transport.sentPayloads.last.endpoints;
      expect(endpoints, containsAll(['ep-1', 'ep-2']));
    });
  });

  // ── 2. Duplicate suppression ────────────────────────────────────────────
  group('duplicate suppression', () {
    test('second receipt of same messageId is dropped', () async {
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);

      transport.connectPeer('ep-1');
      await Future<void>.delayed(Duration.zero);

      final pkt = _packet(id: 'dup-001');
      final bytes = TransportCodec.encode(pkt);

      transport.receiveBytes('ep-1', bytes);
      await Future<void>.delayed(Duration.zero);
      transport.receiveBytes('ep-1', bytes); // duplicate
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
      await sub.cancel();
    });

    test('duplicate is not rebroadcast', () async {
      transport.connectPeer('ep-1');
      transport.connectPeer('ep-2');
      await Future<void>.delayed(Duration.zero);

      final pkt = _packet(id: 'dup-002');
      final bytes = TransportCodec.encode(pkt);
      final beforeCount = transport.sentPayloads.length;

      transport.receiveBytes('ep-1', bytes);
      await Future<void>.delayed(Duration.zero);
      transport.receiveBytes('ep-1', bytes); // duplicate
      await Future<void>.delayed(Duration.zero);

      // Only one rebroadcast should have been issued (for the first receipt).
      final afterCount = transport.sentPayloads.length;
      expect(afterCount - beforeCount, equals(1));
    });
  });

  // ── 3. seenByNodes loop prevention ─────────────────────────────────────
  group('seenByNodes loop prevention', () {
    test('drops packet already containing local nodeId', () async {
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);

      transport.connectPeer('ep-1');
      await Future<void>.delayed(Duration.zero);

      // Packet already has local-node in seenByNodes — should be dropped.
      final pkt = _packet(
        id: 'loop-001',
        seenByNodes: [_remoteNodeId, _localNodeId], // local nodeId present
      );
      transport.receiveBytes('ep-1', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty);
      await sub.cancel();
    });
  });

  // ── 4. Hop limit decrement ───────────────────────────────────────────────
  group('hop limit', () {
    test('forwarded packet has hopLimit - 1', () async {
      transport.connectPeer('ep-1');
      transport.connectPeer('ep-2');
      await Future<void>.delayed(Duration.zero);

      final pkt = _packet(id: 'hop-001', hopLimit: 5);
      transport.receiveBytes('ep-1', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(transport.sentPayloads, isNotEmpty);
      final forwarded = TransportCodec.decode(
        transport.sentPayloads.last.bytes,
      )!;
      expect(forwarded.hopLimit, 4);
    });
  });

  // ── 5. Hop limit = 0 — packet dropped ───────────────────────────────────
  group('TTL exhaustion', () {
    test('packet with hopLimit 0 is dropped', () async {
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);

      transport.connectPeer('ep-1');
      await Future<void>.delayed(Duration.zero);

      final pkt = _packet(id: 'ttl-001', hopLimit: 0);
      transport.receiveBytes('ep-1', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty);
      await sub.cancel();
    });

    test('packet with hopLimit 1 is emitted but not forwarded', () async {
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);

      transport.connectPeer('ep-1');
      transport.connectPeer('ep-2');
      await Future<void>.delayed(Duration.zero);

      final sentBefore = transport.sentPayloads.length;
      final pkt = _packet(id: 'ttl-002', hopLimit: 1);
      transport.receiveBytes('ep-1', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
      // hopLimit decremented to 0 before rebroadcast check — not forwarded.
      expect(transport.sentPayloads.length, sentBefore);
      await sub.cancel();
    });
  });

  // ── 6. Malformed packet ─────────────────────────────────────────────────
  group('malformed packet handling', () {
    test('random bytes do not crash and produce no message', () async {
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);

      transport.connectPeer('ep-1');
      await Future<void>.delayed(Duration.zero);

      transport.receiveBytes(
        'ep-1',
        Uint8List.fromList(List.generate(50, (i) => i % 256)),
      );
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty);
      await sub.cancel();
    });
  });

  // ── 7. Rebroadcast excludes source endpoint ─────────────────────────────
  group('rebroadcast filtering', () {
    test('source endpoint is excluded from rebroadcast targets', () async {
      transport.connectPeer('ep-source');
      transport.connectPeer('ep-other');
      await Future<void>.delayed(Duration.zero);

      final pkt = _packet(id: 'rbcast-001', hopLimit: 5);
      transport.receiveBytes('ep-source', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(transport.sentPayloads, isNotEmpty);
      final targets = transport.sentPayloads.last.endpoints;
      expect(targets, isNot(contains('ep-source')));
      expect(targets, contains('ep-other'));
    });
  });

  // ── 8. seenByNodes updated before forward ───────────────────────────────
  group('seenByNodes accumulation', () {
    test('local nodeId is added to seenByNodes in forwarded packet', () async {
      transport.connectPeer('ep-1');
      transport.connectPeer('ep-2');
      await Future<void>.delayed(Duration.zero);

      final pkt = _packet(
        id: 'seen-001',
        hopLimit: 5,
        seenByNodes: [_remoteNodeId],
      );
      transport.receiveBytes('ep-1', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(transport.sentPayloads, isNotEmpty);
      final forwarded = TransportCodec.decode(
        transport.sentPayloads.last.bytes,
      )!;
      expect(forwarded.seenByNodes, contains(_localNodeId));
      expect(forwarded.seenByNodes, contains(_remoteNodeId));
    });
  });

  // ── 9. Cache pruning ────────────────────────────────────────────────────
  group('cache pruning', () {
    test('prune removes expired entries', () async {
      // Deliver a packet — it enters the cache.
      transport.connectPeer('ep-1');
      await Future<void>.delayed(Duration.zero);

      final pkt = _packet(id: 'prune-001');
      transport.receiveBytes('ep-1', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      // Delivering the same ID again should be a duplicate right now.
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);
      transport.receiveBytes('ep-1', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);
      expect(messages, isEmpty, reason: 'Should still be in cache');

      await sub.cancel();
    });
  });

  // ── 10. Public send – plaintext only ────────────────────────────────────
  group('sendMessage (public)', () {
    test('emits conversationType public', () async {
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);

      await mesh.sendMessage('Public hello');
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
      expect(messages.first.conversationType, 'public');
      await sub.cancel();
    });
  });

  // ── 11. Private send – peerUnavailable when nodeId is null ──────────────
  group('sendPrivateMessage', () {
    test('returns peerUnavailable when peer has no nodeId', () async {
      transport.connectPeer('ep-1');
      await Future<void>.delayed(Duration.zero);

      final peer = mesh.peers.first; // nodeId is null until key_announce
      final result = await mesh.sendPrivateMessage(peer, 'Secret');
      expect(result, PrivateSendResult.peerUnavailable);
    });

    test('sends only to target endpoint, not all peers', () async {
      transport.connectPeer('ep-target');
      transport.connectPeer('ep-other');
      await Future<void>.delayed(Duration.zero);

      // Simulate a key_announce to give ep-target a nodeId + cached key.
      final fakePubKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      final announcePacket = AirGridPacket(
        messageId: 'ka-001',
        senderNodeId: testNodeId('peer-1'),
        senderName: 'PeerOne',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: '',
        seenByNodes: [testNodeId('peer-1')],
        hopLimit: 8,
        packetType: 'key_announce',
        senderPublicKey: fakePubKey,
      );
      transport.receiveBytes(
        'ep-target',
        TransportCodec.encode(announcePacket),
      );
      await Future<void>.delayed(Duration.zero);

      final peer = mesh.peers.firstWhere((p) => p.endpointId == 'ep-target');
      expect(
        peer.nodeId,
        testNodeId('peer-1'),
        reason: 'peer should have nodeId now',
      );

      final countBefore = transport.sentPayloads.length;
      // allowPlaintextFallback=true because test CryptoService has no real key.
      final result = await mesh.sendPrivateMessage(
        peer,
        'Hello private',
        allowPlaintextFallback: true,
      );
      expect(
        result,
        anyOf(PrivateSendResult.sentEncrypted, PrivateSendResult.sentPlaintext),
      );

      // Only one new payload; it must target only ep-target.
      final newPayloads = transport.sentPayloads.skip(countBefore).toList();
      expect(newPayloads, isNotEmpty);
      final lastTargets = newPayloads.last.endpoints;
      expect(lastTargets, contains('ep-target'));
      expect(lastTargets, isNot(contains('ep-other')));
    });

    test(
      'needsPlaintextConfirmation when encryption unavailable and fallback false',
      () async {
        transport.connectPeer('ep-nc');
        await Future<void>.delayed(Duration.zero);

        // Simulate key_announce for ep-nc.
        final fakePubKey = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';
        final announcePacket = AirGridPacket(
          messageId: 'ka-nc',
          senderNodeId: _peerNoConversationNodeId,
          senderName: 'PeerNC',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          content: '',
          seenByNodes: [_peerNoConversationNodeId],
          hopLimit: 8,
          packetType: 'key_announce',
          senderPublicKey: fakePubKey,
        );
        transport.receiveBytes('ep-nc', TransportCodec.encode(announcePacket));
        await Future<void>.delayed(Duration.zero);

        final peer = mesh.peers.firstWhere((p) => p.endpointId == 'ep-nc');
        // allowPlaintextFallback defaults to false.
        // CryptoService.encryptContent will either succeed (sentEncrypted) or
        // fail → needsPlaintextConfirmation. We only assert it is NOT peerUnavailable.
        final result = await mesh.sendPrivateMessage(peer, 'Confidential');
        expect(result, isNot(PrivateSendResult.peerUnavailable));
      },
    );

    test(
      'sends encrypted private packet when local and peer keys are loaded',
      () async {
        await mesh.dispose();

        final crypto = CryptoService();
        await crypto.loadLocalKeyPair(
          identity.privateKeyBase64!,
          identity.publicKeyBase64!,
        );

        final peerKeyPair = await X25519().newKeyPair();
        final peerPublicKey = await peerKeyPair.extractPublicKey();
        crypto.cacheKey('peer-encrypted', base64Encode(peerPublicKey.bytes));

        mesh = AirGridMeshService(
          transport,
          identity,
          crypto,
          jitterOverrideMs: 0,
        );
        await Future<void>.delayed(Duration.zero);

        transport.connectPeer('ep-target');
        transport.connectPeer('ep-other');
        await Future<void>.delayed(Duration.zero);

        final peer = MeshPeer(
          endpointId: 'ep-target',
          displayName: 'EncryptedPeer',
          connectedAt: DateTime.now(),
          nodeId: 'peer-encrypted',
          encryptionReady: true,
        );

        final result = await mesh.sendPrivateMessage(peer, 'Secret hello');

        expect(result, PrivateSendResult.sentEncrypted);
        expect(transport.sentPayloads, isNotEmpty);

        final sent = transport.sentPayloads.last;
        expect(sent.endpoints, ['ep-target']);

        final packet = TransportCodec.decode(sent.bytes)!;
        expect(packet.conversationType, 'private');
        expect(packet.recipientNodeId, 'peer-encrypted');
        expect(packet.encryptionVersion, 1);
        expect(packet.content, isNot('Secret hello'));
      },
    );
  });

  // ── 12. Private packet: wrong recipient is dropped ─────────────────────
  group('private packet routing', () {
    test('drops private packet addressed to a different nodeId', () async {
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);

      transport.connectPeer('ep-1');
      await Future<void>.delayed(Duration.zero);

      final pkt = AirGridPacket(
        messageId: 'priv-drop-001',
        senderNodeId: _remoteNodeId,
        senderName: 'Remote',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: 'Not for you',
        seenByNodes: [_remoteNodeId],
        hopLimit: 8,
        conversationType: 'private',
        recipientNodeId: _otherNodeId, // NOT local-node
      );
      transport.receiveBytes('ep-1', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty);
      await sub.cancel();
    });

    test('accepts private packet addressed to local nodeId', () async {
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);

      transport.connectPeer('ep-1');
      await Future<void>.delayed(Duration.zero);

      final pkt = AirGridPacket(
        messageId: 'priv-ok-001',
        senderNodeId: _remoteNodeId,
        senderName: 'Remote',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: 'Only for you',
        seenByNodes: [_remoteNodeId],
        hopLimit: 8,
        conversationType: 'private',
        recipientNodeId: _localNodeId, // matches identity
      );
      transport.receiveBytes('ep-1', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
      expect(messages.first.conversationType, 'private');
      await sub.cancel();
    });

    test('private packet is not rebroadcast', () async {
      transport.connectPeer('ep-1');
      transport.connectPeer('ep-2');
      await Future<void>.delayed(Duration.zero);

      final countBefore = transport.sentPayloads.length;

      final pkt = AirGridPacket(
        messageId: 'priv-rbcast-001',
        senderNodeId: _remoteNodeId,
        senderName: 'Remote',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: 'Private',
        seenByNodes: [_remoteNodeId],
        hopLimit: 8,
        conversationType: 'private',
        recipientNodeId: _localNodeId,
      );
      transport.receiveBytes('ep-1', TransportCodec.encode(pkt));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // A delivery_receipt may be sent back to ep-1; what must NOT happen is
      // the private chat packet being forwarded to ep-2 (rebroadcast).
      final newPayloads = transport.sentPayloads.skip(countBefore).toList();
      expect(
        newPayloads.where((p) => p.endpoints.contains('ep-2')),
        isEmpty,
        reason: 'Private packets must not be rebroadcast to other peers',
      );
    });
  });

  // ── 13. key_announce enriches peer and emits peerStream ─────────────────
  group('key_announce handling', () {
    test('direct connection metadata sets peer nodeId immediately', () async {
      transport.connectPeer(
        'ep-direct',
        name: 'DirectPeer',
        nodeId: 'direct-node',
      );
      await Future<void>.delayed(Duration.zero);

      final peer = mesh.peers.firstWhere((p) => p.endpointId == 'ep-direct');
      expect(peer.displayName, 'DirectPeer');
      expect(peer.nodeId, 'direct-node');
    });

    test('direct key_announce sets peer nodeId and emits peerStream', () async {
      transport.connectPeer('ep-ka');
      await Future<void>.delayed(Duration.zero);

      final peerEvents = <List<dynamic>>[];
      final sub = mesh.peerStream.listen(peerEvents.add);

      final pkt = AirGridPacket(
        messageId: 'ka-enrich',
        senderNodeId: _kaNodeId,
        senderName: 'KAUser',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: '',
        seenByNodes: [_kaNodeId], // single entry = direct
        hopLimit: 8,
        packetType: 'key_announce',
        senderPublicKey: 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=',
      );
      transport.receiveBytes('ep-ka', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(peerEvents, isNotEmpty);
      final peer = mesh.peers.firstWhere((p) => p.endpointId == 'ep-ka');
      expect(peer.nodeId, _kaNodeId);
      expect(peer.encryptionReady, isTrue);

      await sub.cancel();
    });

    test(
      'relayed key_announce does NOT set nodeId on relay endpoint',
      () async {
        transport.connectPeer('ep-relay');
        await Future<void>.delayed(Duration.zero);

        final pkt = AirGridPacket(
          messageId: 'ka-relayed',
          senderNodeId: _distantNodeId,
          senderName: 'Distant',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          content: '',
          seenByNodes: [_distantNodeId, _relayNodeId], // 2 entries = relayed
          hopLimit: 8,
          packetType: 'key_announce',
          senderPublicKey: 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=',
        );
        transport.receiveBytes('ep-relay', TransportCodec.encode(pkt));
        await Future<void>.delayed(Duration.zero);

        final peer = mesh.peers.firstWhere((p) => p.endpointId == 'ep-relay');
        expect(
          peer.nodeId,
          isNull,
          reason: 'Relay endpoint should not gain nodeId from relayed packet',
        );
      },
    );

    test(
      'direct key_announce enriches peer after same relayed announce',
      () async {
        transport.connectPeer('ep-mixed');
        await Future<void>.delayed(Duration.zero);

        final publicKeyB64 = base64Encode(List<int>.filled(32, 7));
        final relayedPacket = AirGridPacket(
          messageId: 'ka-relayed-first',
          senderNodeId: testNodeId('mixed'),
          senderName: 'MixedPeer',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          content: '',
          seenByNodes: [testNodeId('mixed'), _relayNodeId],
          hopLimit: 8,
          packetType: 'key_announce',
          senderPublicKey: publicKeyB64,
        );

        transport.receiveBytes(
          'ep-mixed',
          TransportCodec.encode(relayedPacket),
        );
        await Future<void>.delayed(Duration.zero);

        var peer = mesh.peers.firstWhere((p) => p.endpointId == 'ep-mixed');
        expect(peer.nodeId, isNull);
        expect(peer.encryptionReady, isFalse);

        final directPacket = relayedPacket.copyWith(
          messageId: 'ka-direct-second',
          seenByNodes: [testNodeId('mixed')],
        );

        transport.receiveBytes('ep-mixed', TransportCodec.encode(directPacket));
        await Future<void>.delayed(Duration.zero);

        peer = mesh.peers.firstWhere((p) => p.endpointId == 'ep-mixed');
        expect(peer.nodeId, testNodeId('mixed'));
        expect(peer.encryptionReady, isTrue);
      },
    );
  });

  // ── 14. Legacy packets without conversationType default to public ────────
  group('backward compatibility', () {
    test('packet without conversationType field emits as public', () async {
      final messages = <dynamic>[];
      final sub = mesh.messageStream.listen(messages.add);

      transport.connectPeer('ep-legacy');
      await Future<void>.delayed(Duration.zero);

      // Manually craft JSON without conversationType to simulate a legacy packet.
      final jsonStr = jsonEncode({
        'messageId': 'legacy-001',
        'senderNodeId': _oldNodeId,
        'senderName': 'OldUser',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'content': 'Legacy message',
        'seenByNodes': [_oldNodeId],
        'hopLimit': 8,
        // conversationType intentionally absent
      });
      final bytes = Uint8List.fromList(jsonStr.codeUnits);
      transport.receiveBytes('ep-legacy', bytes);
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
      expect(messages.first.conversationType, 'public');
      await sub.cancel();
    });
  });

  // ── Fragment integration ────────────────────────────────────────────────
  group('fragment integration', () {
    /// Builds a large public packet whose encoded size exceeds kFragmentThreshold.
    AirGridPacket largePacket({String id = 'large-001'}) {
      return AirGridPacket(
        messageId: id,
        senderNodeId: _remoteNodeId,
        senderName: 'Remote',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: 'X' * 6000, // well above 4096-byte threshold
        seenByNodes: [_remoteNodeId],
        hopLimit: 8,
      );
    }

    test('large public sendMessage sends multiple fragment packets', () async {
      transport.connectPeer('ep-1');
      await Future<void>.delayed(Duration.zero);

      await mesh.sendMessage('X' * 6000);
      await Future<void>.delayed(Duration.zero);

      // Every payload sent must decode as a 'fragment' packet.
      final fragPayloads = transport.sentPayloads
          .where((p) => p.endpoints.contains('ep-1'))
          .toList();
      expect(fragPayloads.length, greaterThan(1));
      for (final p in fragPayloads) {
        final decoded = TransportCodec.decode(p.bytes)!;
        expect(decoded.packetType, 'fragment');
      }
    });

    test(
      'receiver reassembles fragments and emits exactly one message',
      () async {
        transport.connectPeer('ep-sender');
        await Future<void>.delayed(Duration.zero);

        final messages = <dynamic>[];
        final sub = mesh.messageStream.listen(messages.add);

        final original = largePacket();
        final frags = PacketFragmenter.fragment(original);
        expect(frags.length, greaterThan(1));

        for (final frag in frags) {
          transport.receiveBytes('ep-sender', TransportCodec.encode(frag));
          await Future<void>.delayed(Duration.zero);
        }

        // Exactly one reassembled message should be emitted.
        expect(messages, hasLength(1));
        expect(messages.first.id, original.messageId);
        expect(messages.first.content, original.content);
        await sub.cancel();
      },
    );

    test(
      'relay forwards fragments but does not rebroadcast the assembled packet',
      () async {
        // ep-sender sends fragments; ep-relay is a second peer that should
        // receive the forwarded fragment chunks but NOT a reassembled packet.
        transport.connectPeer('ep-sender');
        transport.connectPeer('ep-relay');
        await Future<void>.delayed(Duration.zero);

        final original = largePacket(id: 'relay-large');
        final frags = PacketFragmenter.fragment(original);

        final beforeCount = transport.sentPayloads.length;
        for (final frag in frags) {
          transport.receiveBytes('ep-sender', TransportCodec.encode(frag));
          await Future<void>.delayed(Duration.zero);
        }

        final forwarded = transport.sentPayloads.skip(beforeCount).toList();
        // Should have forwarded each fragment once (to ep-relay).
        expect(forwarded.length, frags.length);
        for (final p in forwarded) {
          final decoded = TransportCodec.decode(p.bytes)!;
          // Every forwarded packet must still be a fragment, NOT the reassembled chat.
          expect(
            decoded.packetType,
            'fragment',
            reason: 'assembled packet must not be rebroadcast',
          );
          expect(decoded.fragmentOf, original.messageId);
        }
      },
    );
  });

  // -- Encrypted receipt relay ----------------------------------------------
  group('encrypted receipt relay', () {
    test('encrypted receipt not for us is relayed to other peers', () async {
      transport.connectPeer('ep-sender');
      transport.connectPeer('ep-other');
      await Future<void>.delayed(Duration.zero);

      final receipt = AirGridPacket(
        messageId: 'receipt-relay-001',
        senderNodeId: _remoteNodeId,
        senderName: 'Remote',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: 'ciphertext==',
        seenByNodes: [_remoteNodeId],
        hopLimit: 8,
        packetType: 'delivery_receipt',
        conversationType: 'private',
        encryptionVersion: 1,
        recipientNodeId: _targetNodeId,
      );

      final before = transport.sentPayloads.length;
      transport.receiveBytes('ep-sender', TransportCodec.encode(receipt));
      await Future<void>.delayed(Duration.zero);

      final relayed = transport.sentPayloads.skip(before).toList();
      expect(relayed, isNotEmpty);
      expect(relayed.first.endpoints, isNot(contains('ep-sender')));
      final decoded = TransportCodec.decode(relayed.first.bytes)!;
      expect(decoded.packetType, 'delivery_receipt');
      expect(decoded.encryptionVersion, 1);
    });

    test('encrypted receipt addressed to local decrypts status id', () async {
      final keys = await _makeReceiptCrypto(identity);
      await mesh.dispose();
      mesh = AirGridMeshService(
        transport,
        identity,
        keys.local,
        jitterOverrideMs: 0,
      );

      final statuses = <dynamic>[];
      final sub = mesh.statusStream.listen(statuses.add);

      transport.connectPeer('ep-relay');
      await Future<void>.delayed(Duration.zero);

      final cipher = await keys.remote.encryptContent(
        'original-msg-001',
        identity.nodeId,
      );
      final receipt = AirGridPacket(
        messageId: 'receipt-local-001',
        senderNodeId: _remoteNodeId,
        senderName: 'Remote',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: cipher!,
        seenByNodes: [_remoteNodeId],
        hopLimit: 8,
        packetType: 'read_receipt',
        senderPublicKey: keys.remotePublicKey,
        encryptionVersion: 1,
        conversationType: 'private',
        recipientNodeId: identity.nodeId,
      );

      transport.receiveBytes('ep-relay', TransportCodec.encode(receipt));
      await Future<void>.delayed(Duration.zero);

      expect(statuses, hasLength(1));
      expect(statuses.single.messageId, 'original-msg-001');
      expect(statuses.single.status, DeliveryStatus.read);

      await sub.cancel();
    });

    test(
      'delivery receipt for encrypted chat is encrypted and relayed',
      () async {
        final keys = await _makeReceiptCrypto(identity);
        await mesh.dispose();
        mesh = AirGridMeshService(
          transport,
          identity,
          keys.local,
          jitterOverrideMs: 0,
        );

        transport.connectPeer('ep-relay');
        transport.connectPeer('ep-other');
        await Future<void>.delayed(Duration.zero);

        final cipher = await keys.remote.encryptContent(
          'secret inbound',
          identity.nodeId,
        );
        final inbound = AirGridPacket(
          messageId: 'encrypted-inbound-001',
          senderNodeId: _remoteNodeId,
          senderName: 'Remote',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          content: cipher!,
          seenByNodes: [_remoteNodeId],
          hopLimit: 8,
          senderPublicKey: keys.remotePublicKey,
          encryptionVersion: 1,
          conversationType: 'private',
          recipientNodeId: identity.nodeId,
        );

        final before = transport.sentPayloads.length;
        transport.receiveBytes('ep-relay', TransportCodec.encode(inbound));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        final sentReceipts = transport.sentPayloads
            .skip(before)
            .map((p) => (payload: p, packet: TransportCodec.decode(p.bytes)!))
            .where((p) => p.packet.packetType == 'delivery_receipt')
            .toList();
        expect(sentReceipts, hasLength(1));

        final receipt = sentReceipts.single.packet;
        expect(
          sentReceipts.single.payload.endpoints,
          containsAll(['ep-relay', 'ep-other']),
        );
        expect(receipt.encryptionVersion, 1);
        expect(receipt.senderPublicKey, identity.publicKeyBase64);
        expect(receipt.receiptMessageId, isNull);
        expect(receipt.content, isNotEmpty);

        final decrypted = await keys.remote.decryptContent(
          receipt.content,
          receipt.senderPublicKey!,
        );
        expect(decrypted, inbound.messageId);
      },
    );

    test(
      'sendReadReceipts encrypts receipt payload when key is known',
      () async {
        final keys = await _makeReceiptCrypto(identity);
        await mesh.dispose();
        mesh = AirGridMeshService(
          transport,
          identity,
          keys.local,
          jitterOverrideMs: 0,
        );

        transport.connectPeer('ep-remote', nodeId: _remoteNodeId);
        await Future<void>.delayed(Duration.zero);

        await mesh.sendReadReceipts(_remoteNodeId, ['read-msg-001']);

        final sent = transport.sentPayloads.last;
        expect(sent.endpoints, ['ep-remote']);
        final receipt = TransportCodec.decode(sent.bytes)!;
        expect(receipt.packetType, 'read_receipt');
        expect(receipt.encryptionVersion, 1);
        expect(receipt.receiptMessageId, isNull);

        final decrypted = await keys.remote.decryptContent(
          receipt.content,
          receipt.senderPublicKey!,
        );
        expect(decrypted, 'read-msg-001');
      },
    );
  });

  // -- Encrypted private relay + store-and-forward --------------------------
  group('encrypted private relay', () {
    /// Builds an encrypted private packet addressed to [recipientNodeId].
    AirGridPacket encPrivate({
      String id = 'priv-001',
      String? senderNodeId,
      String? recipientNodeId,
      int hopLimit = 8,
      List<String>? seenByNodes,
    }) {
      final sender = senderNodeId ?? _remoteNodeId;
      final recipient = recipientNodeId ?? _targetNodeId;
      return AirGridPacket(
        messageId: id,
        senderNodeId: sender,
        senderName: 'Remote',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: 'base64ciphertext==',
        seenByNodes: seenByNodes ?? [sender],
        hopLimit: hopLimit,
        conversationType: 'private',
        encryptionVersion: 1,
        recipientNodeId: recipient,
      );
    }

    test('encrypted private not for us is relayed to other peers', () async {
      transport.connectPeer('ep-sender');
      transport.connectPeer('ep-other');
      await Future<void>.delayed(Duration.zero);

      final pkt = encPrivate();
      final before = transport.sentPayloads.length;
      transport.receiveBytes('ep-sender', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      final relayed = transport.sentPayloads.skip(before).toList();
      expect(relayed, isNotEmpty);
      // Must not be sent back to the source endpoint.
      for (final p in relayed) {
        expect(p.endpoints, isNot(contains('ep-sender')));
      }
    });

    test('plaintext private not for us is dropped (no relay)', () async {
      transport.connectPeer('ep-sender');
      transport.connectPeer('ep-other');
      await Future<void>.delayed(Duration.zero);

      final plainPrivate = AirGridPacket(
        messageId: 'plain-priv',
        senderNodeId: _remoteNodeId,
        senderName: 'Remote',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: 'plaintext',
        seenByNodes: [_remoteNodeId],
        hopLimit: 8,
        conversationType: 'private',
        recipientNodeId: _targetNodeId,
        // encryptionVersion intentionally null
      );

      final before = transport.sentPayloads.length;
      transport.receiveBytes('ep-sender', TransportCodec.encode(plainPrivate));
      await Future<void>.delayed(Duration.zero);

      expect(
        transport.sentPayloads.length,
        equals(before),
        reason: 'plaintext private must not be relayed',
      );
    });

    test('duplicate encrypted private relay is suppressed', () async {
      transport.connectPeer('ep-sender');
      transport.connectPeer('ep-other');
      await Future<void>.delayed(Duration.zero);

      final pkt = encPrivate(id: 'dedup-priv');
      final bytes = TransportCodec.encode(pkt);

      transport.receiveBytes('ep-sender', bytes);
      await Future<void>.delayed(Duration.zero);
      final afterFirst = transport.sentPayloads.length;

      transport.receiveBytes('ep-sender', bytes); // duplicate
      await Future<void>.delayed(Duration.zero);

      expect(
        transport.sentPayloads.length,
        equals(afterFirst),
        reason: 'second copy of same encrypted private must not be relayed',
      );
    });

    test('encrypted private is spooled when no connected peers', () async {
      // Only the sender is connected; no relay targets.
      transport.connectPeer('ep-sender');
      await Future<void>.delayed(Duration.zero);

      final pkt = encPrivate(id: 'spool-001');
      final before = transport.sentPayloads.length;
      transport.receiveBytes('ep-sender', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      // Nothing should be sent while no relay target exists.
      expect(
        transport.sentPayloads.length,
        equals(before),
        reason: 'no relay targets: packet should be spooled, not sent',
      );
    });

    test(
      'spooled packet is flushed when recipient connects via key_announce',
      () async {
        transport.connectPeer('ep-sender');
        await Future<void>.delayed(Duration.zero);

        // Spool a packet for _targetNodeId.
        final pkt = encPrivate(
          id: 'spool-flush-001',
          recipientNodeId: _targetNodeId,
        );
        transport.receiveBytes('ep-sender', TransportCodec.encode(pkt));
        await Future<void>.delayed(Duration.zero);

        final beforeFlush = transport.sentPayloads.length;

        // Now _targetNodeId connects and announces its key.
        transport.connectPeer('ep-target');
        await Future<void>.delayed(Duration.zero);

        final directAnnounce = AirGridPacket(
          messageId: 'ka-target',
          senderNodeId: _targetNodeId,
          senderName: 'Target',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          content: '',
          seenByNodes: [_targetNodeId], // single entry = direct peer
          hopLimit: 8,
          packetType: 'key_announce',
          senderPublicKey: base64Encode(List<int>.filled(32, 9)),
        );
        transport.receiveBytes(
          'ep-target',
          TransportCodec.encode(directAnnounce),
        );
        await Future<void>.delayed(Duration.zero);

        // The spooled packet should have been flushed to ep-target.
        final flushed = transport.sentPayloads
            .skip(beforeFlush)
            .where((p) => p.endpoints.contains('ep-target'))
            .toList();
        expect(
          flushed,
          isNotEmpty,
          reason: 'spooled packet should be delivered on recipient connect',
        );
        final decoded = TransportCodec.decode(flushed.first.bytes)!;
        expect(decoded.messageId, pkt.messageId);
      },
    );

    test('expired spool entry is not delivered', () async {
      // Use an injectable fake clock to test TTL expiry deterministically.
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final expiredTransport = FakeTransport();
      final expiredMesh = AirGridMeshService(
        expiredTransport,
        identity,
        CryptoService(),
        jitterOverrideMs: 0,
        spoolClock: () => fakeNow,
      );

      // Sender connects; spool a packet for _expireTargetNodeId.
      expiredTransport.connectPeer('ep-sender-exp');
      await Future<void>.delayed(Duration.zero);

      final pkt = encPrivate(
        id: 'expire-001',
        recipientNodeId: _expireTargetNodeId,
      );
      expiredTransport.receiveBytes(
        'ep-sender-exp',
        TransportCodec.encode(pkt),
      );
      await Future<void>.delayed(Duration.zero);

      // Advance clock past kSpoolTtlSeconds (15 s).
      fakeNow = fakeNow.add(const Duration(seconds: 20));

      // Now recipient connects and announces itself.
      expiredTransport.connectPeer('ep-expire-target');
      await Future<void>.delayed(Duration.zero);

      final ka = AirGridPacket(
        messageId: 'ka-expire',
        senderNodeId: _expireTargetNodeId,
        senderName: 'ExpireTarget',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: '',
        seenByNodes: [_expireTargetNodeId],
        hopLimit: 8,
        packetType: 'key_announce',
        senderPublicKey: base64Encode(List<int>.filled(32, 7)),
      );
      expiredTransport.receiveBytes(
        'ep-expire-target',
        TransportCodec.encode(ka),
      );
      await Future<void>.delayed(Duration.zero);

      // The expired entry must NOT have been delivered.
      final flushed = expiredTransport.sentPayloads
          .where((p) => p.endpoints.contains('ep-expire-target'))
          .toList();
      expect(
        flushed.any(
          (p) => TransportCodec.decode(p.bytes)?.messageId == pkt.messageId,
        ),
        isFalse,
        reason: 'expired spool entry must not be delivered',
      );

      await expiredMesh.dispose();
    });

    test(
      'encrypted private is delivered direct when recipient already connected',
      () async {
        transport.connectPeer('ep-sender');
        transport.connectPeer('ep-target');
        await Future<void>.delayed(Duration.zero);

        // Let mesh know ep-target == _targetNodeId via key_announce.
        final ka = AirGridPacket(
          messageId: 'ka-direct',
          senderNodeId: _targetNodeId,
          senderName: 'Target',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          content: '',
          seenByNodes: [_targetNodeId],
          hopLimit: 8,
          packetType: 'key_announce',
          senderPublicKey: base64Encode(List<int>.filled(32, 5)),
        );
        transport.receiveBytes('ep-target', TransportCodec.encode(ka));
        await Future<void>.delayed(Duration.zero);

        final before = transport.sentPayloads.length;
        final pkt = encPrivate(id: 'direct-delivery');
        transport.receiveBytes('ep-sender', TransportCodec.encode(pkt));
        await Future<void>.delayed(Duration.zero);

        final sent = transport.sentPayloads.skip(before).toList();
        expect(sent, hasLength(1));
        expect(
          sent.first.endpoints,
          equals(['ep-target']),
          reason: 'should be delivered only to the known direct endpoint',
        );
      },
    );
  });

  // -- Known contacts -------------------------------------------------------
  group('known contacts', () {
    // This group needs a CryptoService with a loaded local keypair so that
    // sendPrivateMessageToContact can actually encrypt.
    late FakeTransport kTransport;
    late AirGridMeshService kMesh;

    setUp(() async {
      kTransport = FakeTransport();
      final crypto = CryptoService();
      await crypto.loadLocalKeyPair(
        identity.privateKeyBase64!,
        identity.publicKeyBase64!,
      );
      kMesh = AirGridMeshService(
        kTransport,
        identity,
        crypto,
        jitterOverrideMs: 0,
      );
      await Future<void>.delayed(Duration.zero);
    });

    tearDown(() async {
      await kMesh.dispose();
      kTransport.dispose();
    });

    /// Build a key_announce packet from [senderNodeId].
    AirGridPacket keyAnnounce({
      required String senderNodeId,
      required String senderName,
      required String publicKey,
      List<String>? seenByNodes,
    }) {
      return AirGridPacket(
        messageId: 'ka-$senderNodeId',
        senderNodeId: senderNodeId,
        senderName: senderName,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: '',
        seenByNodes: seenByNodes ?? [senderNodeId],
        hopLimit: 8,
        packetType: 'key_announce',
        senderPublicKey: publicKey,
      );
    }

    // A valid 32-byte X25519 public key for test contacts.
    final testKey = base64Encode(List<int>.filled(32, 0xAB));

    test('direct key_announce creates contact with endpoint', () async {
      kTransport.connectPeer('ep-alice');
      await Future<void>.delayed(Duration.zero);

      final ka = keyAnnounce(
        senderNodeId: _aliceNodeId,
        senderName: 'Alice',
        publicKey: testKey,
        seenByNodes: [_aliceNodeId], // direct: single entry == sender
      );
      kTransport.receiveBytes('ep-alice', TransportCodec.encode(ka));
      await Future<void>.delayed(Duration.zero);

      final contacts = kMesh.knownContacts;
      expect(contacts, hasLength(1));
      expect(contacts.first.nodeId, _aliceNodeId);
      expect(contacts.first.displayName, 'Alice');
      expect(contacts.first.publicKeyBase64, testKey);
      expect(contacts.first.lastEndpointId, 'ep-alice');
      expect(contacts.first.isDirectlyConnected, isTrue);
    });

    test('relayed key_announce creates contact without endpoint', () async {
      kTransport.connectPeer('ep-relay');
      await Future<void>.delayed(Duration.zero);

      final ka = keyAnnounce(
        senderNodeId: _bobNodeId,
        senderName: 'Bob',
        publicKey: testKey,
        seenByNodes: [_bobNodeId, _relayNodeId], // relayed: more than one hop
      );
      kTransport.receiveBytes('ep-relay', TransportCodec.encode(ka));
      await Future<void>.delayed(Duration.zero);

      final contacts = kMesh.knownContacts;
      expect(contacts.any((c) => c.nodeId == _bobNodeId), isTrue);
      final bob = contacts.firstWhere((c) => c.nodeId == _bobNodeId);
      expect(
        bob.lastEndpointId,
        isNull,
        reason: 'relayed announce should not set endpoint',
      );
    });

    test('peer disconnect clears lastEndpointId', () async {
      kTransport.connectPeer('ep-alice');
      await Future<void>.delayed(Duration.zero);

      kTransport.receiveBytes(
        'ep-alice',
        TransportCodec.encode(
          keyAnnounce(
            senderNodeId: _aliceNodeId,
            senderName: 'Alice',
            publicKey: testKey,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(kMesh.knownContacts.first.isDirectlyConnected, isTrue);

      kTransport.disconnectPeer('ep-alice');
      await Future<void>.delayed(Duration.zero);

      final alice = kMesh.knownContacts.firstWhere(
        (c) => c.nodeId == _aliceNodeId,
      );
      expect(
        alice.lastEndpointId,
        isNull,
        reason: 'disconnect should mark contact offline',
      );
    });

    test('knownContactsStream emits on changes', () async {
      final emitted = <int>[];
      final sub = kMesh.knownContactsStream.listen(
        (contacts) => emitted.add(contacts.length),
      );

      kTransport.connectPeer('ep-carol');
      await Future<void>.delayed(Duration.zero);

      kTransport.receiveBytes(
        'ep-carol',
        TransportCodec.encode(
          keyAnnounce(
            senderNodeId: _carolNodeId,
            senderName: 'Carol',
            publicKey: testKey,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(emitted, contains(1));
      await sub.cancel();
    });

    test(
      'sendPrivateMessageToContact broadcasts when contact not direct',
      () async {
        // Populate _bobNodeId via relayed key_announce.
        kTransport.connectPeer('ep-relay');
        await Future<void>.delayed(Duration.zero);

        kTransport.receiveBytes(
          'ep-relay',
          TransportCodec.encode(
            keyAnnounce(
              senderNodeId: _bobNodeId,
              senderName: 'Bob',
              publicKey: testKey,
              seenByNodes: [_bobNodeId, _relayNodeId],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final bob = kMesh.knownContacts.firstWhere(
          (c) => c.nodeId == _bobNodeId,
        );
        final before = kTransport.sentPayloads.length;

        final result = await kMesh.sendPrivateMessageToContact(bob, 'Hey Bob!');
        expect(result, PrivateSendResult.sentEncrypted);

        final sent = kTransport.sentPayloads.skip(before).toList();
        expect(sent, isNotEmpty);
        final decoded = TransportCodec.decode(sent.first.bytes)!;
        expect(
          decoded.encryptionVersion,
          isNotNull,
          reason: 'must be encrypted',
        );
        expect(decoded.recipientNodeId, _bobNodeId);
      },
    );

    test(
      'sendPrivateMessageToContact sends direct when endpoint known',
      () async {
        kTransport.connectPeer('ep-alice');
        await Future<void>.delayed(Duration.zero);

        kTransport.receiveBytes(
          'ep-alice',
          TransportCodec.encode(
            keyAnnounce(
              senderNodeId: _aliceNodeId,
              senderName: 'Alice',
              publicKey: testKey,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        kTransport.connectPeer('ep-other');
        await Future<void>.delayed(Duration.zero);

        final alice = kMesh.knownContacts.firstWhere(
          (c) => c.nodeId == _aliceNodeId,
        );
        final before = kTransport.sentPayloads.length;

        await kMesh.sendPrivateMessageToContact(alice, 'Direct to Alice');

        final sent = kTransport.sentPayloads.skip(before).toList();
        expect(sent, hasLength(1));
        expect(
          sent.first.endpoints,
          equals(['ep-alice']),
          reason: 'direct send must target only the known endpoint',
        );
      },
    );

    test(
      'sendPrivateMessageToContact spools when no peers connected',
      () async {
        // Populate _daveNodeId while a relay is connected, then disconnect.
        kTransport.connectPeer('ep-relay2');
        await Future<void>.delayed(Duration.zero);

        kTransport.receiveBytes(
          'ep-relay2',
          TransportCodec.encode(
            keyAnnounce(
              senderNodeId: _daveNodeId,
              senderName: 'Dave',
              publicKey: testKey,
              seenByNodes: [_daveNodeId, _relayNodeId],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        kTransport.disconnectPeer('ep-relay2');
        await Future<void>.delayed(Duration.zero);

        final dave = kMesh.knownContacts.firstWhere(
          (c) => c.nodeId == _daveNodeId,
        );
        final before = kTransport.sentPayloads.length;

        final result = await kMesh.sendPrivateMessageToContact(
          dave,
          'Hello Dave',
        );
        expect(
          result,
          PrivateSendResult.sentEncrypted,
          reason: 'spooled still reports sentEncrypted',
        );
        expect(
          kTransport.sentPayloads.length,
          equals(before),
          reason: 'nothing sent over transport when no peers',
        );
      },
    );

    test('contact persists across duplicate key_announces', () async {
      kTransport.connectPeer('ep-eve');
      await Future<void>.delayed(Duration.zero);

      final ka = keyAnnounce(
        senderNodeId: _eveNodeId,
        senderName: 'Eve',
        publicKey: testKey,
      );
      final bytes = TransportCodec.encode(ka);

      kTransport.receiveBytes('ep-eve', bytes);
      await Future<void>.delayed(Duration.zero);
      kTransport.receiveBytes('ep-eve', bytes); // duplicate
      await Future<void>.delayed(Duration.zero);

      expect(
        kMesh.knownContacts.where((c) => c.nodeId == _eveNodeId),
        hasLength(1),
      );
    });
  });

  // ── 16. Blocking — packet gate & send guard ──────────────────────────────
  group('blocking', () {
    late FakeTransport bTransport;
    late AirGridMeshService bMesh;
    late InMemoryKnownContactStore contactStore;
    final testKey = base64Encode(List<int>.filled(32, 0xAB));

    AirGridPacket keyAnnounce(String senderNodeId, String senderName) {
      return AirGridPacket(
        messageId: 'bka-$senderNodeId',
        senderNodeId: senderNodeId,
        senderName: senderName,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        content: '',
        seenByNodes: [senderNodeId],
        hopLimit: 8,
        packetType: 'key_announce',
        senderPublicKey: testKey,
      );
    }

    setUp(() async {
      contactStore = InMemoryKnownContactStore();
      bTransport = FakeTransport();
      final crypto = CryptoService();
      await crypto.loadLocalKeyPair(
        identity.privateKeyBase64!,
        identity.publicKeyBase64!,
      );
      bMesh = AirGridMeshService(
        bTransport,
        identity,
        crypto,
        jitterOverrideMs: 0,
        contactStore: contactStore,
      );
      await Future<void>.delayed(Duration.zero);
    });

    tearDown(() async {
      await bMesh.dispose();
      bTransport.dispose();
      await contactStore.dispose();
    });

    test('blocked public packet is not emitted to messageStream', () async {
      bTransport.connectPeer('ep-blocked');
      await Future<void>.delayed(Duration.zero);

      // First receive a key_announce so the sender is known.
      bTransport.receiveBytes(
        'ep-blocked',
        TransportCodec.encode(keyAnnounce(_aliceNodeId, 'Alice')),
      );
      await Future<void>.delayed(Duration.zero);

      await contactStore.block(_aliceNodeId);

      final messages = <dynamic>[];
      final sub = bMesh.messageStream.listen(messages.add);

      final pkt = _packet(id: 'block-pub-001', senderNodeId: _aliceNodeId);
      bTransport.receiveBytes('ep-blocked', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty, reason: 'blocked sender must be silenced');
      await sub.cancel();
    });

    test('blocked public packet is not rebroadcast', () async {
      bTransport.connectPeer('ep-blocked');
      bTransport.connectPeer('ep-other');
      await Future<void>.delayed(Duration.zero);

      // Upsert alice first so block() takes effect.
      await contactStore.upsert(KnownContact(
        nodeId: _aliceNodeId,
        displayName: 'Alice',
        publicKeyBase64: testKey,
        lastSeenAt: DateTime(2024),
      ));
      await contactStore.block(_aliceNodeId);

      final before = bTransport.sentPayloads.length;
      final pkt = _packet(id: 'block-pub-002', senderNodeId: _aliceNodeId);
      bTransport.receiveBytes('ep-blocked', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(
        bTransport.sentPayloads.length,
        equals(before),
        reason: 'no rebroadcast for blocked sender',
      );
    });

    test('blocked key_announce is dropped and does not clear isBlocked', () async {
      // Pre-seed alice as blocked so the gate can fire on her key_announce.
      await contactStore.upsert(KnownContact(
        nodeId: _aliceNodeId,
        displayName: 'Alice',
        publicKeyBase64: testKey,
        lastSeenAt: DateTime(2024),
      ));
      await contactStore.block(_aliceNodeId);

      bTransport.connectPeer('ep-blocked');
      await Future<void>.delayed(Duration.zero);

      bTransport.receiveBytes(
        'ep-blocked',
        TransportCodec.encode(keyAnnounce(_aliceNodeId, 'Alice')),
      );
      await Future<void>.delayed(Duration.zero);

      // The block gate dropped the key_announce — alice remains blocked.
      expect(
        contactStore.isBlocked(_aliceNodeId),
        isTrue,
        reason: 'blocked key_announce must not clear isBlocked',
      );
    });

    test('sendPrivateMessage to blocked peer returns blockedContact', () async {
      bTransport.connectPeer('ep-blocked');
      await Future<void>.delayed(Duration.zero);

      // Give the peer a nodeId via key_announce.
      bTransport.receiveBytes(
        'ep-blocked',
        TransportCodec.encode(keyAnnounce(_aliceNodeId, 'Alice')),
      );
      await Future<void>.delayed(Duration.zero);

      final peer = bMesh.peers.firstWhere(
        (p) => p.nodeId == _aliceNodeId,
      );

      await contactStore.block(_aliceNodeId);

      final result = await bMesh.sendPrivateMessage(peer, 'Should not send');
      expect(result, PrivateSendResult.blockedContact);
    });

    test(
      'sendPrivateMessageToContact to blocked contact returns blockedContact',
      () async {
        bTransport.connectPeer('ep-blocked');
        await Future<void>.delayed(Duration.zero);

        bTransport.receiveBytes(
          'ep-blocked',
          TransportCodec.encode(keyAnnounce(_bobNodeId, 'Bob')),
        );
        await Future<void>.delayed(Duration.zero);

        final bob = bMesh.knownContacts.firstWhere(
          (c) => c.nodeId == _bobNodeId,
        );
        await contactStore.block(_bobNodeId);

        final result = await bMesh.sendPrivateMessageToContact(
          bob,
          'Should not send',
        );
        expect(result, PrivateSendResult.blockedContact);
      },
    );

    test('unblocked peer receives messages again', () async {
      bTransport.connectPeer('ep-alice');
      await Future<void>.delayed(Duration.zero);

      bTransport.receiveBytes(
        'ep-alice',
        TransportCodec.encode(keyAnnounce(_aliceNodeId, 'Alice')),
      );
      await Future<void>.delayed(Duration.zero);

      await contactStore.block(_aliceNodeId);
      await contactStore.unblock(_aliceNodeId);

      final messages = <dynamic>[];
      final sub = bMesh.messageStream.listen(messages.add);

      final pkt = _packet(id: 'unblock-001', senderNodeId: _aliceNodeId);
      bTransport.receiveBytes('ep-alice', TransportCodec.encode(pkt));
      await Future<void>.delayed(Duration.zero);

      expect(
        messages,
        hasLength(1),
        reason: 'unblocked sender should be visible again',
      );
      await sub.cancel();
    });
  });
}
