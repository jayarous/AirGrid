import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BatteryOptimizationBridge {
  const BatteryOptimizationBridge._();

  static const _channel = MethodChannel('com.airgrid/battery_optimization');

  static Future<bool> openSystemBatteryOptimizationSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    try {
      return await _channel.invokeMethod<bool>(
            'openSystemBatteryOptimizationSettings',
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
