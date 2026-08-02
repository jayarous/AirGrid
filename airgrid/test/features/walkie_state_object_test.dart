import 'package:airgrid/features/walkie/walkie_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// WalkieState is now a standalone value object rather than nine loose fields
/// on ChatState, so the invite/session state machine can be tested directly.
void main() {
  group('defaults', () {
    test('initial is idle', () {
      const s = WalkieState.initial();

      expect(s.peerNodeId, isNull);
      expect(s.isTransmitting, isFalse);
      expect(s.isSending, isFalse);
      expect(s.lastError, isNull);
      expect(s.publicStayOnline, isFalse);
      expect(s.hasPendingInvite, isFalse);
      expect(s.hasActiveSession, isFalse);
    });
  });

  group('copyWith', () {
    test('updates only the named field', () {
      const s = WalkieState.initial();

      final next = s.copyWith(isTransmitting: true);

      expect(next.isTransmitting, isTrue);
      expect(next.isSending, isFalse);
      expect(next.peerNodeId, isNull);
    });

    test('clear flags win over values', () {
      const s = WalkieState(peerNodeId: 'p1', lastError: 'boom');

      expect(s.copyWith(clearPeerNodeId: true).peerNodeId, isNull);
      expect(s.copyWith(clearLastError: true).lastError, isNull);
    });

    test('clearInvite resets all three invite fields together', () {
      const s = WalkieState(
        inviteSessionId: 's1',
        invitePeerNodeId: 'p1',
        inviteIsIncoming: true,
      );

      final cleared = s.copyWith(clearInvite: true);

      expect(cleared.inviteSessionId, isNull);
      expect(cleared.invitePeerNodeId, isNull);
      expect(
        cleared.inviteIsIncoming,
        isFalse,
        reason: 'a half-cleared invite would strand the handshake',
      );
    });

    test('clearing the invite leaves an accepted session intact', () {
      const s = WalkieState(
        inviteSessionId: 's1',
        invitePeerNodeId: 'p1',
        sessionActivePeerNodeId: 'p1',
      );

      final accepted = s.copyWith(clearInvite: true);

      expect(accepted.hasPendingInvite, isFalse);
      expect(accepted.hasActiveSession, isTrue);
      expect(accepted.sessionActivePeerNodeId, 'p1');
    });

    test('clearSessionActivePeerNodeId ends the session', () {
      const s = WalkieState(sessionActivePeerNodeId: 'p1');

      expect(
        s.copyWith(clearSessionActivePeerNodeId: true).hasActiveSession,
        isFalse,
      );
    });
  });
}
