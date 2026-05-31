import 'package:airgrid/domain/models/known_contact.dart';
import 'package:flutter_test/flutter_test.dart';

KnownContact _contact({
  String nodeId = 'node-1',
  String displayName = 'Alice',
  bool isBlocked = false,
  bool isTrusted = false,
  bool isChatClosed = false,
}) {
  return KnownContact(
    nodeId: nodeId,
    displayName: displayName,
    publicKeyBase64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    lastSeenAt: DateTime(2024, 1, 1),
    isBlocked: isBlocked,
    isTrusted: isTrusted,
    isChatClosed: isChatClosed,
  );
}

void main() {
  group('KnownContact.isBlocked', () {
    test('defaults to false in constructor', () {
      final c = _contact();
      expect(c.isBlocked, isFalse);
    });

    test('can be set to true in constructor', () {
      final c = _contact(isBlocked: true);
      expect(c.isBlocked, isTrue);
    });

    test('fromJson without isBlocked field defaults to false', () {
      final json = {
        'nodeId': 'node-1',
        'displayName': 'Alice',
        'publicKeyBase64': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        'lastSeenAt': DateTime(2024, 1, 1).millisecondsSinceEpoch,
      };
      final c = KnownContact.fromJson(json);
      expect(c.isBlocked, isFalse);
    });

    test('fromJson with isBlocked: true reads correctly', () {
      final json = {
        'nodeId': 'node-1',
        'displayName': 'Alice',
        'publicKeyBase64': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        'lastSeenAt': DateTime(2024, 1, 1).millisecondsSinceEpoch,
        'isBlocked': true,
      };
      final c = KnownContact.fromJson(json);
      expect(c.isBlocked, isTrue);
    });

    test('toJson includes isBlocked', () {
      final c = _contact(isBlocked: true);
      final json = c.toJson();
      expect(json['isBlocked'], isTrue);
    });

    test('toJson isBlocked false is included', () {
      final c = _contact();
      final json = c.toJson();
      expect(json.containsKey('isBlocked'), isTrue);
      expect(json['isBlocked'], isFalse);
    });

    test('copyWith(isBlocked: true) changes value', () {
      final c = _contact();
      final blocked = c.copyWith(isBlocked: true);
      expect(blocked.isBlocked, isTrue);
      expect(blocked.nodeId, c.nodeId);
      expect(blocked.displayName, c.displayName);
    });

    test('copyWith(isBlocked: false) changes value', () {
      final c = _contact(isBlocked: true);
      final unblocked = c.copyWith(isBlocked: false);
      expect(unblocked.isBlocked, isFalse);
    });

    test('copyWith() without isBlocked preserves existing value', () {
      final blocked = _contact(isBlocked: true);
      final copy = blocked.copyWith(displayName: 'Alice2');
      expect(copy.isBlocked, isTrue);
    });

    test('roundtrip toJson / fromJson preserves isBlocked', () {
      final original = _contact(isBlocked: true);
      final restored = KnownContact.fromJson(original.toJson());
      expect(restored.isBlocked, isTrue);
      expect(restored.nodeId, original.nodeId);
    });
  });

  group('KnownContact.isTrusted', () {
    test('defaults to false in constructor', () {
      final c = _contact();
      expect(c.isTrusted, isFalse);
    });

    test('can be set to true in constructor', () {
      final c = _contact(isTrusted: true);
      expect(c.isTrusted, isTrue);
    });

    test('fromJson without isTrusted field defaults to false', () {
      final json = {
        'nodeId': 'node-1',
        'displayName': 'Alice',
        'publicKeyBase64': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        'lastSeenAt': DateTime(2024, 1, 1).millisecondsSinceEpoch,
      };
      final c = KnownContact.fromJson(json);
      expect(c.isTrusted, isFalse);
    });

    test('toJson includes isTrusted', () {
      final c = _contact(isTrusted: true);
      final json = c.toJson();
      expect(json['isTrusted'], isTrue);
    });

    test('copyWith(isTrusted: true) changes value', () {
      final c = _contact();
      final trusted = c.copyWith(isTrusted: true);
      expect(trusted.isTrusted, isTrue);
    });

    test('roundtrip toJson / fromJson preserves isTrusted', () {
      final original = _contact(isTrusted: true);
      final restored = KnownContact.fromJson(original.toJson());
      expect(restored.isTrusted, isTrue);
    });
  });

  group('KnownContact.isChatClosed', () {
    test('defaults to false in constructor', () {
      final c = _contact();
      expect(c.isChatClosed, isFalse);
    });

    test('fromJson without isChatClosed field defaults to false', () {
      final json = {
        'nodeId': 'node-1',
        'displayName': 'Alice',
        'publicKeyBase64': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        'lastSeenAt': DateTime(2024, 1, 1).millisecondsSinceEpoch,
      };
      final c = KnownContact.fromJson(json);
      expect(c.isChatClosed, isFalse);
    });

    test('toJson includes isChatClosed', () {
      final c = _contact(isChatClosed: true);
      final json = c.toJson();
      expect(json['isChatClosed'], isTrue);
    });

    test('copyWith(isChatClosed: true) changes value', () {
      final c = _contact();
      final closed = c.copyWith(isChatClosed: true);
      expect(closed.isChatClosed, isTrue);
    });

    test('roundtrip toJson / fromJson preserves isChatClosed', () {
      final original = _contact(isChatClosed: true);
      final restored = KnownContact.fromJson(original.toJson());
      expect(restored.isChatClosed, isTrue);
    });
  });
}
