import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

class MeshPermissionsSnapshot {
  final Map<Permission, PermissionStatus> statuses;
  final List<Permission> criticalPermissions;

  const MeshPermissionsSnapshot(
    this.statuses, {
    this.criticalPermissions = MeshPermissions.criticalPermissions,
  });

  bool get hasMissingCriticalPermissions =>
      criticalPermissions.any((permission) {
        final status = statuses[permission];
        return status == null || status.isDenied || status.isPermanentlyDenied;
      });

  bool get hasPermanentlyDenied =>
      statuses.values.any((status) => status.isPermanentlyDenied);

  bool isGranted(Permission permission) =>
      statuses[permission]?.isGranted ?? false;

  PermissionStatus? operator [](Permission permission) => statuses[permission];
}

class MeshPermissions {
  const MeshPermissions();

  static const _platformChannel = MethodChannel('com.airgrid/platform');

  static const criticalPermissions = <Permission>[
    Permission.bluetoothScan,
    Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
    Permission.nearbyWifiDevices,
  ];

  static const optionalPermissions = <Permission>[
    Permission.location,
    Permission.notification,
    Permission.ignoreBatteryOptimizations,
  ];

  static const allPermissions = <Permission>[
    ...criticalPermissions,
    ...optionalPermissions,
  ];

  static List<Permission> criticalPermissionsForAndroidSdk(int sdkInt) {
    if (sdkInt >= 33) {
      return criticalPermissions;
    }
    if (sdkInt >= 31) {
      return const [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ];
    }
    return const [Permission.location];
  }

  Future<MeshPermissionsSnapshot> checkStatuses() async {
    final statuses = <Permission, PermissionStatus>{};
    for (final permission in allPermissions) {
      statuses[permission] = await permission.status;
    }
    final criticalPermissions = await _criticalPermissionsForCurrentPlatform();
    return MeshPermissionsSnapshot(
      statuses,
      criticalPermissions: criticalPermissions,
    );
  }

  Future<MeshPermissionsSnapshot> requestMeshPermissions() async {
    final statuses = await allPermissions.request();
    final criticalPermissions = await _criticalPermissionsForCurrentPlatform();
    return MeshPermissionsSnapshot(
      statuses,
      criticalPermissions: criticalPermissions,
    );
  }

  Future<List<Permission>> _criticalPermissionsForCurrentPlatform() async {
    if (!Platform.isAndroid) {
      return criticalPermissions;
    }
    final sdkInt = await _androidSdkInt();
    return criticalPermissionsForAndroidSdk(sdkInt);
  }

  Future<int> _androidSdkInt() async {
    try {
      return await _platformChannel.invokeMethod<int>('androidSdkInt') ?? 33;
    } on PlatformException {
      return 33;
    } on MissingPluginException {
      return 33;
    }
  }

  String labelFor(Permission permission) {
    if (permission == Permission.bluetoothScan) {
      return 'Bluetooth scan';
    }
    if (permission == Permission.bluetoothAdvertise) {
      return 'Bluetooth advertise';
    }
    if (permission == Permission.bluetoothConnect) {
      return 'Bluetooth connect';
    }
    if (permission == Permission.nearbyWifiDevices) {
      return 'Nearby Wi-Fi devices';
    }
    if (permission == Permission.location) {
      return 'Location';
    }
    if (permission == Permission.notification) {
      return 'Notifications';
    }
    if (permission == Permission.ignoreBatteryOptimizations) {
      return 'Ignore battery optimizations';
    }
    return permission.toString();
  }

  String descriptionFor(Permission permission) {
    if (permission == Permission.bluetoothScan) {
      return 'Find nearby devices';
    }
    if (permission == Permission.bluetoothAdvertise) {
      return 'Broadcast your presence';
    }
    if (permission == Permission.bluetoothConnect) {
      return 'Connect to peers';
    }
    if (permission == Permission.nearbyWifiDevices) {
      return 'Use nearby Wi-Fi radios';
    }
    if (permission == Permission.location) {
      return 'Enable discovery and optional nearby distance';
    }
    if (permission == Permission.notification) {
      return 'Show foreground service alerts';
    }
    if (permission == Permission.ignoreBatteryOptimizations) {
      return 'Allow mesh to stay active reliably in background';
    }
    return 'Permission';
  }
}

final meshPermissionsProvider = Provider<MeshPermissions>(
  (ref) => const MeshPermissions(),
);
