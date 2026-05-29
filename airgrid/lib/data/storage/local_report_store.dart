import 'dart:convert';

import 'package:airgrid/domain/models/local_report.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists safety reports locally.
///
/// Reports are never sent to any server — export is manual via [exportText].
abstract class LocalReportStore {
  /// Append a new report.
  Future<void> add(LocalReport report);

  /// All stored reports, oldest first.
  Future<List<LocalReport>> listAll();

  /// Remove all stored reports.
  Future<void> clear();

  /// Returns all reports formatted as a single exportable plain-text string.
  Future<String> exportText();
}

// ---------------------------------------------------------------------------

/// [SharedPreferences]-backed [LocalReportStore].
class SharedPrefsLocalReportStore implements LocalReportStore {
  static const _prefsKey = 'airgrid_local_reports';

  final SharedPreferences _prefs;

  SharedPrefsLocalReportStore._(this._prefs);

  static Future<SharedPrefsLocalReportStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPrefsLocalReportStore._(prefs);
  }

  @override
  Future<void> add(LocalReport report) async {
    final existing = await listAll();
    existing.add(report);
    final encoded = jsonEncode(existing.map((r) => r.toJson()).toList());
    await _prefs.setString(_prefsKey, encoded);
  }

  @override
  Future<List<LocalReport>> listAll() async {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => LocalReport.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> clear() async {
    await _prefs.remove(_prefsKey);
  }

  @override
  Future<String> exportText() async {
    final reports = await listAll();
    if (reports.isEmpty) return 'No safety reports on this device.';
    final separator = '\n${'-' * 40}\n';
    return reports.map((r) => r.toReadableText()).join(separator);
  }
}

// ---------------------------------------------------------------------------

/// In-memory [LocalReportStore] — no persistence. Used in tests.
class InMemoryLocalReportStore implements LocalReportStore {
  final _reports = <LocalReport>[];

  @override
  Future<void> add(LocalReport report) async {
    _reports.add(report);
  }

  @override
  Future<List<LocalReport>> listAll() async => List.unmodifiable(_reports);

  @override
  Future<void> clear() async {
    _reports.clear();
  }

  @override
  Future<String> exportText() async {
    if (_reports.isEmpty) return 'No safety reports on this device.';
    final separator = '\n${'-' * 40}\n';
    return _reports.map((r) => r.toReadableText()).join(separator);
  }
}
