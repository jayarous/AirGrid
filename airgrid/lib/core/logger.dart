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

  static void log(LogCategory category, String message) {
    if (kDebugMode) {
      final ts = DateTime.now().toIso8601String();
      debugPrint('[$ts][${category.name.toUpperCase()}] $message');
    }
  }
}
