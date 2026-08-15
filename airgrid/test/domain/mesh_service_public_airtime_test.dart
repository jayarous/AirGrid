import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_transport.dart';
import '../helpers/test_node_ids.dart';

/// The airtime budget on public walkie broadcast.
///
/// Public walkie is free, so the paywall no longer decides who may flood the
/// mesh. `_outboundLimiter` cannot take over that job: it counts packets, so a
/// 96 KiB clip and a one-line chat message cost it the same token. These tests
/// pin the budget that actually bounds broadcast — charged in seconds of audio.
///
/// Every test starts from a full bucket (a fresh service per test) and a frozen
/// clock, so nothing refills unless a test advances time deliberately.
///
/// Clip counts here stay at or below `kOutboundMessageBurst` (10) on purpose.
/// Above that the packet limiter fires first and the assertions would be
/// measuring the wrong limiter — which is why each refusal asserts on the
/// message text rather than merely that *something* threw.
final _localNodeId = testNodeId('local');

Future<LocalIdentityStore> _makeIdentity() async {
  SharedPreferences.setMockInitialValues({
    'airgrid_node_id': _localNodeId,
    'airgrid_display_name': 'LocalUser',
  });
  FlutterSecureStorage.setMockInitialValues({});
  return LocalIdentityStore.create();
}

AudioAttachmentPayload _clip({required int? durationMs}) =>
    AudioAttachmentPayload(
      transferId: 'clip-$durationMs',
      mimeType: 'audio/m4a',
      byteLength: 4,
      durationMs: durationMs,
      source: AudioAttachmentPayload.sourceWalkie,
      dataBase64: base64Encode(Uint8List(4)),
    );

/// Matches the airtime refusal specifically, not the packet-rate one.
final _airtimeRefusal = throwsA(
  isA<StateError>().having(
    (e) => e.message,
    'message',
    contains('airtime'),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTransport transport;
  late AirGridMeshService mesh;
  late DateTime now;

  setUp(() async {
    now = DateTime(2026, 8, 15, 12, 0, 0);
    transport = FakeTransport();
    final identity = await _makeIdentity();
    final crypto = CryptoService();
    await crypto.loadLocalKeyPair(
      identity.privateKeyBase64!,
      identity.publicKeyBase64!,
    );

    mesh = AirGridMeshService(
      transport,
      identity,
      crypto,
      jitterOverrideMs: 0,
      spoolClock: () => now,
    );
    await Future<void>.delayed(Duration.zero);

    transport.connectPeer('ep-listener');
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await mesh.dispose();
  });

  group('public walkie airtime budget', () {
    test('a normal back-and-forth is not interrupted', () async {
      // Six 3s clips = 18s of the 20s burst. Ordinary conversation must not
      // hit the limiter at all, or the feature feels broken rather than
      // protected.
      for (var i = 0; i < 6; i++) {
        await mesh.sendPublicAudio(_clip(durationMs: 3000));
      }
    });

    test('a seventh three-second clip is refused', () async {
      for (var i = 0; i < 6; i++) {
        await mesh.sendPublicAudio(_clip(durationMs: 3000));
      }
      // 2s left, clip costs 3s.
      expect(() => mesh.sendPublicAudio(_clip(durationMs: 3000)),
          _airtimeRefusal);
    });

    test('waiting restores capacity in proportion to the wait', () async {
      for (var i = 0; i < 6; i++) {
        await mesh.sendPublicAudio(_clip(durationMs: 3000));
      }
      expect(() => mesh.sendPublicAudio(_clip(durationMs: 3000)),
          _airtimeRefusal);

      // 2s remaining + 0.2/s for 5s = 3s exactly.
      now = now.add(const Duration(seconds: 5));
      await mesh.sendPublicAudio(_clip(durationMs: 3000));
    });

    test('one long clip costs its full length', () async {
      await mesh.sendPublicAudio(
        _clip(durationMs: AirGridConstants.kWalkieMaxDuration.inMilliseconds),
      );
      // 20 - 15 = 5s left, so a 6s clip cannot follow.
      expect(() => mesh.sendPublicAudio(_clip(durationMs: 6000)),
          _airtimeRefusal);
    });

    test('a clip with no stated duration is charged the maximum', () async {
      // Fail closed. If this charged the 2s floor instead, 18s would remain
      // and the 6s clip below would sail through.
      await mesh.sendPublicAudio(_clip(durationMs: null));

      expect(() => mesh.sendPublicAudio(_clip(durationMs: 6000)),
          _airtimeRefusal);
    });

    test('very short clips are charged the floor, not their length', () async {
      // Eight 350ms clips: 16s if floored at 2s each, 2.8s if charged by
      // length. The 5s clip that follows discriminates between the two — it is
      // refused only if the floor was applied.
      //
      // Flood cost is per clip, not per second: each one is a fresh fragment
      // set relayed across every hop, so a machine-gun burst must not be
      // cheap.
      for (var i = 0; i < 8; i++) {
        await mesh.sendPublicAudio(
          _clip(
            durationMs: AirGridConstants.kWalkieMinDuration.inMilliseconds,
          ),
        );
      }

      expect(() => mesh.sendPublicAudio(_clip(durationMs: 5000)),
          _airtimeRefusal);
    });

    test('the refusal names a wait the caller can act on', () async {
      await mesh.sendPublicAudio(
        _clip(durationMs: AirGridConstants.kWalkieMaxDuration.inMilliseconds),
      );

      // 5s left, 15s wanted → 10s of refill at 0.2/s = 50s.
      // The message is the entire UX of being rate limited, so it must carry a
      // number rather than a bare "try later".
      expect(
        () => mesh.sendPublicAudio(
          _clip(durationMs: AirGridConstants.kWalkieMaxDuration.inMilliseconds),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('airtime'), contains('51s')),
          ),
        ),
      );
    });
  });
}
