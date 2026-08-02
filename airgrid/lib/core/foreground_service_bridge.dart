import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'logger.dart';

class PrivateMessageNotificationTap {
  final String peerNodeId;
  final String peerName;

  const PrivateMessageNotificationTap({
    required this.peerNodeId,
    required this.peerName,
  });
}

/// Flutter-side bridge to the native [NearbyForegroundService].
///
/// Calls the [MethodChannel] injected into [MainActivity] to start and stop
/// the Android foreground service that keeps Nearby Connections alive.
///
/// All methods are no-ops on non-Android platforms so the rest of the codebase
/// stays platform-agnostic.
abstract interface class MeshForegroundService {
  Stream<void> get exitRequests;
  Stream<PrivateMessageNotificationTap> get privateMessageNotificationTaps;
  Stream<void> get riderMuteRequests;
  Stream<void> get riderEndRequests;
  Future<void> startMeshService();
  Future<void> startRiderService({
    required String peerName,
    required bool muted,
  });
  Future<void> updateRiderServiceMuted(bool muted);
  Future<bool> consumePendingExitAction();
  Future<PrivateMessageNotificationTap?> consumePendingPrivateMessageTap();
  Future<void> showPrivateMessageNotification({
    required String peerNodeId,
    required String senderName,
  });
  Future<void> stopRiderService();
  Future<void> stopMeshService();
}

class ForegroundServiceBridge implements MeshForegroundService {
  const ForegroundServiceBridge();

  static const _channel = MethodChannel('com.airgrid/foreground');
  static final _exitController = StreamController<void>.broadcast();
  static final _privateMessageTapController =
      StreamController<PrivateMessageNotificationTap>.broadcast();
  static final _riderMuteController = StreamController<void>.broadcast();
  static final _riderEndController = StreamController<void>.broadcast();
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
      if (call.method == 'privateMessageNotificationTapped') {
        final tap = _privateMessageTapFromMap(call.arguments);
        if (tap != null) {
          _privateMessageTapController.add(tap);
          await _channel.invokeMethod<void>('ackPrivateMessageNotificationTap');
        }
      }
      if (call.method == 'riderMute') {
        _riderMuteController.add(null);
      }
      if (call.method == 'riderEnd') {
        _riderEndController.add(null);
      }
    });
  }

  @override
  Stream<void> get exitRequests => staticExitRequests;

  @override
  Stream<PrivateMessageNotificationTap> get privateMessageNotificationTaps {
    _ensureHandlerInstalled();
    return _privateMessageTapController.stream;
  }

  @override
  Stream<void> get riderMuteRequests {
    _ensureHandlerInstalled();
    return _riderMuteController.stream;
  }

  @override
  Stream<void> get riderEndRequests {
    _ensureHandlerInstalled();
    return _riderEndController.stream;
  }

  @override
  Future<void> startMeshService() => startMeshServiceStatic();

  @override
  Future<void> startRiderService({
    required String peerName,
    required bool muted,
  }) => startRiderServiceStatic(peerName: peerName, muted: muted);

  @override
  Future<void> updateRiderServiceMuted(bool muted) =>
      updateRiderServiceMutedStatic(muted);

  @override
  Future<bool> consumePendingExitAction() => consumePendingExitActionStatic();

  @override
  Future<PrivateMessageNotificationTap?> consumePendingPrivateMessageTap() =>
      consumePendingPrivateMessageTapStatic();

  @override
  Future<void> showPrivateMessageNotification({
    required String peerNodeId,
    required String senderName,
  }) => showPrivateMessageNotificationStatic(
    peerNodeId: peerNodeId,
    senderName: senderName,
  );

  @override
  Future<void> stopRiderService() => stopRiderServiceStatic();

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

  static Future<void> startRiderServiceStatic({
    required String peerName,
    required bool muted,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _ensureHandlerInstalled();
    try {
      await _channel.invokeMethod<void>('startRiderService', {
        'peerName': peerName,
        'muted': muted,
      });
      AirGridLogger.log(LogCategory.connection, 'Rider service started');
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to start Rider service: ${e.message}',
      );
    }
  }

  static Future<void> updateRiderServiceMutedStatic(bool muted) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('updateRiderServiceMuted', {
        'muted': muted,
      });
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to update Rider service: ${e.message}',
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

  static Future<PrivateMessageNotificationTap?>
  consumePendingPrivateMessageTapStatic() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    _ensureHandlerInstalled();
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'consumePendingPrivateMessageTap',
      );
      return _privateMessageTapFromMap(result);
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to consume private message notification tap: ${e.message}',
      );
      return null;
    }
  }

  static Future<void> showPrivateMessageNotificationStatic({
    required String peerNodeId,
    required String senderName,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('showPrivateMessageNotification', {
        'peerNodeId': peerNodeId,
        'senderName': senderName,
      });
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to show private message notification: ${e.message}',
      );
    }
  }

  static PrivateMessageNotificationTap? _privateMessageTapFromMap(
    Object? value,
  ) {
    if (value is! Map) return null;
    final peerNodeId = value['peerNodeId'] as String?;
    if (peerNodeId == null || peerNodeId.isEmpty) return null;
    final peerName = value['peerName'] as String? ?? 'Private chat';
    return PrivateMessageNotificationTap(
      peerNodeId: peerNodeId,
      peerName: peerName,
    );
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

  static Future<void> stopRiderServiceStatic() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('stopRiderService');
      AirGridLogger.log(LogCategory.connection, 'Rider service stopped');
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to stop Rider service: ${e.message}',
      );
    }
  }
}
