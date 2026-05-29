import 'dart:async';
import 'dart:convert';

import 'package:airgrid/domain/models/known_contact.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists and exposes the set of mesh peers whose identities are known.
///
/// Two implementations are provided:
/// - [SharedPrefsKnownContactStore] — production, backed by SharedPreferences.
/// - [InMemoryKnownContactStore] — ephemeral, used in tests and as the default
///   when no persistent store is injected.
abstract class KnownContactStore {
  /// Stream that emits the full contact list whenever it changes.
  Stream<List<KnownContact>> get contactsStream;

  /// Current snapshot of all known contacts.
  List<KnownContact> get contacts;

  /// Insert or update a contact.
  ///
  /// The in-memory state is always updated synchronously (no internal
  /// awaits) so callers may safely fire-and-forget via [unawaited].
  Future<void> upsert(KnownContact contact);

  /// Clears [lastEndpointId] for [nodeId] when a direct peer disconnects.
  Future<void> markOffline(String nodeId);

  /// Marks the contact identified by [nodeId] as blocked.
  ///
  /// Blocking is local-only and never communicated to the peer.
  /// Silently ignores an unknown or already-blocked [nodeId].
  Future<void> block(String nodeId);

  /// Removes the block for the contact identified by [nodeId].
  ///
  /// Silently ignores an unknown or already-unblocked [nodeId].
  Future<void> unblock(String nodeId);

  /// Returns true if the contact identified by [nodeId] is currently blocked.
  bool isBlocked(String nodeId);

  /// All contacts that are currently blocked.
  List<KnownContact> get blockedContacts;

  /// Marks the contact identified by [nodeId] as trusted.
  ///
  /// Trust is local-only and never communicated to the peer.
  /// Silently ignores an unknown or already-trusted [nodeId].
  Future<void> trust(String nodeId);

  /// Removes trust for the contact identified by [nodeId].
  ///
  /// Silently ignores an unknown or already-untrusted [nodeId].
  Future<void> untrust(String nodeId);

  /// Returns true if the contact identified by [nodeId] is currently trusted.
  bool isTrusted(String nodeId);

  /// All contacts that are currently trusted.
  List<KnownContact> get trustedContacts;

  /// Releases resources. Called from [AirGridMeshService.dispose].
  Future<void> dispose();
}

// ---------------------------------------------------------------------------

/// [SharedPreferences]-backed [KnownContactStore].
///
/// The in-memory map is always mutated synchronously; SharedPreferences writes
/// happen as best-effort background fire-and-forget.
class SharedPrefsKnownContactStore implements KnownContactStore {
  static const _prefsKey = 'airgrid_known_contacts';

  final SharedPreferences _prefs;
  final _contacts = <String, KnownContact>{};
  final _controller = StreamController<List<KnownContact>>.broadcast();

  SharedPrefsKnownContactStore._(this._prefs) {
    _loadFromPrefs();
  }

  static Future<SharedPrefsKnownContactStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPrefsKnownContactStore._(prefs);
  }

  void _loadFromPrefs() {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        final c = KnownContact.fromJson(item as Map<String, dynamic>);
        _contacts[c.nodeId] = c;
      }
      _emit();
    } catch (_) {
      // Corrupted data — start fresh.
    }
  }

  Future<void> _persist() async {
    final json = jsonEncode(_contacts.values.map((c) => c.toJson()).toList());
    await _prefs.setString(_prefsKey, json);
  }

  void _emit() => _controller.add(List.unmodifiable(_contacts.values.toList()));

  @override
  Stream<List<KnownContact>> get contactsStream => _controller.stream;

  @override
  List<KnownContact> get contacts =>
      List.unmodifiable(_contacts.values.toList());

  @override
  Future<void> upsert(KnownContact contact) async {
    final existing = _contacts[contact.nodeId];
    _contacts[contact.nodeId] = existing == null
        ? contact
        : contact.copyWith(
            lastEndpointId: contact.lastEndpointId ?? existing.lastEndpointId,
            isBlocked: existing.isBlocked,
            isTrusted: existing.isTrusted,
          );
    _emit();
    unawaited(_persist());
  }

  @override
  Future<void> markOffline(String nodeId) async {
    final c = _contacts[nodeId];
    if (c == null || c.lastEndpointId == null) return;
    _contacts[nodeId] = c.copyWith(clearEndpointId: true);
    _emit();
    unawaited(_persist());
  }

  @override
  Future<void> block(String nodeId) async {
    final c = _contacts[nodeId];
    if (c == null || c.isBlocked) return;
    _contacts[nodeId] = c.copyWith(isBlocked: true);
    _emit();
    unawaited(_persist());
  }

  @override
  Future<void> unblock(String nodeId) async {
    final c = _contacts[nodeId];
    if (c == null || !c.isBlocked) return;
    _contacts[nodeId] = c.copyWith(isBlocked: false);
    _emit();
    unawaited(_persist());
  }

  @override
  bool isBlocked(String nodeId) => _contacts[nodeId]?.isBlocked ?? false;

  @override
  List<KnownContact> get blockedContacts =>
      List.unmodifiable(_contacts.values.where((c) => c.isBlocked).toList());

  @override
  Future<void> trust(String nodeId) async {
    final c = _contacts[nodeId];
    if (c == null || c.isTrusted) return;
    _contacts[nodeId] = c.copyWith(isTrusted: true);
    _emit();
    unawaited(_persist());
  }

  @override
  Future<void> untrust(String nodeId) async {
    final c = _contacts[nodeId];
    if (c == null || !c.isTrusted) return;
    _contacts[nodeId] = c.copyWith(isTrusted: false);
    _emit();
    unawaited(_persist());
  }

  @override
  bool isTrusted(String nodeId) => _contacts[nodeId]?.isTrusted ?? false;

  @override
  List<KnownContact> get trustedContacts =>
      List.unmodifiable(_contacts.values.where((c) => c.isTrusted).toList());

  @override
  Future<void> dispose() async => _controller.close();
}

// ---------------------------------------------------------------------------

/// In-memory [KnownContactStore] — no persistence.
///
/// Used as the default implementation inside [AirGridMeshService] when no
/// external store is provided (i.e. unit tests and lightweight scenarios).
class InMemoryKnownContactStore implements KnownContactStore {
  final _contacts = <String, KnownContact>{};
  final _controller = StreamController<List<KnownContact>>.broadcast();

  void _emit() => _controller.add(List.unmodifiable(_contacts.values.toList()));

  @override
  Stream<List<KnownContact>> get contactsStream => _controller.stream;

  @override
  List<KnownContact> get contacts =>
      List.unmodifiable(_contacts.values.toList());

  @override
  Future<void> upsert(KnownContact contact) async {
    final existing = _contacts[contact.nodeId];
    _contacts[contact.nodeId] = existing == null
        ? contact
        : contact.copyWith(
            lastEndpointId: contact.lastEndpointId ?? existing.lastEndpointId,
            isBlocked: existing.isBlocked,
            isTrusted: existing.isTrusted,
          );
    _emit();
  }

  @override
  Future<void> markOffline(String nodeId) async {
    final c = _contacts[nodeId];
    if (c == null || c.lastEndpointId == null) return;
    _contacts[nodeId] = c.copyWith(clearEndpointId: true);
    _emit();
  }

  @override
  Future<void> block(String nodeId) async {
    final c = _contacts[nodeId];
    if (c == null || c.isBlocked) return;
    _contacts[nodeId] = c.copyWith(isBlocked: true);
    _emit();
  }

  @override
  Future<void> unblock(String nodeId) async {
    final c = _contacts[nodeId];
    if (c == null || !c.isBlocked) return;
    _contacts[nodeId] = c.copyWith(isBlocked: false);
    _emit();
  }

  @override
  bool isBlocked(String nodeId) => _contacts[nodeId]?.isBlocked ?? false;

  @override
  List<KnownContact> get blockedContacts =>
      List.unmodifiable(_contacts.values.where((c) => c.isBlocked).toList());

  @override
  Future<void> trust(String nodeId) async {
    final c = _contacts[nodeId];
    if (c == null || c.isTrusted) return;
    _contacts[nodeId] = c.copyWith(isTrusted: true);
    _emit();
  }

  @override
  Future<void> untrust(String nodeId) async {
    final c = _contacts[nodeId];
    if (c == null || !c.isTrusted) return;
    _contacts[nodeId] = c.copyWith(isTrusted: false);
    _emit();
  }

  @override
  bool isTrusted(String nodeId) => _contacts[nodeId]?.isTrusted ?? false;

  @override
  List<KnownContact> get trustedContacts =>
      List.unmodifiable(_contacts.values.where((c) => c.isTrusted).toList());

  @override
  Future<void> dispose() async => _controller.close();
}
