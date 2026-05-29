import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'logger.dart';

/// Flutter-side bridge to the native [NearbyForegroundService].
///
/// Calls the [MethodChannel] injected into [MainActivity] to start and stop
/// the Android foreground service that keeps Nearby Connections alive.
///
/// All methods are no-ops on non-Android platforms so the rest of the codebase
/// stays platform-agnostic.
abstract interface class MeshForegroundService {
  Stream<void> get exitRequests;
  Future<void> startMeshService();
  Future<bool> consumePendingExitAction();
  Future<void> showPrivateMessageNotification(String senderName);
  Future<void> stopMeshService();
}

class ForegroundServiceBridge implements MeshForegroundService {
  const ForegroundServiceBridge();

  static const _channel = MethodChannel('com.airgrid/foreground');
  static final _exitController = StreamController<void>.broadcast();
  static bool _handlerInstalled = false;

  static Stream<void> get staticExitRequests {
    _ensureHandlerInstalled();
    return _exitController.stream;
  }

  static void _ensureHandlerInstalled() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'exitMesh') {
        _exitController.add(null);
        await _channel.invokeMethod<void>('ackExitAction');
      }
    });
  }

  @override
  Stream<void> get exitRequests => staticExitRequests;

  @override
  Future<void> startMeshService() => startMeshServiceStatic();

  @override
  Future<bool> consumePendingExitAction() => consumePendingExitActionStatic();

  @override
  Future<void> showPrivateMessageNotification(String senderName) =>
      showPrivateMessageNotificationStatic(senderName);

  @override
  Future<void> stopMeshService() => stopMeshServiceStatic();

  static Future<void> startMeshServiceStatic() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _ensureHandlerInstalled();
    try {
      await _channel.invokeMethod<void>('startMeshService');
      AirGridLogger.log(LogCategory.connection, 'Foreground service started');
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to start foreground service: ${e.message}',
      );
    }
  }

  static Future<bool> consumePendingExitActionStatic() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    _ensureHandlerInstalled();
    try {
      return await _channel.invokeMethod<bool>('consumePendingExitAction') ??
          false;
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to consume notification exit action: ${e.message}',
      );
      return false;
    }
  }

  static Future<void> showPrivateMessageNotificationStatic(
    String senderName,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('showPrivateMessageNotification', {
        'senderName': senderName,
      });
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to show private message notification: ${e.message}',
      );
    }
  }

  static Future<void> stopMeshServiceStatic() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('stopMeshService');
      AirGridLogger.log(LogCategory.connection, 'Foreground service stopped');
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to stop foreground service: ${e.message}',
      );
    }
  }
}
