import 'package:airgrid/core/play_services_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlayServicesBridge.channel, null);
  });

  test('checkAvailability parses native status payload', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlayServicesBridge.channel, (call) async {
          expect(call.method, 'checkPlayServices');
          return <String, Object>{
            'available': false,
            'code': 'outdated',
            'message': 'Google Play Services is out of date.',
            'canResolve': true,
          };
        });

    const bridge = PlayServicesBridge();
    final status = await bridge.checkAvailability();

    expect(status.available, isFalse);
    expect(status.code, 'outdated');
    expect(status.canResolve, isTrue);
    expect(status.displayMessage, contains('out of date'));
  });

  test('resolve calls native resolver only when status can resolve', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlayServicesBridge.channel, (call) async {
          calls.add(call);
          return true;
        });

    const bridge = PlayServicesBridge();
    final opened = await bridge.resolve(
      const PlayServicesStatus(
        available: false,
        code: 'disabled',
        message: 'Disabled',
        canResolve: true,
      ),
    );

    expect(opened, isTrue);
    expect(calls.single.method, 'resolvePlayServices');
  });
}
