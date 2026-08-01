import 'dart:convert';

import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Setup mock secure storage for testing
  FlutterSecureStorage.setMockInitialValues({});

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('LocalIdentityStore - Fresh Identity', () {
    test('generates new keypair on first run', () async {
      final store = await LocalIdentityStore.create();

      expect(store.nodeId, isNotEmpty);
      expect(store.publicKeyBase64, isNotNull);
      expect(store.privateKeyBase64, isNotNull);
      expect(store.publicKeyBase64!.length, greaterThan(40));
      expect(store.privateKeyBase64!.length, greaterThan(40));
    });

    test('generates stable node ID (UUID v4 format)', () async {
      final store = await LocalIdentityStore.create();
      final nodeId = store.nodeId;

      // UUID v4 format: 8-4-4-4-12 hex with hyphens
      final uuidPattern = RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      );
      expect(uuidPattern.hasMatch(nodeId), isTrue);
    });

    test('node ID persists across restarts', () async {
      final store1 = await LocalIdentityStore.create();
      final nodeId1 = store1.nodeId;

      final store2 = await LocalIdentityStore.create();
      final nodeId2 = store2.nodeId;

      expect(nodeId2, equals(nodeId1));
    });

    test('keypair persists across restarts', () async {
      final store1 = await LocalIdentityStore.create();
      final pub1 = store1.publicKeyBase64;
      final priv1 = store1.privateKeyBase64;

      final store2 = await LocalIdentityStore.create();
      final pub2 = store2.publicKeyBase64;
      final priv2 = store2.privateKeyBase64;

      expect(pub2, equals(pub1));
      expect(priv2, equals(priv1));
    });

    test('hasIdentity is false before onboarding', () async {
      final store = await LocalIdentityStore.create();
      expect(store.hasIdentity, isFalse);
      expect(store.displayName, isNull);
    });

    test('hasIdentity is true after saving display name', () async {
      final store = await LocalIdentityStore.create();
      await store.saveDisplayName('Alice');

      expect(store.hasIdentity, isTrue);
      expect(store.displayName, equals('Alice'));
    });

    test('display name is trimmed when saved', () async {
      final store = await LocalIdentityStore.create();
      await store.saveDisplayName('  Bob  ');

      expect(store.displayName, equals('Bob'));
    });
  });

  group('LocalIdentityStore - Migration from SharedPreferences', () {
    test('migrates legacy keys to secure storage', () async {
      // Simulate legacy keys in SharedPreferences
      SharedPreferences.setMockInitialValues({
        'airgrid_private_key_b64': 'legacy_private_key_abc123',
        'airgrid_public_key_b64': 'legacy_public_key_xyz789',
        'airgrid_node_id': 'legacy-node-id-12345',
        'airgrid_display_name': 'Legacy User',
      });

      final store = await LocalIdentityStore.create();

      // Keys should be migrated to secure storage
      expect(store.publicKeyBase64, equals('legacy_public_key_xyz789'));
      expect(store.privateKeyBase64, equals('legacy_private_key_abc123'));

      // Node ID and display name should remain accessible
      expect(store.nodeId, equals('legacy-node-id-12345'));
      expect(store.displayName, equals('Legacy User'));
    });

    test('migration does NOT regenerate keys', () async {
      const legacyPrivate = 'original_private_key_should_not_change';
      const legacyPublic = 'original_public_key_should_not_change';

      SharedPreferences.setMockInitialValues({
        'airgrid_private_key_b64': legacyPrivate,
        'airgrid_public_key_b64': legacyPublic,
      });

      final store = await LocalIdentityStore.create();

      // Keys MUST match legacy keys exactly (no regeneration)
      expect(store.publicKeyBase64, equals(legacyPublic));
      expect(store.privateKeyBase64, equals(legacyPrivate));
    });

    test(
      'legacy keys are removed from SharedPreferences after migration',
      () async {
        SharedPreferences.setMockInitialValues({
          'airgrid_private_key_b64': 'legacy_private',
          'airgrid_public_key_b64': 'legacy_public',
        });

        await LocalIdentityStore.create();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('airgrid_private_key_b64'), isNull);
        expect(prefs.getString('airgrid_public_key_b64'), isNull);
      },
    );

    test('migration only happens once', () async {
      SharedPreferences.setMockInitialValues({
        'airgrid_private_key_b64': 'legacy_private',
        'airgrid_public_key_b64': 'legacy_public',
      });

      final store1 = await LocalIdentityStore.create();
      final pub1 = store1.publicKeyBase64;

      // Second create should use secure storage, not legacy keys
      final store2 = await LocalIdentityStore.create();
      final pub2 = store2.publicKeyBase64;

      expect(pub2, equals(pub1));

      // Legacy keys should still be cleaned up
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('airgrid_private_key_b64'), isNull);
    });
  });

  group('LocalIdentityStore - Missing Key Recovery', () {
    test('regenerates keypair if only private key is missing', () async {
      // Simulate partial legacy state (only public key exists)
      SharedPreferences.setMockInitialValues({
        'airgrid_public_key_b64': 'orphaned_public_key',
      });

      final store = await LocalIdentityStore.create();

      // Should generate NEW keypair (not use orphaned public key)
      expect(store.publicKeyBase64, isNotNull);
      expect(store.privateKeyBase64, isNotNull);
      expect(store.publicKeyBase64, isNot(equals('orphaned_public_key')));
    });

    test('regenerates keypair if only public key is missing', () async {
      // Simulate partial legacy state (only private key exists)
      SharedPreferences.setMockInitialValues({
        'airgrid_private_key_b64': 'orphaned_private_key',
      });

      final store = await LocalIdentityStore.create();

      // Should generate NEW keypair (not use orphaned private key)
      expect(store.publicKeyBase64, isNotNull);
      expect(store.privateKeyBase64, isNotNull);
      expect(store.privateKeyBase64, isNot(equals('orphaned_private_key')));
    });

    test('regenerates keypair if secure storage has partial keys', () async {
      // Simulate partial secure storage state (only public key)
      FlutterSecureStorage.setMockInitialValues({
        'airgrid_secure_public_key_b64': 'orphaned_secure_public',
      });

      final store = await LocalIdentityStore.create();

      // Should generate NEW keypair (both keys must exist)
      expect(store.publicKeyBase64, isNotNull);
      expect(store.privateKeyBase64, isNotNull);
      expect(store.publicKeyBase64, isNot(equals('orphaned_secure_public')));
    });
  });

  group('LocalIdentityStore - Secure Storage Verification', () {
    test('keys are stored in secure storage, not SharedPreferences', () async {
      final store = await LocalIdentityStore.create();
      final publicKey = store.publicKeyBase64;
      final privateKey = store.privateKeyBase64;

      final prefs = await SharedPreferences.getInstance();

      // Keys should NOT be in SharedPreferences
      expect(prefs.getString('airgrid_private_key_b64'), isNull);
      expect(prefs.getString('airgrid_public_key_b64'), isNull);
      expect(prefs.getString('airgrid_secure_private_key_b64'), isNull);
      expect(prefs.getString('airgrid_secure_public_key_b64'), isNull);

      // Keys should be accessible through store (cached from secure storage)
      expect(publicKey, isNotNull);
      expect(privateKey, isNotNull);
    });

    test('node ID remains in SharedPreferences (not secret)', () async {
      final store = await LocalIdentityStore.create();
      final nodeId = store.nodeId;

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('airgrid_node_id'), equals(nodeId));
    });

    test('display name remains in SharedPreferences', () async {
      final store = await LocalIdentityStore.create();
      await store.saveDisplayName('Charlie');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('airgrid_display_name'), equals('Charlie'));
    });
  });

  group('LocalIdentityStore - Edge Cases', () {
    test('handles empty display name trimming', () async {
      final store = await LocalIdentityStore.create();
      await store.saveDisplayName('   ');

      // hasIdentity should be false for whitespace-only name
      expect(store.hasIdentity, isFalse);
    });

    test('multiple instances share same identity', () async {
      final store1 = await LocalIdentityStore.create();
      await store1.saveDisplayName('User1');

      final store2 = await LocalIdentityStore.create();

      expect(store2.nodeId, equals(store1.nodeId));
      expect(store2.publicKeyBase64, equals(store1.publicKeyBase64));
      expect(store2.privateKeyBase64, equals(store1.privateKeyBase64));
      expect(store2.displayName, equals('User1'));
    });

    test('keypair is valid base64', () async {
      final store = await LocalIdentityStore.create();

      // Should not throw when decoding
      expect(() => base64Decode(store.publicKeyBase64!), returnsNormally);
      expect(() => base64Decode(store.privateKeyBase64!), returnsNormally);
    });

    test('keypair bytes are 32 bytes (X25519 key size)', () async {
      final store = await LocalIdentityStore.create();

      final pubBytes = base64Decode(store.publicKeyBase64!);
      final privBytes = base64Decode(store.privateKeyBase64!);

      expect(pubBytes.length, equals(32));
      expect(privBytes.length, equals(32));
    });
  });
}
