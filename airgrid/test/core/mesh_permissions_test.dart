import 'package:airgrid/core/mesh_permissions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  group('MeshPermissions', () {
    test('uses location as the critical permission before Android 12', () {
      expect(MeshPermissions.criticalPermissionsForAndroidSdk(28), [
        Permission.location,
      ]);
    });

    test('uses Bluetooth and location runtime permissions on Android 12', () {
      expect(MeshPermissions.criticalPermissionsForAndroidSdk(31), [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.location,
      ]);
    });

    test(
      'uses Bluetooth, Nearby Wi-Fi, and location runtime permissions on Android 13+',
      () {
        expect(
          MeshPermissions.criticalPermissionsForAndroidSdk(33),
          MeshPermissions.criticalPermissions,
        );
      },
    );
  });
}
