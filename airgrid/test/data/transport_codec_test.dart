import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/constants.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:flutter_test/flutter_test.dart';

// Helper — asserts that a decoded packet matches its source field-by-field.
void _expectRoundTrip(AirGridPacket original, AirGridPacket? decoded) {
  expect(decoded, isNotNull, reason: 'decode returned null');
  final p = decoded!;
  expect(p.messageId, original.messageId);
  expect(p.senderNodeId, original.senderNodeId);
  expect(p.senderName, original.senderName);
  expect(p.timestamp, original.timestamp);
  expect(p.content, original.content);
  expect(p.seenByNodes, original.seenByNodes);
  expect(p.hopLimit, original.hopLimit);
  expect(p.packetType, original.packetType);
  expect(p.conversationType, original.conversationType);
  expect(p.recipientNodeId, original.recipientNodeId);
  expect(p.encryptionVersion, original.encryptionVersion);
  expect(p.senderPublicKey, original.senderPublicKey);
  expect(p.receiptMessageId, original.receiptMessageId);
  expect(p.fragmentOf, original.fragmentOf);
  expect(p.fragmentIndex, original.fragmentIndex);
  expect(p.fragmentCount, original.fragmentCount);
}

void main() {
  final basePacket = AirGridPacket(
    messageId: 'test-id-1234',
    senderNodeId: 'node-abc',
    senderName: 'Alice',
    timestamp: 1700000000000,
    content: 'Hello mesh',
    seenByNodes: ['node-abc'],
    hopLimit: 8,
  );

  group('TransportCodec.encode', () {
    test('produces non-empty bytes', () {
      final bytes = TransportCodec.encode(basePacket);
      expect(bytes, isNotEmpty);
    });

    test('round-trips through decode', () {
      final bytes = TransportCodec.encode(basePacket);
      final decoded = TransportCodec.decode(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.messageId, basePacket.messageId);
      expect(decoded.senderNodeId, basePacket.senderNodeId);
      expect(decoded.content, basePacket.content);
      expect(decoded.hopLimit, basePacket.hopLimit);
      expect(decoded.seenByNodes, basePacket.seenByNodes);
    });

    test('throws when packet exceeds max packet bytes', () {
      final bigPacket = basePacket.copyWith(
        content: 'x' * (AirGridConstants.kMaxPacketBytes + 1),
      );
      expect(() => TransportCodec.encode(bigPacket), throwsArgumentError);
    });
  });

  group('TransportCodec.decode', () {
    test('returns null for empty bytes', () {
      expect(TransportCodec.decode(Uint8List(0)), isNull);
    });

    test('returns null for random garbage bytes', () {
      final garbage = Uint8List.fromList(List.generate(100, (i) => i % 256));
      expect(TransportCodec.decode(garbage), isNull);
    });

    test('returns null for oversized payload', () {
      final oversized = Uint8List(AirGridConstants.kMaxPacketBytes + 1);
      expect(TransportCodec.decode(oversized), isNull);
    });

    test('returns null for valid UTF-8 but invalid JSON structure', () {
      final badJson = Uint8List.fromList('{"foo":"bar"}'.codeUnits);
      expect(TransportCodec.decode(badJson), isNull);
    });

    test('returns null for valid JSON with missing required fields', () {
      final partial = Uint8List.fromList('{"messageId":"x"}'.codeUnits);
      expect(TransportCodec.decode(partial), isNull);
    });
  });

  group('private packet round-trip', () {
    test('conversationType and recipientNodeId survive encode/decode', () {
      final privatePacket = AirGridPacket(
        messageId: 'priv-rt-1',
        senderNodeId: 'node-alice',
        senderName: 'Alice',
        timestamp: 1700000000000,
        content: 'Secret',
        seenByNodes: ['node-alice'],
        hopLimit: 8,
        conversationType: 'private',
        recipientNodeId: 'node-bob',
      );

      final bytes = TransportCodec.encode(privatePacket);
      final decoded = TransportCodec.decode(bytes);

      expect(decoded, isNotNull);
      expect(decoded!.conversationType, 'private');
      expect(decoded.recipientNodeId, 'node-bob');
    });
  });

  group('missing conversationType defaults to public', () {
    test('JSON without conversationType key decodes as public', () {
      // Build raw JSON without conversationType.
      final json = {
        'messageId': 'legacy-ct-1',
        'senderNodeId': 'node-old',
        'senderName': 'OldUser',
        'timestamp': 1700000000000,
        'content': 'Hello',
        'seenByNodes': ['node-old'],
        'hopLimit': 8,
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
      final decoded = TransportCodec.decode(bytes);

      expect(decoded, isNotNull);
      expect(decoded!.conversationType, 'public');
    });
  });

  // ── Binary v2 round-trip tests ───────────────────────────────────────────

  group('binary v2 round-trip', () {
    test('first byte of encoded output is 0x02', () {
      final bytes = TransportCodec.encode(basePacket);
      expect(bytes.first, 0x02);
    });

    test('public chat round-trip', () {
      final p = AirGridPacket(
        messageId: 'chat-rt-1',
        senderNodeId: 'node-abc',
        senderName: 'Alice',
        timestamp: 1700000000000,
        content: 'Hello v2',
        seenByNodes: ['node-abc', 'node-xyz'],
        hopLimit: 6,
        packetType: 'chat',
        conversationType: 'public',
      );
      _expectRoundTrip(p, TransportCodec.decode(TransportCodec.encode(p)));
    });

    test('image packet round-trip', () {
      final packet = AirGridPacket(
        messageId: 'img-rt-1',
        senderNodeId: 'node-alice',
        senderName: 'Alice',
        timestamp: 1700000000000,
        content: '{"kind":"image","data":"abc"}',
        seenByNodes: const ['node-alice'],
        hopLimit: 8,
        packetType: 'image',
        conversationType: 'private',
        recipientNodeId: 'node-bob',
        encryptionVersion: 1,
      );

      final bytes = TransportCodec.encode(packet);
      final decoded = TransportCodec.decode(bytes);
      _expectRoundTrip(packet, decoded);
    });

    test('key_announce round-trip with senderPublicKey', () {
      final p = AirGridPacket(
        messageId: 'ka-rt-1',
        senderNodeId: 'node-ka',
        senderName: 'Bob',
        timestamp: 1700000000001,
        content: '',
        seenByNodes: ['node-ka'],
        hopLimit: 7,
        packetType: 'key_announce',
        senderPublicKey: 'base64pubkey==',
        encryptionVersion: 1,
      );
      _expectRoundTrip(p, TransportCodec.decode(TransportCodec.encode(p)));
    });

    test('private encrypted chat round-trip', () {
      final p = AirGridPacket(
        messageId: 'priv-rt-2',
        senderNodeId: 'node-alice',
        senderName: 'Alice',
        timestamp: 1700000000002,
        content: 'base64(encryptedCiphertext==)',
        seenByNodes: ['node-alice'],
        hopLimit: 8,
        packetType: 'chat',
        conversationType: 'private',
        recipientNodeId: 'node-bob',
        encryptionVersion: 1,
        senderPublicKey: 'alicePubKey==',
      );
      _expectRoundTrip(p, TransportCodec.decode(TransportCodec.encode(p)));
    });

    test('delivery_receipt round-trip with receiptMessageId', () {
      final p = AirGridPacket(
        messageId: 'rcpt-rt-1',
        senderNodeId: 'node-bob',
        senderName: 'Bob',
        timestamp: 1700000000003,
        content: '',
        seenByNodes: ['node-bob'],
        hopLimit: 3,
        packetType: 'delivery_receipt',
        conversationType: 'private',
        recipientNodeId: 'node-alice',
        receiptMessageId: 'priv-rt-2',
      );
      _expectRoundTrip(p, TransportCodec.decode(TransportCodec.encode(p)));
    });

    test('read_receipt round-trip', () {
      final p = AirGridPacket(
        messageId: 'rr-rt-1',
        senderNodeId: 'node-bob',
        senderName: 'Bob',
        timestamp: 1700000000004,
        content: '',
        seenByNodes: ['node-bob'],
        hopLimit: 3,
        packetType: 'read_receipt',
        conversationType: 'private',
        recipientNodeId: 'node-alice',
        receiptMessageId: 'priv-rt-2',
      );
      _expectRoundTrip(p, TransportCodec.decode(TransportCodec.encode(p)));
    });

    test('rider control round-trip', () {
      final p = AirGridPacket(
        messageId: 'rider-control-1',
        senderNodeId: 'node-alice',
        senderName: 'Alice',
        timestamp: 1700000000005,
        content: 'encrypted-control',
        seenByNodes: ['node-alice'],
        hopLimit: 1,
        packetType: 'rider_control',
        conversationType: 'private',
        recipientNodeId: 'node-bob',
        senderPublicKey: 'public-key',
        encryptionVersion: 1,
      );
      _expectRoundTrip(p, TransportCodec.decode(TransportCodec.encode(p)));
    });

    test('rider audio frame round-trip', () {
      final p = AirGridPacket(
        messageId: 'rider-frame-1',
        senderNodeId: 'node-alice',
        senderName: 'Alice',
        timestamp: 1700000000006,
        content: 'encrypted-frame',
        seenByNodes: ['node-alice'],
        hopLimit: 1,
        packetType: 'rider_audio_frame',
        conversationType: 'private',
        recipientNodeId: 'node-bob',
        senderPublicKey: 'public-key',
        encryptionVersion: 1,
      );
      _expectRoundTrip(p, TransportCodec.decode(TransportCodec.encode(p)));
    });

    test('fragment round-trip with all fragment fields', () {
      final p = AirGridPacket(
        messageId: 'frag-rt-1',
        senderNodeId: 'node-alice',
        senderName: 'Alice',
        timestamp: 1700000000005,
        content: 'base64(chunkBytes==)',
        seenByNodes: ['node-alice'],
        hopLimit: 8,
        packetType: 'fragment',
        fragmentOf: 'original-msg-id-xyz',
        fragmentIndex: 2,
        fragmentCount: 5,
      );
      _expectRoundTrip(p, TransportCodec.decode(TransportCodec.encode(p)));
    });

    test('non-UUID nodeIds survive encode/decode', () {
      final p = AirGridPacket(
        messageId: 'non-uuid-msg',
        senderNodeId: 'short-id',
        senderName: 'Dev',
        timestamp: 1700000000006,
        content: 'test',
        seenByNodes: ['short-id'],
        hopLimit: 4,
      );
      final decoded = TransportCodec.decode(TransportCodec.encode(p));
      expect(decoded?.senderNodeId, 'short-id');
      expect(decoded?.messageId, 'non-uuid-msg');
    });

    test('empty seenByNodes survives encode/decode', () {
      final p = AirGridPacket(
        messageId: 'empty-seen',
        senderNodeId: 'node-x',
        senderName: 'X',
        timestamp: 1700000000007,
        content: '',
        seenByNodes: const [],
        hopLimit: 8,
      );
      final decoded = TransportCodec.decode(TransportCodec.encode(p));
      expect(decoded?.seenByNodes, isEmpty);
    });

    test('legacy UTF-8 JSON still decodes (backward compat)', () {
      final json = {
        'messageId': 'legacy-v1',
        'senderNodeId': 'node-legacy',
        'senderName': 'Legacy',
        'timestamp': 1700000000008,
        'content': 'Old format',
        'seenByNodes': ['node-legacy'],
        'hopLimit': 8,
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
      final decoded = TransportCodec.decode(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.messageId, 'legacy-v1');
      expect(decoded.conversationType, 'public');
    });
  });
}
