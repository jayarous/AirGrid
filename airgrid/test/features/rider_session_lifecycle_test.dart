import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/rider_tones.dart';
import 'package:airgrid/domain/models/rider_mode_event.dart';
import 'package:airgrid/features/rider/rider_link_health.dart';
import 'package:airgrid/features/rider/rider_mode_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('rider control wire compatibility', () {
    test('known actions round-trip', () {
      for (final action in RiderControlAction.values) {
        final wire = RiderControlPayload(
          action: action,
          sessionId: 'session-1',
        ).toWire();

        final decoded = RiderControlPayload.fromWire(wire);
        expect(decoded, isNotNull, reason: 'failed for ${action.name}');
        expect(decoded!.action, action);
        expect(decoded.sessionId, 'session-1');
      }
    });

    test('an unknown action is dropped rather than coerced to invite', () {
      final wire = jsonEncode({
        'kind': 'rider_control',
        'action': 'some_future_action',
        'sessionId': 'session-1',
      });

      // Coercing would pop an unsolicited invite prompt mid-ride.
      expect(RiderControlPayload.fromWire(wire), isNull);
    });

    test('a keepalive is ignored by the control parser', () {
      // This is what a build shipped before keepalives existed does with one:
      // it only has the control parser, gets null, and drops the packet.
      final wire = const RiderKeepalivePayload(sessionId: 'session-1').toWire();

      expect(RiderControlPayload.fromWire(wire), isNull);
    });

    test('a control packet is ignored by the keepalive parser', () {
      final wire = const RiderControlPayload(
        action: RiderControlAction.end,
        sessionId: 'session-1',
      ).toWire();

      expect(RiderKeepalivePayload.fromWire(wire), isNull);
    });

    test('keepalive round-trips and rejects a missing session', () {
      final wire = const RiderKeepalivePayload(sessionId: 'session-7').toWire();
      expect(RiderKeepalivePayload.fromWire(wire)?.sessionId, 'session-7');

      expect(
        RiderKeepalivePayload.fromWire(
          jsonEncode({'kind': 'rider_keepalive', 'sessionId': ''}),
        ),
        isNull,
      );
      expect(RiderKeepalivePayload.fromWire('not json'), isNull);
    });
  });

  group('rider link watchdog thresholds', () {
    test('recent traffic is healthy', () {
      expect(riderLinkHealthFor(Duration.zero), RiderLinkHealth.healthy);
      expect(
        riderLinkHealthFor(riderPeerStaleAfter - const Duration(seconds: 1)),
        RiderLinkHealth.healthy,
      );
    });

    test('an overdue peer is stale but not yet dropped', () {
      expect(riderLinkHealthFor(riderPeerStaleAfter), RiderLinkHealth.stale);
      expect(
        riderLinkHealthFor(riderPeerLostAfter - const Duration(seconds: 1)),
        RiderLinkHealth.stale,
      );
    });

    test('a long silence is treated as lost', () {
      expect(riderLinkHealthFor(riderPeerLostAfter), RiderLinkHealth.lost);
      expect(
        riderLinkHealthFor(const Duration(minutes: 5)),
        RiderLinkHealth.lost,
      );
    });

    test('stale fires before lost', () {
      expect(riderPeerStaleAfter, lessThan(riderPeerLostAfter));
    });
  });

  group('rider ended-session state', () {
    test('the ended reason and peer name travel together', () {
      const ended = RiderModeState(
        endedReason: RiderSessionEndReason.peerLost,
        endedPeerName: 'Alex',
      );

      expect(ended.endedReason, RiderSessionEndReason.peerLost);
      expect(ended.endedPeerName, 'Alex');
    });

    test('starting a new session clears both', () {
      const ended = RiderModeState(
        endedReason: RiderSessionEndReason.endedByPeer,
        endedPeerName: 'Alex',
      );

      // The panel must not caption a live session with why the last one died.
      final restarted = ended.copyWith(isActive: true, clearEndedReason: true);

      expect(restarted.endedReason, isNull);
      expect(restarted.endedPeerName, isNull);
    });

    test('the peer name survives teardown clearing peerName', () {
      const live = RiderModeState(
        isActive: true,
        peerNodeId: 'node-1',
        peerName: 'Alex',
      );

      // clearPeer wipes peerName, which is why endedPeerName exists at all.
      final torndown = live.copyWith(
        isActive: false,
        endedReason: RiderSessionEndReason.peerLost,
        endedPeerName: live.peerName,
        clearPeer: true,
      );

      expect(torndown.peerName, isNull);
      expect(torndown.endedPeerName, 'Alex');
    });
  });

  group('rider audio cues', () {
    Uint8List cue(String name) => switch (name) {
      'started' => RiderTones.sessionStarted(),
      'ended' => RiderTones.sessionEnded(),
      _ => RiderTones.peerLost(),
    };

    test('cues are well-formed PCM16', () {
      for (final name in ['started', 'ended', 'lost']) {
        final pcm = cue(name);
        expect(pcm.lengthInBytes.isEven, isTrue, reason: name);
        expect(pcm.lengthInBytes, greaterThan(0), reason: name);
      }
    });

    test('cues are audibly distinct from one another', () {
      expect(cue('ended'), isNot(equals(cue('started'))));
      expect(cue('lost'), isNot(equals(cue('ended'))));
    });

    test('peer-lost is longer than a clean hang-up', () {
      // The rider needs to tell "they hung up" from "they vanished".
      expect(
        RiderTones.durationOf(cue('lost')),
        greaterThan(RiderTones.durationOf(cue('ended'))),
      );
    });

    test('reported duration matches the sample count', () {
      final pcm = cue('ended');
      expect(
        RiderTones.durationOf(pcm).inMilliseconds,
        closeTo(pcm.lengthInBytes / 2 / 8000 * 1000, 1),
      );
    });

    test('cues start and end near silence so they do not click', () {
      final pcm = cue('ended');
      final view = ByteData.sublistView(pcm);
      expect(view.getInt16(0, Endian.little).abs(), lessThan(2000));
      expect(
        view.getInt16(pcm.lengthInBytes - 2, Endian.little).abs(),
        lessThan(2000),
      );
    });
  });
}
