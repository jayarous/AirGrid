import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/logger.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:cryptography/cryptography.dart';

/// In-memory peer public-key cache and local encryption/decryption service.
///
/// Peer keys are populated from [key_announce] packets.  The local keypair
/// is loaded once at startup via [loadLocalKeyPair] and held in memory only.
///
/// Encryption uses X25519 key agreement + ChaCha20-Poly1305 AEAD.
/// Wire format: base64( nonce[12] ‖ cipherText[n] ‖ mac[16] ).
///
/// Since [kEncryptionVersion] 2 the packet header is bound into the AEAD as
/// associated data (see [associatedData]), so a ciphertext only authenticates
/// under the message id, sender, recipient, type and timestamp it was sent
/// with. Re-sending an observed ciphertext under a fresh message id fails the
/// MAC instead of showing up as a new message.
class CryptoService {
  static final _x25519 = X25519();
  static final _chacha = Chacha20.poly1305Aead();
  static final _sha256 = Sha256();

  // ── Wire versions ────────────────────────────────────────────────────────

  /// Version 1: content-only AEAD, no associated data. Produced by builds up
  /// to 1.0.14. Still accepted inbound so a peer on an older build can keep
  /// talking during the rollout; never produced any more. Drop inbound
  /// support once production has moved past 1.0.14.
  static const int kLegacyEncryptionVersion = 1;

  /// Version 2: the packet header is authenticated as associated data.
  static const int kEncryptionVersion = 2;

  /// True for every version this build can decrypt.
  static bool isSupportedEncryptionVersion(int? version) =>
      version == kEncryptionVersion || version == kLegacyEncryptionVersion;

  /// The associated data that binds a ciphertext to its packet header.
  ///
  /// Every field here is one a relay could otherwise rewrite without touching
  /// the ciphertext. The recipient is included so a packet encrypted to one
  /// node cannot be re-addressed, and the timestamp so an old packet cannot
  /// be refreshed. The version prefix keeps a future layout from colliding.
  static Uint8List associatedData({
    required String messageId,
    required String senderNodeId,
    required String? recipientNodeId,
    required String packetType,
    required int timestamp,
  }) => Uint8List.fromList(
    utf8.encode(
      'airgrid/v$kEncryptionVersion\u0000$messageId\u0000$senderNodeId'
      '\u0000${recipientNodeId ?? ''}\u0000$packetType\u0000$timestamp',
    ),
  );

  /// Associated data for [packet], or none when its version predates AAD.
  ///
  /// Fragments carry the original header on the reassembled packet, so this
  /// is evaluated on whole packets only.
  static List<int> associatedDataFor(AirGridPacket packet) {
    if (packet.encryptionVersion != kEncryptionVersion) return const <int>[];
    return associatedData(
      messageId: packet.messageId,
      senderNodeId: packet.senderNodeId,
      recipientNodeId: packet.recipientNodeId,
      packetType: packet.packetType,
      timestamp: packet.timestamp,
    );
  }

  // ── Key fingerprints ─────────────────────────────────────────────────────

  /// SHA-256 fingerprint of a base64 X25519 public key, formatted for humans
  /// to read aloud or compare on screen: 16 uppercase hex chars in groups of
  /// four, e.g. `A1B2 C3D4 E5F6 0718`.
  ///
  /// Truncated to 64 bits deliberately: long enough that forging a match is
  /// impractical for an opportunistic attacker, short enough that two people
  /// will actually compare it. Verification is out-of-band — the mesh cannot
  /// vouch for a key it has only ever learned over the mesh.
  ///
  /// Returns null when [publicKeyBase64] is empty or not valid base64.
  static Future<String?> fingerprint(String publicKeyBase64) async {
    if (publicKeyBase64.isEmpty) return null;
    final Uint8List bytes;
    try {
      bytes = base64Decode(publicKeyBase64);
    } on FormatException {
      return null;
    }
    final digest = await _sha256.hash(bytes);
    final hex = digest.bytes
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return RegExp(r'.{1,4}').allMatches(hex).map((m) => m.group(0)!).join(' ');
  }

