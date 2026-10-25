import 'dart:convert';

import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_node_ids.dart';

/// Header binding at the AEAD layer.
///
/// A ciphertext is authenticated together with the packet header it was sent
/// under, so neither the content nor the header can be reused apart from the
/// other. These tests pin that contract below the mesh service.
final _aliceId = testNodeId('alice');
final _bobId = testNodeId('bob');

Future<({CryptoService alice, CryptoService bob})> _pair() async {
  final x25519 = X25519();
  final aliceKp = await x25519.newKeyPair();
  final bobKp = await x25519.newKeyPair();
  final alicePub = base64Encode((await aliceKp.extractPublicKey()).bytes);
  final bobPub = base64Encode((await bobKp.extractPublicKey()).bytes);

  final alice = CryptoService();
  await alice.loadLocalKeyPair(
    base64Encode(await aliceKp.extractPrivateKeyBytes()),
    alicePub,
  );
  alice.cacheKey(_bobId, bobPub);

  final bob = CryptoService();
  await bob.loadLocalKeyPair(
    base64Encode(await bobKp.extractPrivateKeyBytes()),
    bobPub,
  );
  bob.cacheKey(_aliceId, alicePub);

  return (alice: alice, bob: bob);
}

AirGridPacket _packet({
  required String messageId,
  String content = '',
  int? version = CryptoService.kEncryptionVersion,
  int timestamp = 1700000000000,
}) => AirGridPacket(
  messageId: messageId,
  senderNodeId: _aliceId,
  senderName: 'Alice',
  timestamp: timestamp,
  content: content,
  seenByNodes: [_aliceId],
  hopLimit: 8,
  conversationType: 'private',
  recipientNodeId: _bobId,
  encryptionVersion: version,
);

void main() {
  group('CryptoService.associatedData', () {
    test('changes with every bound header field', () {
      final base = CryptoService.associatedData(
        messageId: 'm1',
        senderNodeId: _aliceId,
        recipientNodeId: _bobId,
        packetType: 'chat',
        timestamp: 1,
      );
      final variants = [
        CryptoService.associatedData(
          messageId: 'm2',
          senderNodeId: _aliceId,
          recipientNodeId: _bobId,
          packetType: 'chat',
          timestamp: 1,
        ),
        CryptoService.associatedData(
          messageId: 'm1',
          senderNodeId: _bobId,
          recipientNodeId: _bobId,
          packetType: 'chat',
          timestamp: 1,
        ),
        CryptoService.associatedData(
          messageId: 'm1',
          senderNodeId: _aliceId,
          recipientNodeId: _aliceId,
          packetType: 'chat',
          timestamp: 1,
        ),
        CryptoService.associatedData(
          messageId: 'm1',
          senderNodeId: _aliceId,
          recipientNodeId: _bobId,
          packetType: 'image',
          timestamp: 1,
        ),
        CryptoService.associatedData(
          messageId: 'm1',
          senderNodeId: _aliceId,
          recipientNodeId: _bobId,
          packetType: 'chat',
          timestamp: 2,
        ),
      ];
      for (final v in variants) {
        expect(v, isNot(equals(base)));
      }
    });

    test('is empty for a legacy version-1 packet', () {
      final packet = _packet(
        messageId: 'm1',
        version: CryptoService.kLegacyEncryptionVersion,
      );
      expect(CryptoService.associatedDataFor(packet), isEmpty);
    });

    test('for a version-2 packet matches the explicit builder', () {
      final packet = _packet(messageId: 'm1');
      expect(
        CryptoService.associatedDataFor(packet),
        CryptoService.associatedData(
          messageId: packet.messageId,
          senderNodeId: packet.senderNodeId,
          recipientNodeId: packet.recipientNodeId,
          packetType: packet.packetType,
          timestamp: packet.timestamp,
        ),
      );
    });
  });

  group('AEAD header binding', () {
    test('round-trips under the same header', () async {
      final pair = await _pair();
      final header = _packet(messageId: 'm1');
      final cipher = await pair.alice.encryptContent(
        'hello',
        _bobId,
        aad: CryptoService.associatedDataFor(header),
      );
      final sent = header.copyWith(content: cipher);

      final plain = await pair.bob.decryptContent(
        sent.content,
        pair.bob.pinnedKeyBase64(_aliceId)!,
        aad: CryptoService.associatedDataFor(sent),
      );
      expect(plain, 'hello');
    });

    test('the same ciphertext under a new message id fails', () async {
      final pair = await _pair();
      final header = _packet(messageId: 'm1');
      final cipher = await pair.alice.encryptContent(
        'hello',
        _bobId,
        aad: CryptoService.associatedDataFor(header),
      );
      final replayed = header.copyWith(messageId: 'm2', content: cipher);

      final plain = await pair.bob.decryptContent(
        replayed.content,
        pair.bob.pinnedKeyBase64(_aliceId)!,
        aad: CryptoService.associatedDataFor(replayed),
      );
      expect(plain, isNull);
    });

    test('a bound ciphertext cannot be read as a legacy packet', () async {
      final pair = await _pair();
      final header = _packet(messageId: 'm1');
      final cipher = await pair.alice.encryptContent(
        'hello',
        _bobId,
        aad: CryptoService.associatedDataFor(header),
      );
      // Relabelling the version strips the AAD on the receiving side; the
      // MAC was computed over it, so it no longer verifies.
      final downgraded = header.copyWith(
        content: cipher,
        encryptionVersion: CryptoService.kLegacyEncryptionVersion,
      );

      final plain = await pair.bob.decryptContent(
        downgraded.content,
        pair.bob.pinnedKeyBase64(_aliceId)!,
        aad: CryptoService.associatedDataFor(downgraded),
      );
      expect(plain, isNull);
    });
  });

  group('CryptoService.pinKeyIfAbsent', () {
    test('pins when nothing is cached and keeps the first key after', () {
      final crypto = CryptoService();
      final first = base64Encode(List<int>.filled(32, 1));
      final second = base64Encode(List<int>.filled(32, 2));

      expect(crypto.pinKeyIfAbsent(_aliceId, first), isTrue);
      expect(crypto.pinnedKeyBase64(_aliceId), first);

      expect(crypto.pinKeyIfAbsent(_aliceId, second), isTrue);
      expect(crypto.pinnedKeyBase64(_aliceId), first);
    });

    test('reports false for a malformed key', () {
      final crypto = CryptoService();
      expect(crypto.pinKeyIfAbsent(_aliceId, 'not-a-key'), isFalse);
      expect(crypto.pinnedKeyBase64(_aliceId), isNull);
    });
  });
}
