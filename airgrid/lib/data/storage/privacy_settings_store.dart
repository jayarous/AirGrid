import 'package:airgrid/domain/models/privacy_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's chosen [PrivacyMode].
abstract class PrivacySettingsStore {
  /// Load the current mode. Returns [PrivacyMode.everyoneNearby] if unset.
  Future<PrivacyMode> getPrivacyMode();

  /// Persist [mode].
  Future<void> setPrivacyMode(PrivacyMode mode);

  /// Synchronous cached read — returns the last value written/loaded.
  PrivacyMode get currentMode;
}

// ---------------------------------------------------------------------------

/// [SharedPreferences]-backed [PrivacySettingsStore].
class SharedPrefsPrivacySettingsStore implements PrivacySettingsStore {
  static const _prefsKey = 'airgrid_privacy_mode';

  final SharedPreferences _prefs;
  PrivacyMode _cached;

  SharedPrefsPrivacySettingsStore._(this._prefs)
      : _cached = _load(_prefs);

  static PrivacyMode _load(SharedPreferences prefs) {
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return PrivacyMode.everyoneNearby;
    return PrivacyMode.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => PrivacyMode.everyoneNearby,
    );
  }

  static Future<SharedPrefsPrivacySettingsStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPrefsPrivacySettingsStore._(prefs);
  }

  @override
  Future<PrivacyMode> getPrivacyMode() async {
    return _cached;
  }

  @override
  Future<void> setPrivacyMode(PrivacyMode mode) async {
    _cached = mode;
    await _prefs.setString(_prefsKey, mode.name);
  }

  @override
  PrivacyMode get currentMode => _cached;
}

// ---------------------------------------------------------------------------

/// In-memory [PrivacySettingsStore] — no persistence. Used in tests.
class InMemoryPrivacySettingsStore implements PrivacySettingsStore {
  PrivacyMode _mode;

  InMemoryPrivacySettingsStore({PrivacyMode initialMode = PrivacyMode.everyoneNearby})
      : _mode = initialMode;

  @override
  Future<PrivacyMode> getPrivacyMode() async => _mode;

  @override
  Future<void> setPrivacyMode(PrivacyMode mode) async {
    _mode = mode;
  }

  @override
  PrivacyMode get currentMode => _mode;
}
