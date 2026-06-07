import 'package:airgrid/data/storage/rider_mode_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Rider Mode settings default to always-open trusted auto-join', () {
    const settings = RiderModeSettings();

    expect(settings.micMode, RiderMicMode.alwaysOpen);
    expect(settings.startPolicy, RiderStartPolicy.trustedAutoJoin);
    expect(settings.backgroundEnabled, isTrue);
  });

  test('in-memory Rider Mode settings store saves and emits updates', () async {
    final store = InMemoryRiderModeSettingsStore();
    final updates = <RiderModeSettings>[];
    final sub = store.settingsStream.listen(updates.add);

    final next = store.current.copyWith(
      micMode: RiderMicMode.voiceActivated,
      startPolicy: RiderStartPolicy.mutualStart,
      backgroundEnabled: false,
    );
    await store.save(next);

    expect(store.current.micMode, RiderMicMode.voiceActivated);
    expect(store.current.startPolicy, RiderStartPolicy.mutualStart);
    expect(store.current.backgroundEnabled, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(updates.single, next);

    await sub.cancel();
  });
}
