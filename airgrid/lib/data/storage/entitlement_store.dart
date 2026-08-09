import 'dart:async';
import 'dart:convert';

import 'package:airgrid/domain/models/entitlement.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the cached subscription entitlement.
///
/// The entitlement lives in [FlutterSecureStorage] because it carries a Play
/// purchase token; the "change notice already shown" marker lives in
/// [SharedPreferences] because it is not secret — the same split
/// `LocalIdentityStore` makes.
abstract interface class EntitlementStore {
  /// Synchronous access to the cached entitlement. Never blocks on billing.
  Entitlement get current;

  Stream<Entitlement> get entitlementStream;

  Future<void> save(Entitlement entitlement);

  /// Folds the result of a Play query into the cache and returns the result.
  ///
  /// Pass null when Play could not be reached. See the implementation note —
  /// null must never be treated as [Entitlement.free].
  Future<Entitlement> reconcile(Entitlement? fromPlay);

  /// App version whose "what's changed" notice has already been shown.
  String? get changeNoticeShownForVersion;

  Future<void> markChangeNoticeShown(String version);
}

/// The reconcile rule, shared by both implementations because getting it wrong
/// is the one bug that would break the offline promise.
mixin EntitlementReconciler implements EntitlementStore {
  /// Minimum ceiling advance worth a write.
  ///
  /// Without it the rollback ceiling would be persisted on every cold start.
  /// Someone who rolls the clock back gains at most this much unearned trust,
  /// which is not worth a storage write per launch.
  static const Duration ceilingWriteGranularity = Duration(hours: 1);

  /// Injected for tests; production passes `DateTime.now`.
  DateTime nowUtc();

  /// Keeps a known billing period when Play could not report one.
  ///
  /// The Android client is never told which base plan a purchase belongs to, so
  /// a Play-derived entitlement usually has no period. Carrying the cached one
  /// forward means a device that has not been wiped keeps its correct 30-day
  /// window instead of dropping to the 7-day floor.
  ///
  /// Guarded on a matching purchase token, so this only ever applies to
  /// demonstrably the same purchase. A plan change issues a new token, and the
  /// stale period is correctly discarded.
  static Entitlement carryForwardPeriod(
    Entitlement fromPlay,
    Entitlement cached,
  ) {
    if (fromPlay.period != null) return fromPlay;
    if (fromPlay.tier != EntitlementTier.plus) return fromPlay;
    if (cached.period == null) return fromPlay;
    final token = fromPlay.purchaseToken;
    if (token == null || token != cached.purchaseToken) return fromPlay;
    return fromPlay.copyWith(period: cached.period);
  }

  @override
  Future<Entitlement> reconcile(Entitlement? fromPlay) async {
    final now = nowUtc();

    if (fromPlay != null) {
      final verified = carryForwardPeriod(fromPlay, current).verifiedAt(now);
      await save(verified);
      return verified;
    }

    // Play could not be reached. Keep whatever is cached: downgrading here
    // would lock out every offline user, which is the single failure this
    // whole design exists to prevent.
    final cached = current;

    // A free user has no entitlement to protect from a clock change.
    if (cached.tier == EntitlementTier.free) return cached;

    final advanced = cached.observedAt(now);
    if (advanced == cached) return cached;

    final ceiling = cached.maxClockSeen;
    if (ceiling != null && now.difference(ceiling) < ceilingWriteGranularity) {
      // Ceiling moved, but not far enough to spend a write on.
      return cached;
    }

    await save(advanced);
    return advanced;
  }
}

class SecureEntitlementStore
    with EntitlementReconciler
    implements EntitlementStore {
  static const _secureKey = 'airgrid_secure_entitlement';
  static const _prefsNoticeKey = 'airgrid_entitlement_notice_version';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secureStorage;
  final DateTime Function() _clock;
  final _controller = StreamController<Entitlement>.broadcast();
  Entitlement _current;

  SecureEntitlementStore._(
    this._prefs,
    this._secureStorage,
    this._clock,
    this._current,
  );

  /// Async factory — use this to obtain an instance.
  ///
  /// Reconciles once against a null Play result so the rollback ceiling is
  /// seeded on every cold start, without ever waiting on the network.
  static Future<SecureEntitlementStore> create({
    DateTime Function()? clock,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    const secureStorage = FlutterSecureStorage(
      aOptions: AndroidOptions(
        encryptedSharedPreferences: true,
        resetOnError: true,
      ),
    );
    final raw = await _readSecure(secureStorage);
    final store = SecureEntitlementStore._(
      prefs,
      secureStorage,
      clock ?? DateTime.now,
      decode(raw),
    );
    await store.reconcile(null);
    return store;
  }

  /// Parses a persisted record, falling back to free.
  ///
  /// A corrupt record reads as free rather than throwing. That downgrades a
  /// paying user until the next successful Play query restores them, which is
  /// recoverable — whereas trusting unparseable data is not, and crashing at
  /// startup is worse than either.
  static Entitlement decode(String? raw) {
    if (raw == null || raw.isEmpty) return Entitlement.free;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return Entitlement.fromJson(decoded);
      }
    } catch (_) {
      // Fall through to free.
    }
    return Entitlement.free;
  }

  static Future<String?> _readSecure(FlutterSecureStorage storage) async {
    try {
      return await storage.read(key: _secureKey);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  DateTime nowUtc() => _clock().toUtc();

  @override
  Entitlement get current => _current;

  @override
  Stream<Entitlement> get entitlementStream => _controller.stream;

  @override
  Future<void> save(Entitlement entitlement) async {
    // In-memory first, and kept even if the write fails: a user who just
    // purchased must not be locked out because secure storage hiccuped.
    _current = entitlement;
    try {
      await _secureStorage.write(
        key: _secureKey,
        value: jsonEncode(entitlement.toJson()),
      );
    } on PlatformException {
      // Entitlement is re-derivable from Play on the next successful query.
    } on MissingPluginException {
      // Same, and this is the usual case in unit tests without the plugin.
    }
    _controller.add(_current);
  }

  @override
  String? get changeNoticeShownForVersion => _prefs.getString(_prefsNoticeKey);

  @override
  Future<void> markChangeNoticeShown(String version) =>
      _prefs.setString(_prefsNoticeKey, version);
}

/// Non-persistent store used as the provider default and in tests.
///
/// Defaulting to this rather than throwing means a forgotten override fails
/// closed to the free tier instead of crashing the app.
class InMemoryEntitlementStore
    with EntitlementReconciler
    implements EntitlementStore {
  final _controller = StreamController<Entitlement>.broadcast();
  final DateTime Function() _clock;
  Entitlement _current;
  String? _noticeVersion;

  InMemoryEntitlementStore({
    Entitlement initial = Entitlement.free,
    DateTime Function()? clock,
    String? changeNoticeShownForVersion,
  }) : _current = initial,
       _clock = clock ?? DateTime.now,
       _noticeVersion = changeNoticeShownForVersion;

  @override
  DateTime nowUtc() => _clock().toUtc();

  @override
  Entitlement get current => _current;

  @override
  Stream<Entitlement> get entitlementStream => _controller.stream;

  @override
  Future<void> save(Entitlement entitlement) async {
    _current = entitlement;
    _controller.add(_current);
  }

  @override
  String? get changeNoticeShownForVersion => _noticeVersion;

  @override
  Future<void> markChangeNoticeShown(String version) async {
    _noticeVersion = version;
  }
}
