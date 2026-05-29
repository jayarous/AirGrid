import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

/// A freshly generated X25519 identity for use in integration tests.
///
/// Call [generate] to create a node identity with a real keypair.
class CryptoTestIdentity {
  final String nodeId;
  final String displayName;
  final String privateKeyBase64;
  final String publicKeyBase64;

  const CryptoTestIdentity({
    required this.nodeId,
    required this.displayName,
    required this.privateKeyBase64,
    required this.publicKeyBase64,
  });

  /// Generates a fresh X25519 keypair and assigns a new UUID node ID.
  static Future<CryptoTestIdentity> generate(String displayName) async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    return CryptoTestIdentity(
      nodeId: const Uuid().v4(),
      displayName: displayName,
      privateKeyBase64: base64Encode(privateBytes),
      publicKeyBase64: base64Encode(publicKey.bytes),
    );
  }
}
