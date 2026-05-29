import 'package:airgrid/data/storage/battery_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults battery optimization to enabled', () async {
    final store = await SharedPrefsBatterySettingsStore.create();

    expect(await store.getBatteryOptimizationEnabled(), isTrue);
    expect(store.batteryOptimizationEnabled, isTrue);
  });

  test('persists battery optimization setting', () async {
    final store = await SharedPrefsBatterySettingsStore.create();

    await store.setBatteryOptimizationEnabled(false);
    final reopened = await SharedPrefsBatterySettingsStore.create();

    expect(store.batteryOptimizationEnabled, isFalse);
    expect(await reopened.getBatteryOptimizationEnabled(), isFalse);
  });
}
