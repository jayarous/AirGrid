import 'package:airgrid/domain/services/relay_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RelayController.decide', () {
    // ── hop-limit exhaustion ────────────────────────────────────────────

    test('hop limit 0 returns shouldRelay=false regardless of type', () {
      final d = RelayController.decide(
        packetType: 'chat',
        isDirectedEncrypted: false,
        peerCount: 2,
        currentHopLimit: 0,
      );
      expect(d.shouldRelay, isFalse);
    });

    test(
      'hop limit 0 for encrypted private also returns shouldRelay=false',
      () {
        final d = RelayController.decide(
          packetType: 'chat',
          isDirectedEncrypted: true,
          peerCount: 2,
          currentHopLimit: 0,
        );
        expect(d.shouldRelay, isFalse);
      },
    );

    test(
      'hop limit 1 returns shouldRelay=false (forward copy would be TTL=0)',
      () {
        final d = RelayController.decide(
          packetType: 'chat',
          isDirectedEncrypted: false,
          peerCount: 2,
          currentHopLimit: 1,
        );
        expect(d.shouldRelay, isFalse);
        expect(d.newHopLimit, equals(0));
      },
    );

    // ── TTL cap per packet type ─────────────────────────────────────────

    test('public chat: newHopLimit capped at 6', () {
      final d = RelayController.decide(
        packetType: 'chat',
        isDirectedEncrypted: false,
        peerCount: 1,
        currentHopLimit: 10,
      );
      expect(d.shouldRelay, isTrue);
      expect(d.newHopLimit, equals(6));
    });

    test('public chat: newHopLimit is currentHopLimit-1 when below cap', () {
      final d = RelayController.decide(
        packetType: 'chat',
        isDirectedEncrypted: false,
        peerCount: 1,
        currentHopLimit: 4,
      );
      expect(d.newHopLimit, equals(3)); // min(3, 6) = 3
    });

    test('key_announce: newHopLimit capped at 7', () {
      final d = RelayController.decide(
        packetType: 'key_announce',
        isDirectedEncrypted: false,
        peerCount: 1,
        currentHopLimit: 10,
      );
      expect(d.newHopLimit, equals(7));
    });

    test('location_update: newHopLimit capped at 7', () {
      final d = RelayController.decide(
        packetType: 'location_update',
        isDirectedEncrypted: false,
        peerCount: 1,
        currentHopLimit: 10,
      );
      expect(d.newHopLimit, equals(7));
    });

    test('directed encrypted private: newHopLimit capped at 8', () {
      final d = RelayController.decide(
        packetType: 'chat',
        isDirectedEncrypted: true,
        peerCount: 1,
        currentHopLimit: 10,
      );
      expect(d.newHopLimit, equals(8));
    });

    test('delivery_receipt: newHopLimit capped at 8', () {
      final d = RelayController.decide(
        packetType: 'delivery_receipt',
        isDirectedEncrypted: false,
        peerCount: 1,
        currentHopLimit: 10,
      );
      expect(d.newHopLimit, equals(8));
    });

    test('read_receipt: newHopLimit capped at 8', () {
      final d = RelayController.decide(
        packetType: 'read_receipt',
        isDirectedEncrypted: false,
        peerCount: 1,
        currentHopLimit: 10,
      );
      expect(d.newHopLimit, equals(8));
    });

    test('fragment: newHopLimit capped at 8', () {
      final d = RelayController.decide(
        packetType: 'fragment',
        isDirectedEncrypted: false,
        peerCount: 1,
        currentHopLimit: 10,
      );
      expect(d.newHopLimit, equals(8));
    });

    // ── jitter by peer density ──────────────────────────────────────────

    test('sparse mesh (0 peers): jitter in 0–20 ms', () {
      for (var i = 0; i < 200; i++) {
        final d = RelayController.decide(
          packetType: 'chat',
          isDirectedEncrypted: false,
          peerCount: 0,
          currentHopLimit: 4,
        );
        expect(d.delayMs, inInclusiveRange(0, 20));
      }
    });

    test('sparse mesh (3 peers): jitter in 0–20 ms', () {
      for (var i = 0; i < 200; i++) {
        final d = RelayController.decide(
          packetType: 'chat',
          isDirectedEncrypted: false,
          peerCount: 3,
          currentHopLimit: 4,
        );
        expect(d.delayMs, inInclusiveRange(0, 20));
      }
    });

    test('medium mesh (4 peers): jitter in 20–80 ms', () {
      for (var i = 0; i < 200; i++) {
        final d = RelayController.decide(
          packetType: 'chat',
          isDirectedEncrypted: false,
          peerCount: 4,
          currentHopLimit: 4,
        );
        expect(d.delayMs, inInclusiveRange(20, 80));
      }
    });

    test('medium mesh (7 peers): jitter in 20–80 ms', () {
      for (var i = 0; i < 200; i++) {
        final d = RelayController.decide(
          packetType: 'chat',
          isDirectedEncrypted: false,
          peerCount: 7,
          currentHopLimit: 4,
        );
        expect(d.delayMs, inInclusiveRange(20, 80));
      }
    });

    test('dense mesh (8 peers): jitter in 80–250 ms', () {
      for (var i = 0; i < 200; i++) {
        final d = RelayController.decide(
          packetType: 'chat',
          isDirectedEncrypted: false,
          peerCount: 8,
          currentHopLimit: 4,
        );
        expect(d.delayMs, inInclusiveRange(80, 250));
      }
    });

    test('dense mesh (20 peers): jitter in 80–250 ms', () {
      for (var i = 0; i < 200; i++) {
        final d = RelayController.decide(
          packetType: 'chat',
          isDirectedEncrypted: false,
          peerCount: 20,
          currentHopLimit: 4,
        );
        expect(d.delayMs, inInclusiveRange(80, 250));
      }
    });

    // -- shouldRelay=false when newHopLimit would be 0 --------------------

    test(
      'hop limit 1: shouldRelay=false because forward copy would be TTL=0',
      () {
        final d = RelayController.decide(
          packetType: 'chat',
          isDirectedEncrypted: false,
          peerCount: 1,
          currentHopLimit: 1,
        );
        expect(d.shouldRelay, isFalse);
        expect(d.newHopLimit, equals(0));
      },
    );
  });
}
