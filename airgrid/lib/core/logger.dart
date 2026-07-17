import 'package:flutter/foundation.dart';

enum LogCategory {
  discovery,
  advertising,
  connection,
  routing,
  dedup,
  rebroadcast,
  permission,
  validation,
  storage,
  crypto,
}

class AirGridLogger {
  AirGridLogger._();

  static const int _maxEntries = 120;
  static final List<String> _recentEntries = <String>[];

  static void log(LogCategory category, String message) {
    final ts = DateTime.now().toIso8601String();
    final entry = '[$ts][${category.name.toUpperCase()}] $message';
    _recentEntries.add(entry);
    if (_recentEntries.length > _maxEntries) {
      _recentEntries.removeRange(0, _recentEntries.length - _maxEntries);
    }
    if (kDebugMode) {
      debugPrint(entry);
    }
  }

  static List<String> recentEntries() => List.unmodifiable(_recentEntries);
}
