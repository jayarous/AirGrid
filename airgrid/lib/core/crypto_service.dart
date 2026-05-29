import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// In-memory peer public-key cache and local encryption/decryption service.
///
/// Peer keys are populated from [key_announce] packets.  The local keypair
/// is loaded once at startup via [loadLocalKeyPair] and held in memory only.
///
/// Encryption uses X25519 key agreement + ChaCha20-Poly1305 AEAD.
/// Wire format: base64( nonce[12] ‖ cipherText[n] ‖ mac[16] ).
class CryptoService {
  static final _x25519 = X25519();
  static final _chacha = Chacha20.poly1305Aead();

  final Map<String, SimplePublicKey> _keyCache = {};
  SimpleKeyPairData? _localKeyPair;

  // ── Local keypair ────────────────────────────────────────────────────────

  /// Reconstructs and stores the local X25519 keypair from persisted bytes.
  /// Must be called before [encryptContent] or [decryptContent].
  Future<void> loadLocalKeyPair(
    String privateKeyB64,
    String publicKeyB64,
  ) async {
    final privateBytes = base64Decode(privateKeyB64);
    final publicBytes = base64Decode(publicKeyB64);
    _localKeyPair = SimpleKeyPairData(
      privateBytes,
      publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
  }

  /// True after [loadLocalKeyPair] has been called successfully.
  bool get hasLocalKeyPair => _localKeyPair != null;

  // ── Peer key cache ───────────────────────────────────────────────────────

  /// Caches the X25519 public key for [nodeId].
  ///
  /// Silently ignored if [base64PublicKey] is malformed or not exactly 32 bytes.
  void cacheKey(String nodeId, String base64PublicKey) {
    try {
      final bytes = base64Decode(base64PublicKey);
      if (bytes.length != 32) {
        if (kDebugMode) {
          debugPrint(
            '[CRYPTO] Invalid key for $nodeId: expected 32 bytes, got ${bytes.length}',
          );
        }
        return;
      }
      _keyCache[nodeId] = SimplePublicKey(bytes, type: KeyPairType.x25519);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[CRYPTO] Malformed key for $nodeId: $e');
      }
    }
  }

  /// Returns true if a public key is cached for [nodeId].
  bool hasKey(String nodeId) => _keyCache.containsKey(nodeId);

  /// Returns the cached [SimplePublicKey] for [nodeId], or null if unknown.
  SimplePublicKey? getPublicKey(String nodeId) => _keyCache[nodeId];

  /// All node IDs for which a public key is cached.
  Set<String> get knownNodeIds => Set.unmodifiable(_keyCache.keys);

  // ── Encryption ───────────────────────────────────────────────────────────

  /// Encrypts [plaintext] for [recipientNodeId] using the local keypair and
  /// the recipient's cached public key.
  ///
  /// Returns base64(nonce[12] ‖ cipherText ‖ mac[16]), or null if the local
  /// keypair is not loaded, the recipient key is unknown, or encryption fails.
  Future<String?> encryptContent(
    String plaintext,
    String recipientNodeId,
  ) async {
    final localKp = _localKeyPair;
    final theirKey = _keyCache[recipientNodeId];
    if (localKp == null || theirKey == null) return null;

    try {
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: localKp,
        remotePublicKey: theirKey,
      );
      final secretBox = await _chacha.encrypt(
        utf8.encode(plaintext),
        secretKey: sharedSecret,
      );
      final combined = Uint8List.fromList([
        ...secretBox.nonce,
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]);
      return base64Encode(combined);
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[CRYPTO] Encryption failed for recipient $recipientNodeId: $e',
        );
      }
      return null;
    }
  }

  // ── Decryption ───────────────────────────────────────────────────────────

  /// Decrypts [encryptedB64] (base64 wire format) sent by the node whose
  /// X25519 public key is [senderPublicKeyB64].
  ///
  /// Returns the plaintext string, or null if decryption fails for any reason
  /// (wrong key, truncated payload, authentication failure, etc.).
  Future<String?> decryptContent(
    String encryptedB64,
    String senderPublicKeyB64,
  ) async {
    final localKp = _localKeyPair;
    if (localKp == null) return null;

    try {
      final senderBytes = base64Decode(senderPublicKeyB64);
      if (senderBytes.length != 32) return null;
      final senderPublicKey = SimplePublicKey(
        senderBytes,
        type: KeyPairType.x25519,
      );

      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: localKp,
        remotePublicKey: senderPublicKey,
      );

      final combined = base64Decode(encryptedB64);
      // Minimum: 12-byte nonce + 0-byte ciphertext + 16-byte mac = 28 bytes.
      if (combined.length < 28) return null;

      final nonce = combined.sublist(0, 12).toList();
      final mac = Mac(combined.sublist(combined.length - 16).toList());
      final cipherText = combined.sublist(12, combined.length - 16).toList();

      final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
      final plainBytes = await _chacha.decrypt(
        secretBox,
        secretKey: sharedSecret,
      );
      return utf8.decode(plainBytes);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[CRYPTO] Decryption failed: $e');
      }
      return null;
    }
  }
}
