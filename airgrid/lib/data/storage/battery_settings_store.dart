import 'package:shared_preferences/shared_preferences.dart';

/// Persists battery behavior for mesh scanning.
abstract class BatterySettingsStore {
  /// Whether AirGrid should stop mesh activity when the app backgrounds.
  Future<bool> getBatteryOptimizationEnabled();

  /// Persist [enabled].
  Future<void> setBatteryOptimizationEnabled(bool enabled);

  /// Synchronous cached read, returning the last loaded/written value.
  bool get batteryOptimizationEnabled;
}

class SharedPrefsBatterySettingsStore implements BatterySettingsStore {
  static const _prefsKey = 'airgrid_battery_optimization_enabled';

  final SharedPreferences _prefs;
  bool _cached;

  SharedPrefsBatterySettingsStore._(this._prefs)
    : _cached = _prefs.getBool(_prefsKey) ?? false;

  static Future<SharedPrefsBatterySettingsStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPrefsBatterySettingsStore._(prefs);
  }

  @override
  Future<bool> getBatteryOptimizationEnabled() async => _cached;

  @override
  Future<void> setBatteryOptimizationEnabled(bool enabled) async {
    _cached = enabled;
    await _prefs.setBool(_prefsKey, enabled);
  }

  @override
  bool get batteryOptimizationEnabled => _cached;
}

class InMemoryBatterySettingsStore implements BatterySettingsStore {
  bool _enabled;

  InMemoryBatterySettingsStore({bool initialEnabled = false})
    : _enabled = initialEnabled;

  @override
  Future<bool> getBatteryOptimizationEnabled() async => _enabled;

  @override
  Future<void> setBatteryOptimizationEnabled(bool enabled) async {
    _enabled = enabled;
  }

  @override
  bool get batteryOptimizationEnabled => _enabled;
}
