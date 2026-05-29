import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'logger.dart';

class PlayServicesStatus {
  final bool available;
  final String code;
  final String message;
  final bool canResolve;

  const PlayServicesStatus({
    required this.available,
    required this.code,
    required this.message,
    required this.canResolve,
  });

  const PlayServicesStatus.available()
    : available = true,
      code = 'available',
      message = 'Google Play Services is available.',
      canResolve = false;

  const PlayServicesStatus.unsupported({
    this.code = 'unsupported',
    this.message =
        'Nearby Connections is not supported because Google Play Services is unavailable on this device.',
  }) : available = false,
       canResolve = false;

  factory PlayServicesStatus.fromMap(Map<Object?, Object?> map) {
    return PlayServicesStatus(
      available: map['available'] == true,
      code: (map['code'] as String?) ?? 'unknown',
      message:
          (map['message'] as String?) ??
          'Google Play Services availability is unknown.',
      canResolve: map['canResolve'] == true,
    );
  }

  String get displayMessage {
    if (available) return message;
    return switch (code) {
      'missing' =>
        'Google Play Services is missing. Nearby Connections cannot start until it is installed.',
      'disabled' =>
        'Google Play Services is disabled. Enable it to use Nearby Connections.',
      'outdated' =>
        'Google Play Services is out of date. Update it to use Nearby Connections.',
      'updating' =>
        'Google Play Services is updating. Wait a moment, then try again.',
      'unsupported' =>
        'This device does not support the Google Play Services required for Nearby Connections.',
      _ => message,
    };
  }
}

abstract interface class PlayServicesAvailability {
  Future<PlayServicesStatus> checkAvailability();
  Future<bool> resolve(PlayServicesStatus status);
}

class PlayServicesBridge implements PlayServicesAvailability {
  static const channel = MethodChannel('com.airgrid/play_services');

  const PlayServicesBridge();

  @override
  Future<PlayServicesStatus> checkAvailability() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const PlayServicesStatus.available();
    }

    try {
      final raw = await channel.invokeMapMethod<Object?, Object?>(
        'checkPlayServices',
      );
      if (raw == null) {
        return const PlayServicesStatus.unsupported(
          code: 'unknown',
          message: 'Google Play Services status could not be checked.',
        );
      }
      final status = PlayServicesStatus.fromMap(raw);
      AirGridLogger.log(
        LogCategory.connection,
        'Play Services status: ${status.code}, available=${status.available}',
      );
      return status;
    } on MissingPluginException {
      return const PlayServicesStatus.available();
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to check Play Services: ${e.message}',
      );
      return PlayServicesStatus.unsupported(
        code: 'unknown',
        message: e.message ?? 'Google Play Services status is unavailable.',
      );
    }
  }

  @override
  Future<bool> resolve(PlayServicesStatus status) async {
    if (!status.canResolve || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    try {
      return await channel.invokeMethod<bool>('resolvePlayServices', {
            'code': status.code,
          }) ??
          false;
    } on PlatformException catch (e) {
      AirGridLogger.log(
        LogCategory.connection,
        'Failed to resolve Play Services: ${e.message}',
      );
      return false;
    }
  }
}
