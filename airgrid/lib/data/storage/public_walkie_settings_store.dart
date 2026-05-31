import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the user wants public walkie audio to keep playing while
/// navigating away from the walkie screen.
abstract class PublicWalkieSettingsStore {
  Future<bool> getStayOnlineEnabled();

  Future<void> setStayOnlineEnabled(bool enabled);

  bool get currentStayOnlineEnabled;
}

class SharedPrefsPublicWalkieSettingsStore
    implements PublicWalkieSettingsStore {
  static const _prefsKey = 'airgrid_public_walkie_stay_online';

  final SharedPreferences _prefs;
  bool _cached;

  SharedPrefsPublicWalkieSettingsStore._(this._prefs)
      : _cached = _prefs.getBool(_prefsKey) ?? false;

  static Future<SharedPrefsPublicWalkieSettingsStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPrefsPublicWalkieSettingsStore._(prefs);
  }

  @override
  Future<bool> getStayOnlineEnabled() async => _cached;

  @override
  Future<void> setStayOnlineEnabled(bool enabled) async {
    _cached = enabled;
    await _prefs.setBool(_prefsKey, enabled);
  }

  @override
  bool get currentStayOnlineEnabled => _cached;
}

class InMemoryPublicWalkieSettingsStore implements PublicWalkieSettingsStore {
  bool _enabled;

  InMemoryPublicWalkieSettingsStore({bool initialEnabled = false})
      : _enabled = initialEnabled;

  @override
  Future<bool> getStayOnlineEnabled() async => _enabled;

  @override
  Future<void> setStayOnlineEnabled(bool enabled) async {
    _enabled = enabled;
  }

  @override
  bool get currentStayOnlineEnabled => _enabled;
}