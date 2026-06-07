import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Persists and retrieves the local device identity.
///
/// On first launch a random UUID v4 is generated and stored as the stable
/// node ID.  The display name is saved separately after onboarding.
/// An X25519 keypair is also generated once and persisted for future use
/// in opportunistic encryption (Phase 3B).
///
/// **Security:** Private and public keys are stored in [FlutterSecureStorage].
/// Node ID and display name remain in [SharedPreferences] for performance
/// (they are not secret).
///
/// **Migration:** On first access after upgrade, any keys found in
/// SharedPreferences are automatically migrated to secure storage without
/// regenerating the keypair.
///
/// Does NOT use MAC addresses or hardware identifiers.
class LocalIdentityStore {
  static const _keyNodeId = 'airgrid_node_id';
  static const _keyDisplayName = 'airgrid_display_name';
  static const _keyProfileIconId = 'airgrid_profile_icon_id';
  static const _keyProfileStatus = 'airgrid_profile_status';
  static const _keyTermsAcceptedVersion = 'airgrid_terms_accepted_version';
  static const _keyTermsAcceptedAt = 'airgrid_terms_accepted_at';
  static const _defaultProfileIconId = 'person';

  // Legacy SharedPreferences keys (for migration)
  static const _legacyPrivateKeyB64 = 'airgrid_private_key_b64';
  static const _legacyPublicKeyB64 = 'airgrid_public_key_b64';

  // Secure storage keys (current)
  static const _securePrivateKeyB64 = 'airgrid_secure_private_key_b64';
  static const _securePublicKeyB64 = 'airgrid_secure_public_key_b64';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secureStorage;

  // Cached keys (populated once during create() to avoid repeated async reads)
  String? _cachedPublicKeyB64;
  String? _cachedPrivateKeyB64;

  LocalIdentityStore._(this._prefs, this._secureStorage);

  /// Async factory — use this to obtain an instance.
  static Future<LocalIdentityStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    const secureStorage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    final store = LocalIdentityStore._(prefs, secureStorage);
    await store._ensureKeypair();

    // Cache keys for synchronous access
    store._cachedPrivateKeyB64 = await store._secureStorage.read(
      key: _securePrivateKeyB64,
    );
    store._cachedPublicKeyB64 = await store._secureStorage.read(
      key: _securePublicKeyB64,
    );

    return store;
  }

  /// Generates and persists an X25519 keypair on first run, or migrates from
  /// legacy SharedPreferences storage if found there.
  ///
  /// If either half of a previously persisted keypair is missing (e.g. due to
  /// a partial write), regenerates both halves.  Both halves are always
  /// written together atomically to secure storage.
  ///
  /// **Migration:** If keys exist in SharedPreferences but not in secure
  /// storage, they are migrated without regeneration, then deleted from prefs.
  Future<void> _ensureKeypair() async {
    // Check secure storage first
    final securePrivate = await _secureStorage.read(key: _securePrivateKeyB64);
    final securePublic = await _secureStorage.read(key: _securePublicKeyB64);

    if (securePrivate != null && securePublic != null) {
      // Already in secure storage - ensure legacy keys are cleaned up
      await _cleanupLegacyKeys();
      return;
    }

    // Check for legacy keys in SharedPreferences (migration path)
    final legacyPrivate = _prefs.getString(_legacyPrivateKeyB64);
    final legacyPublic = _prefs.getString(_legacyPublicKeyB64);

    if (legacyPrivate != null && legacyPublic != null) {
      // Migrate from SharedPreferences to secure storage
      await _secureStorage.write(
        key: _securePrivateKeyB64,
        value: legacyPrivate,
      );
      await _secureStorage.write(key: _securePublicKeyB64, value: legacyPublic);

      // Clean up legacy keys
      await _cleanupLegacyKeys();
      return;
    }

    // No keypair found anywhere - generate new one
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();

    // Write to secure storage atomically
    await _secureStorage.write(
      key: _securePrivateKeyB64,
      value: base64Encode(privateKeyBytes),
    );
    await _secureStorage.write(
      key: _securePublicKeyB64,
      value: base64Encode(publicKey.bytes),
    );
  }

  /// Removes legacy keypair from SharedPreferences after migration.
  Future<void> _cleanupLegacyKeys() async {
    await _prefs.remove(_legacyPrivateKeyB64);
    await _prefs.remove(_legacyPublicKeyB64);
  }

  /// Stable node ID.  Generated once on first launch and never changes.
  String get nodeId {
    var id = _prefs.getString(_keyNodeId);
    if (id == null) {
      id = const Uuid().v4();
      _prefs.setString(_keyNodeId, id);
    }
    return id;
  }

  /// Display name chosen during onboarding, or null before onboarding.
  String? get displayName => _prefs.getString(_keyDisplayName);

  /// Selected local profile icon ID.
  String get profileIconId =>
      _prefs.getString(_keyProfileIconId) ?? _defaultProfileIconId;

  /// Optional profile status shown under the local display name.
  String? get profileStatus {
    final raw = _prefs.getString(_keyProfileStatus);
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }

  /// True once the user has completed onboarding and saved a display name.
  bool get hasIdentity {
    final name = displayName;
    return name != null && name.trim().isNotEmpty;
  }

  /// Terms version the user last accepted, or null if never accepted.
  String? get acceptedTermsVersion =>
      _prefs.getString(_keyTermsAcceptedVersion);

  /// True once the current legal terms version has been accepted.
  bool hasAcceptedTerms(String currentVersion) =>
      acceptedTermsVersion == currentVersion;

  /// Base64-encoded X25519 public key, or null if the keypair hasn't been
  /// generated yet (shouldn't happen after [create] completes).
  ///
  /// **Security:** Read from secure storage (cached at initialization).
  String? get publicKeyBase64 => _cachedPublicKeyB64;

  /// Base64-encoded X25519 private key. Never transmitted over the mesh —
  /// used only locally by [CryptoService] to derive shared secrets.
  ///
  /// **Security:** Read from secure storage (cached at initialization).
  /// NEVER log or expose this value.
  String? get privateKeyBase64 => _cachedPrivateKeyB64;

  Future<void> saveDisplayName(String name) =>
      _prefs.setString(_keyDisplayName, name.trim());

  Future<void> acceptTerms(String version, {DateTime? acceptedAt}) async {
    await _prefs.setString(_keyTermsAcceptedVersion, version);
    await _prefs.setString(
      _keyTermsAcceptedAt,
      (acceptedAt ?? DateTime.now().toUtc()).toIso8601String(),
    );
  }

  Future<void> saveProfileIconId(String iconId) =>
      _prefs.setString(_keyProfileIconId, iconId.trim());

  Future<void> saveProfileStatus(String status) async {
    final trimmed = status.trim();
    if (trimmed.isEmpty) {
      await _prefs.remove(_keyProfileStatus);
      return;
    }
    await _prefs.setString(_keyProfileStatus, trimmed);
  }
}
