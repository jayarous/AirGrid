import 'dart:convert';

import 'package:airgrid/core/crypto_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Creates two CryptoService instances that know each other's public keys and
/// have their local keypairs loaded, simulating two peers.
Future<(CryptoService alice, CryptoService bob)> _makePair() async {
  final algorithm = X25519();

  final aliceKp = await algorithm.newKeyPair();
  final alicePub = await aliceKp.extractPublicKey();
  final alicePriv = await aliceKp.extractPrivateKeyBytes();

  final bobKp = await algorithm.newKeyPair();
  final bobPub = await bobKp.extractPublicKey();
  final bobPriv = await bobKp.extractPrivateKeyBytes();

  final alice = CryptoService();
  await alice.loadLocalKeyPair(
    base64Encode(alicePriv),
    base64Encode(alicePub.bytes),
  );
  alice.cacheKey('bob', base64Encode(bobPub.bytes));

  final bob = CryptoService();
  await bob.loadLocalKeyPair(base64Encode(bobPriv), base64Encode(bobPub.bytes));
  bob.cacheKey('alice', base64Encode(alicePub.bytes));

  return (alice, bob);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('CryptoService — key cache', () {
    late CryptoService service;

    setUp(() {
      service = CryptoService();
    });

    test('hasKey returns false for unknown node', () {
      expect(service.hasKey('unknown-node'), isFalse);
    });

    test('getPublicKey returns null for unknown node', () {
      expect(service.getPublicKey('unknown-node'), isNull);
    });

    test('cacheKey stores a valid X25519 public key', () async {
      final algorithm = X25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final encoded = base64Encode(publicKey.bytes);

      service.cacheKey('node-1', encoded);

      expect(service.hasKey('node-1'), isTrue);
    });

    test('getPublicKey returns the cached key with correct bytes', () async {
      final algorithm = X25519();
      final keyPair = await algorithm.newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final encoded = base64Encode(publicKey.bytes);

      service.cacheKey('node-2', encoded);
      final retrieved = service.getPublicKey('node-2');

      expect(retrieved, isNotNull);
      expect(retrieved!.bytes, equals(publicKey.bytes));
    });

    test('caches keys for multiple distinct nodes independently', () async {
      final algorithm = X25519();

      final kp1 = await algorithm.newKeyPair();
      final pub1 = await kp1.extractPublicKey();

      final kp2 = await algorithm.newKeyPair();
      final pub2 = await kp2.extractPublicKey();

      service.cacheKey('node-a', base64Encode(pub1.bytes));
      service.cacheKey('node-b', base64Encode(pub2.bytes));

      expect(service.hasKey('node-a'), isTrue);
      expect(service.hasKey('node-b'), isTrue);
      expect(service.getPublicKey('node-a')!.bytes, equals(pub1.bytes));
      expect(service.getPublicKey('node-b')!.bytes, equals(pub2.bytes));
    });

    test('knownNodeIds contains all cached nodes', () async {
      final algorithm = X25519();

      final kp = await algorithm.newKeyPair();
      final pub = await kp.extractPublicKey();
      final encoded = base64Encode(pub.bytes);

      service.cacheKey('node-x', encoded);
      service.cacheKey('node-y', encoded);

      expect(service.knownNodeIds, containsAll(['node-x', 'node-y']));
    });

    test('cacheKey silently ignores malformed base64 key', () {
      expect(
        () => service.cacheKey('bad-node', 'not-valid-base64!!!'),
        returnsNormally,
      );
      expect(service.hasKey('bad-node'), isFalse);
    });

    test('cacheKey rejects valid base64 that is not exactly 32 bytes', () {
      final shortKey = base64Encode(List.filled(31, 0));
      service.cacheKey('short-node', shortKey);
      expect(service.hasKey('short-node'), isFalse);

      final longKey = base64Encode(List.filled(33, 0));
      service.cacheKey('long-node', longKey);
      expect(service.hasKey('long-node'), isFalse);
    });

    test('later cacheKey overwrites earlier entry for same nodeId', () async {
      final algorithm = X25519();

      final kp1 = await algorithm.newKeyPair();
      final pub1 = await kp1.extractPublicKey();

      final kp2 = await algorithm.newKeyPair();
      final pub2 = await kp2.extractPublicKey();

      service.cacheKey('node-rotate', base64Encode(pub1.bytes));
      service.cacheKey('node-rotate', base64Encode(pub2.bytes));

      final retrieved = service.getPublicKey('node-rotate');
      expect(retrieved!.bytes, equals(pub2.bytes));
    });
  });

  // ── Encryption / Decryption ────────────────────────────────────────────────

  group('CryptoService — encrypt / decrypt', () {
    test('encrypt returns null when local keypair not loaded', () async {
      final service = CryptoService();
      final algorithm = X25519();
      final kp = await algorithm.newKeyPair();
      final pub = await kp.extractPublicKey();
      service.cacheKey('peer', base64Encode(pub.bytes));

      final result = await service.encryptContent('hello', 'peer');
      expect(result, isNull);
    });

    test('encrypt returns null when recipient key not cached', () async {
      final (alice, _) = await _makePair();

      final result = await alice.encryptContent('hello', 'unknown-node');
      expect(result, isNull);
    });

    test('round-trip: encrypt then decrypt recovers plaintext', () async {
      final (alice, bob) = await _makePair();

      final cipher = await alice.encryptContent('Hello, Bob!', 'bob');
      expect(cipher, isNotNull);

      // Bob decrypts using Alice's public key (populated by _makePair).
      final alicePubKey = bob.getPublicKey('alice')!;
      final plain = await bob.decryptContent(
        cipher!,
        base64Encode(alicePubKey.bytes),
      );
      expect(plain, equals('Hello, Bob!'));
    });

    test('decrypt returns null for wrong sender key', () async {
      final (alice, bob) = await _makePair();

      final cipher = await alice.encryptContent('secret', 'bob');
      expect(cipher, isNotNull);

      // Use a random wrong key instead of Alice's real public key.
      final wrongKp = await X25519().newKeyPair();
      final wrongPub = await wrongKp.extractPublicKey();
      final plain = await bob.decryptContent(
        cipher!,
        base64Encode(wrongPub.bytes),
      );
      expect(plain, isNull);
    });

    test('decrypt returns null when local keypair not loaded', () async {
      final (alice, _) = await _makePair();
      final bobKp = await X25519().newKeyPair();
      final bobPub = await bobKp.extractPublicKey();
      alice.cacheKey('bob-fresh', base64Encode(bobPub.bytes));

      final cipher = await alice.encryptContent('hi', 'bob-fresh');
      expect(cipher, isNotNull);

      // Bob2 has no local keypair loaded.
      final bob2 = CryptoService();
      final alicePubKey = alice.getPublicKey('bob-fresh')!;
      final result = await bob2.decryptContent(
        cipher!,
        base64Encode(alicePubKey.bytes),
      );
      expect(result, isNull);
    });

    test('decrypt returns null for truncated ciphertext', () async {
      final (alice, bob) = await _makePair();

      final cipher = await alice.encryptContent('data', 'bob');
      // Truncate to fewer than 28 bytes (nonce + mac minimum).
      final truncated = base64Encode(base64Decode(cipher!).sublist(0, 10));

      final alicePubKey = bob.getPublicKey('alice')!;
      final plain = await bob.decryptContent(
        truncated,
        base64Encode(alicePubKey.bytes),
      );
      expect(plain, isNull);
    });

    test('encrypted output is different from plaintext input', () async {
      final (alice, _) = await _makePair();

      final plaintext = 'Hello mesh!';
      final cipher = await alice.encryptContent(plaintext, 'bob');

      expect(cipher, isNotNull);
      expect(cipher, isNot(equals(plaintext)));
    });

    test(
      'two encryptions of the same plaintext produce different ciphertexts',
      () async {
        // ChaCha20-Poly1305 uses a random nonce, so outputs must differ.
        final (alice, _) = await _makePair();

        final cipher1 = await alice.encryptContent('same', 'bob');
        final cipher2 = await alice.encryptContent('same', 'bob');

        expect(cipher1, isNotNull);
        expect(cipher2, isNotNull);
        expect(cipher1, isNot(equals(cipher2)));
      },
    );
  });
}
