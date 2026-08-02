import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the relay-eligibility matrix.
///
/// Two rules underpin the whole table:
///   - Public traffic relays: everyone is meant to see it.
///   - Private traffic relays only when encrypted, because a relay must never
///     be able to read what it forwards. Plaintext private packets are
///     therefore dropped rather than forwarded.
AirGridPacket _packet({
  required String packetType,
  String conversationType = 'public',
  int? encryptionVersion,
}) => AirGridPacket(
  messageId: 'm1',
  senderNodeId: 'n1',
  senderName: 'Sender',
  timestamp: 0,
  content: 'c',
  seenByNodes: const ['n1'],
  hopLimit: 8,
  packetType: packetType,
  conversationType: conversationType,
  encryptionVersion: encryptionVersion,
);

void main() {
  group('public traffic relays', () {
    for (final type in ['chat', 'image', 'audio']) {
      test('$type relays when public', () {
        expect(_packet(packetType: type).isRelayEligible, isTrue);
      });
    }

    test('key_announce relays', () {
      expect(_packet(packetType: 'key_announce').isRelayEligible, isTrue);
    });

    test('location_update relays', () {
      expect(_packet(packetType: 'location_update').isRelayEligible, isTrue);
    });
  });

  group('private traffic relays only when encrypted', () {
    for (final type in ['chat', 'image', 'audio', 'file']) {
      test('private $type relays when encrypted', () {
        expect(
          _packet(
            packetType: type,
            conversationType: 'private',
            encryptionVersion: 1,
          ).isRelayEligible,
          isTrue,
        );
      });

      test('private $type does NOT relay in plaintext', () {
        expect(
          _packet(
            packetType: type,
            conversationType: 'private',
          ).isRelayEligible,
          isFalse,
          reason: 'a relay must never be able to read what it forwards',
        );
      });
    }
  });

  group('receipts', () {
    for (final type in ['delivery_receipt', 'read_receipt']) {
      test('$type relays when private and encrypted', () {
        expect(
          _packet(
            packetType: type,
            conversationType: 'private',
            encryptionVersion: 1,
          ).isRelayEligible,
          isTrue,
        );
      });

      test('$type does NOT relay in plaintext', () {
        expect(
          _packet(
            packetType: type,
            conversationType: 'private',
          ).isRelayEligible,
          isFalse,
        );
      });
    }
  });

  group('fragments', () {
    test('public fragment relays', () {
      expect(_packet(packetType: 'fragment').isRelayEligible, isTrue);
    });

    test('encrypted private fragment relays', () {
      expect(
        _packet(
          packetType: 'fragment',
          conversationType: 'private',
          encryptionVersion: 1,
        ).isRelayEligible,
        isTrue,
      );
    });

    test('plaintext private fragment does NOT relay', () {
      expect(
        _packet(
          packetType: 'fragment',
          conversationType: 'private',
        ).isRelayEligible,
        isFalse,
      );
    });
  });
}
