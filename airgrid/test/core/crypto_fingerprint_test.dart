import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/crypto_service.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fingerprints exist so two people can compare a key out-of-band. The mesh
/// learns keys over the mesh, so it can never vouch for them itself.
void main() {
  String keyOf(int fill) => base64Encode(Uint8List(32)..fillRange(0, 32, fill));

  group('CryptoService.fingerprint', () {
    test('is stable for the same key', () async {
      final a = await CryptoService.fingerprint(keyOf(7));
      final b = await CryptoService.fingerprint(keyOf(7));

      expect(a, isNotNull);
      expect(a, b);
    });

    test('differs for different keys', () async {
      final a = await CryptoService.fingerprint(keyOf(1));
      final b = await CryptoService.fingerprint(keyOf(2));

      expect(a, isNot(b));
    });

    test('is formatted as four groups of four uppercase hex chars', () async {
      final fp = await CryptoService.fingerprint(keyOf(0));

      expect(fp, matches(RegExp(r'^[0-9A-F]{4}( [0-9A-F]{4}){3}$')));
    });

    test('returns null for empty or malformed input', () async {
      expect(await CryptoService.fingerprint(''), isNull);
      expect(await CryptoService.fingerprint('not base64 !!!'), isNull);
    });

    test('works on a real generated X25519 public key', () async {
      final kp = await X25519().newKeyPair();
      final pub = await kp.extractPublicKey();

      final fp = await CryptoService.fingerprint(base64Encode(pub.bytes));

      expect(fp, isNotNull);
      expect(fp!.replaceAll(' ', '').length, 16);
    });
  });
}
