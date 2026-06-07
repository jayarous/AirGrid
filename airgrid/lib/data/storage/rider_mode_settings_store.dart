import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum RiderMicMode { alwaysOpen, voiceActivated }

enum RiderStartPolicy { trustedAutoJoin, mutualStart }

class RiderModeSettings {
  final RiderMicMode micMode;
  final RiderStartPolicy startPolicy;
  final bool backgroundEnabled;

  const RiderModeSettings({
    this.micMode = RiderMicMode.alwaysOpen,
    this.startPolicy = RiderStartPolicy.trustedAutoJoin,
    this.backgroundEnabled = true,
  });

  RiderModeSettings copyWith({
    RiderMicMode? micMode,
    RiderStartPolicy? startPolicy,
    bool? backgroundEnabled,
  }) {
    return RiderModeSettings(
      micMode: micMode ?? this.micMode,
      startPolicy: startPolicy ?? this.startPolicy,
      backgroundEnabled: backgroundEnabled ?? this.backgroundEnabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'micMode': micMode.name,
    'startPolicy': startPolicy.name,
    'backgroundEnabled': backgroundEnabled,
  };

  factory RiderModeSettings.fromJson(Map<String, dynamic> json) {
    RiderMicMode micMode = RiderMicMode.alwaysOpen;
    RiderStartPolicy startPolicy = RiderStartPolicy.trustedAutoJoin;

    final micRaw = json['micMode'] as String?;
    if (micRaw != null) {
      micMode = RiderMicMode.values.firstWhere(
        (v) => v.name == micRaw,
        orElse: () => RiderMicMode.alwaysOpen,
      );
    }

    final policyRaw = json['startPolicy'] as String?;
    if (policyRaw != null) {
      startPolicy = RiderStartPolicy.values.firstWhere(
        (v) => v.name == policyRaw,
        orElse: () => RiderStartPolicy.trustedAutoJoin,
      );
    }

    return RiderModeSettings(
      micMode: micMode,
      startPolicy: startPolicy,
      backgroundEnabled: json['backgroundEnabled'] as bool? ?? true,
    );
  }
}

abstract interface class RiderModeSettingsStore {
  RiderModeSettings get current;
  Stream<RiderModeSettings> get settingsStream;
  Future<void> save(RiderModeSettings settings);
}

class SharedPrefsRiderModeSettingsStore implements RiderModeSettingsStore {
  static const _prefsKey = 'airgrid_rider_mode_settings';

  final SharedPreferences _prefs;
  final _controller = StreamController<RiderModeSettings>.broadcast();
  RiderModeSettings _current;

  SharedPrefsRiderModeSettingsStore._(this._prefs, this._current);

  static Future<SharedPrefsRiderModeSettingsStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPrefsRiderModeSettingsStore._(
      prefs,
      _readSettings(prefs.getString(_prefsKey)),
    );
  }

  static RiderModeSettings _readSettings(String? raw) {
    if (raw == null || raw.isEmpty) return const RiderModeSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return RiderModeSettings.fromJson(decoded);
      }
    } catch (_) {
      // Fall through to defaults.
    }
    return const RiderModeSettings();
  }

  @override
  RiderModeSettings get current => _current;

  @override
  Stream<RiderModeSettings> get settingsStream => _controller.stream;

  @override
  Future<void> save(RiderModeSettings settings) async {
    _current = settings;
    await _prefs.setString(_prefsKey, jsonEncode(settings.toJson()));
    _controller.add(_current);
  }
}

class InMemoryRiderModeSettingsStore implements RiderModeSettingsStore {
  final _controller = StreamController<RiderModeSettings>.broadcast();
  RiderModeSettings _current;

  InMemoryRiderModeSettingsStore({
    RiderModeSettings initial = const RiderModeSettings(),
  }) : _current = initial;

  @override
  RiderModeSettings get current => _current;

  @override
  Stream<RiderModeSettings> get settingsStream => _controller.stream;

  @override
  Future<void> save(RiderModeSettings settings) async {
    _current = settings;
    _controller.add(_current);
  }
}