  final Map<String, SimplePublicKey> _keyCache = {};
  final Map<String, Future<SecretKey>> _sharedSecretCache = {};
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
        AirGridLogger.log(
          LogCategory.crypto,
          'Ignored peer key with invalid length during cache update',
        );
        return;
      }
      _keyCache[nodeId] = SimplePublicKey(bytes, type: KeyPairType.x25519);
      _sharedSecretCache.remove(nodeId);
    } catch (_) {
      AirGridLogger.log(
        LogCategory.crypto,
        'Ignored malformed peer key during cache update',
      );
    }
  }

  /// Caches [base64PublicKey] for [nodeId] only when nothing is cached yet.
  ///
  /// This is the trust-on-first-use path for a data packet that arrives
  /// before the sender's key_announce. A key that is already pinned is never
  /// replaced here: that decision belongs to key-announce handling, which
  /// surfaces the change to the user instead of silently swapping keys.
  ///
  /// Returns true when [nodeId] has a usable key afterwards.
  bool pinKeyIfAbsent(String nodeId, String base64PublicKey) {
    if (!hasKey(nodeId)) cacheKey(nodeId, base64PublicKey);
    return hasKey(nodeId);
  }

  /// Returns true if a public key is cached for [nodeId].
  bool hasKey(String nodeId) => _keyCache.containsKey(nodeId);

  /// The cached public key for [nodeId] as base64, or null if unknown.
  String? pinnedKeyBase64(String nodeId) {
    final key = _keyCache[nodeId];
    return key == null ? null : base64Encode(key.bytes);
  }

  /// Returns the cached [SimplePublicKey] for [nodeId], or null if unknown.
  SimplePublicKey? getPublicKey(String nodeId) => _keyCache[nodeId];

  /// All node IDs for which a public key is cached.
  Set<String> get knownNodeIds => Set.unmodifiable(_keyCache.keys);

  Future<SecretKey?> _sharedSecretFor(String nodeId) async {
    final localKp = _localKeyPair;
    final theirKey = _keyCache[nodeId];
    if (localKp == null || theirKey == null) return null;
    return _sharedSecretCache.putIfAbsent(
      nodeId,
      () =>
          _x25519.sharedSecretKey(keyPair: localKp, remotePublicKey: theirKey),
    );
  }

  // ── Encryption ───────────────────────────────────────────────────────────

  /// Encrypts [plaintext] for [recipientNodeId] using the local keypair and
  /// the recipient's cached public key.
  ///
  /// [aad] is authenticated but not encrypted; the recipient must present the
  /// same bytes to decrypt. Callers sending [kEncryptionVersion] packets pass
  /// [associatedData] for the header they are about to send under.
  ///
  /// Returns base64(nonce[12] ‖ cipherText ‖ mac[16]), or null if the local
  /// keypair is not loaded, the recipient key is unknown, or encryption fails.
  Future<String?> encryptContent(
    String plaintext,
    String recipientNodeId, {
    List<int> aad = const <int>[],
  }) async {
    return encryptBytes(
      Uint8List.fromList(utf8.encode(plaintext)),
      recipientNodeId,
      aad: aad,
    );
  }

  Future<String?> encryptBytes(
    Uint8List plaintext,
    String recipientNodeId, {
    List<int> aad = const <int>[],
  }) async {
    final sharedSecret = await _sharedSecretFor(recipientNodeId);
    if (sharedSecret == null) return null;

    try {
      final secretBox = await _chacha.encrypt(
        plaintext,
        secretKey: sharedSecret,
        aad: aad,
      );
      final combined = Uint8List.fromList([
        ...secretBox.nonce,
        ...secretBox.cipherText,
        ...secretBox.mac.bytes,
      ]);
      return base64Encode(combined);
    } catch (_) {
      AirGridLogger.log(
        LogCategory.crypto,
        'Encryption failed for recipient due to cryptographic operation error',
      );
      return null;
    }
  }

  // ── Decryption ───────────────────────────────────────────────────────────

  /// Decrypts [encryptedB64] (base64 wire format) sent by the node whose
  /// X25519 public key is [senderPublicKeyB64].
  ///
  /// [senderPublicKeyB64] must be the key *pinned* for the sender, not the
  /// one the packet carries: a packet's own key proves only that someone
  /// holds that key, not that they are the node id on the header.
  ///
  /// [aad] must match what the sender authenticated, byte for byte.
  ///
  /// Returns the plaintext string, or null if decryption fails for any reason
  /// (wrong key, truncated payload, authentication failure, etc.).
  Future<String?> decryptContent(
    String encryptedB64,
    String senderPublicKeyB64, {
    List<int> aad = const <int>[],
  }) async {
    final plainBytes = await decryptBytes(
      encryptedB64,
      senderPublicKeyB64,
      aad: aad,
    );
    if (plainBytes == null) return null;
    try {
      return utf8.decode(plainBytes);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> decryptBytes(
    String encryptedB64,
    String senderPublicKeyB64, {
    List<int> aad = const <int>[],
  }) async {
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
        aad: aad,
      );
      return Uint8List.fromList(plainBytes);
    } catch (_) {
      AirGridLogger.log(
        LogCategory.crypto,
        'Decryption failed due to invalid payload or key mismatch',
      );
      return null;
    }
  }
}
