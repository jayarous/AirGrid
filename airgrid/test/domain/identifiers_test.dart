import 'package:airgrid/domain/models/identifiers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NodeId', () {
    const validUuid = '550e8400-e29b-41d4-a716-446655440000';
    const anotherValidUuid = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

    group('fromString', () {
      test('accepts valid UUID', () {
        final nodeId = NodeId.fromString(validUuid);
        expect(nodeId, isNotNull);
        expect(nodeId!.value, validUuid);
      });

      test('rejects invalid UUID format', () {
        expect(NodeId.fromString('not-a-uuid'), isNull);
        expect(NodeId.fromString('12345'), isNull);
        expect(NodeId.fromString(''), isNull);
      });

      test('rejects UUID with invalid characters', () {
        expect(
          NodeId.fromString('550e8400-e29b-41d4-a716-44665544000g'),
          isNull,
        );
      });

      test('rejects UUID with wrong segment lengths', () {
        expect(NodeId.fromString('550e8400-e29b-41d4-a716-4466554400'), isNull);
      });
    });

    group('fromValidated', () {
      test('creates NodeId without validation', () {
        const nodeId = NodeId.fromValidated(validUuid);
        expect(nodeId.value, validUuid);
      });

      test('is const-constructible', () {
        const nodeId1 = NodeId.fromValidated(validUuid);
        const nodeId2 = NodeId.fromValidated(validUuid);
        expect(identical(nodeId1, nodeId2), isTrue);
      });
    });

    group('equality', () {
      test('equal NodeIds are equal', () {
        final nodeId1 = NodeId.fromString(validUuid);
        final nodeId2 = NodeId.fromString(validUuid);
        expect(nodeId1, equals(nodeId2));
      });

      test('different NodeIds are not equal', () {
        final nodeId1 = NodeId.fromString(validUuid);
        final nodeId2 = NodeId.fromString(anotherValidUuid);
        expect(nodeId1, isNot(equals(nodeId2)));
      });

      test('NodeId is not equal to String', () {
        final nodeId = NodeId.fromString(validUuid);
        expect(nodeId, isNot(equals(validUuid)));
      });
    });

    group('hashCode', () {
      test('equal NodeIds have equal hashCodes', () {
        final nodeId1 = NodeId.fromString(validUuid);
        final nodeId2 = NodeId.fromString(validUuid);
        expect(nodeId1.hashCode, equals(nodeId2.hashCode));
      });

      test('different NodeIds typically have different hashCodes', () {
        final nodeId1 = NodeId.fromString(validUuid);
        final nodeId2 = NodeId.fromString(anotherValidUuid);
        // Not guaranteed, but very likely for different UUIDs
        expect(nodeId1.hashCode, isNot(equals(nodeId2.hashCode)));
      });
    });

    group('toString', () {
      test('returns the UUID string', () {
        final nodeId = NodeId.fromString(validUuid);
        expect(nodeId.toString(), validUuid);
      });
    });

    group('value getter', () {
      test('returns the underlying UUID string', () {
        final nodeId = NodeId.fromString(validUuid);
        expect(nodeId!.value, validUuid);
      });
    });
  });

  group('EndpointId', () {
    const endpointStr = 'endpoint-abc123';
    const anotherEndpointStr = 'endpoint-xyz789';

    group('fromString', () {
      test('accepts non-empty string', () {
        final endpointId = EndpointId.fromString(endpointStr);
        expect(endpointId, isNotNull);
        expect(endpointId!.value, endpointStr);
      });

      test('accepts arbitrary format', () {
        expect(EndpointId.fromString('ABC'), isNotNull);
        expect(EndpointId.fromString('123'), isNotNull);
        expect(EndpointId.fromString('endpoint:foo:bar'), isNotNull);
      });

      test('rejects empty string', () {
        expect(EndpointId.fromString(''), isNull);
      });
    });

    group('equality', () {
      test('equal EndpointIds are equal', () {
        final endpointId1 = EndpointId.fromString(endpointStr);
        final endpointId2 = EndpointId.fromString(endpointStr);
        expect(endpointId1, equals(endpointId2));
      });

      test('different EndpointIds are not equal', () {
        final endpointId1 = EndpointId.fromString(endpointStr);
        final endpointId2 = EndpointId.fromString(anotherEndpointStr);
        expect(endpointId1, isNot(equals(endpointId2)));
      });

      test('EndpointId is not equal to String', () {
        final endpointId = EndpointId.fromString(endpointStr);
        expect(endpointId, isNot(equals(endpointStr)));
      });
    });

    group('hashCode', () {
      test('equal EndpointIds have equal hashCodes', () {
        final endpointId1 = EndpointId.fromString(endpointStr);
        final endpointId2 = EndpointId.fromString(endpointStr);
        expect(endpointId1.hashCode, equals(endpointId2.hashCode));
      });

      test('different EndpointIds typically have different hashCodes', () {
        final endpointId1 = EndpointId.fromString(endpointStr);
        final endpointId2 = EndpointId.fromString(anotherEndpointStr);
        expect(endpointId1.hashCode, isNot(equals(endpointId2.hashCode)));
      });
    });

    group('toString', () {
      test('returns the endpoint string', () {
        final endpointId = EndpointId.fromString(endpointStr);
        expect(endpointId.toString(), endpointStr);
      });
    });

    group('value getter', () {
      test('returns the underlying endpoint string', () {
        final endpointId = EndpointId.fromString(endpointStr);
        expect(endpointId!.value, endpointStr);
      });
    });
  });

  group('MessageId', () {
    const uuidMessageId = '7c9e6679-7425-40de-944b-e07fc1f90ae7';
    const legacyMessageId = 'msg-12345';
    const anotherMessageId = 'msg-67890';

    group('fromString', () {
      test('accepts UUID string', () {
        final messageId = MessageId.fromString(uuidMessageId);
        expect(messageId, isNotNull);
        expect(messageId!.value, uuidMessageId);
      });

      test('accepts legacy non-UUID format', () {
        final messageId = MessageId.fromString(legacyMessageId);
        expect(messageId, isNotNull);
        expect(messageId!.value, legacyMessageId);
      });

      test('accepts arbitrary non-empty string', () {
        expect(MessageId.fromString('ABC'), isNotNull);
        expect(MessageId.fromString('123'), isNotNull);
        expect(MessageId.fromString('msg:foo:bar'), isNotNull);
      });

      test('rejects empty string', () {
        expect(MessageId.fromString(''), isNull);
      });
    });

    group('equality', () {
      test('equal MessageIds are equal', () {
        final messageId1 = MessageId.fromString(legacyMessageId);
        final messageId2 = MessageId.fromString(legacyMessageId);
        expect(messageId1, equals(messageId2));
      });

      test('different MessageIds are not equal', () {
        final messageId1 = MessageId.fromString(legacyMessageId);
        final messageId2 = MessageId.fromString(anotherMessageId);
        expect(messageId1, isNot(equals(messageId2)));
      });

      test('UUID and legacy IDs are not equal', () {
        final messageId1 = MessageId.fromString(uuidMessageId);
        final messageId2 = MessageId.fromString(legacyMessageId);
        expect(messageId1, isNot(equals(messageId2)));
      });

      test('MessageId is not equal to String', () {
        final messageId = MessageId.fromString(legacyMessageId);
        expect(messageId, isNot(equals(legacyMessageId)));
      });
    });

    group('hashCode', () {
      test('equal MessageIds have equal hashCodes', () {
        final messageId1 = MessageId.fromString(legacyMessageId);
        final messageId2 = MessageId.fromString(legacyMessageId);
        expect(messageId1.hashCode, equals(messageId2.hashCode));
      });

      test('different MessageIds typically have different hashCodes', () {
        final messageId1 = MessageId.fromString(legacyMessageId);
        final messageId2 = MessageId.fromString(anotherMessageId);
        expect(messageId1.hashCode, isNot(equals(messageId2.hashCode)));
      });
    });

    group('toString', () {
      test('returns the message ID string', () {
        final messageId = MessageId.fromString(legacyMessageId);
        expect(messageId.toString(), legacyMessageId);
      });
    });

    group('value getter', () {
      test('returns the underlying message ID string', () {
        final messageId = MessageId.fromString(legacyMessageId);
        expect(messageId!.value, legacyMessageId);
      });
    });
  });

  group('Type safety', () {
    test('NodeId and EndpointId are distinct types', () {
      const uuid = '550e8400-e29b-41d4-a716-446655440000';
      final nodeId = NodeId.fromString(uuid);
      final endpointId = EndpointId.fromString(uuid);

      expect(nodeId, isNot(equals(endpointId)));
      expect(nodeId.runtimeType, isNot(equals(endpointId.runtimeType)));
    });

    test('NodeId and MessageId are distinct types', () {
      const uuid = '550e8400-e29b-41d4-a716-446655440000';
      final nodeId = NodeId.fromString(uuid);
      final messageId = MessageId.fromString(uuid);

      expect(nodeId, isNot(equals(messageId)));
      expect(nodeId.runtimeType, isNot(equals(messageId.runtimeType)));
    });

    test('EndpointId and MessageId are distinct types', () {
      const str = 'identifier-123';
      final endpointId = EndpointId.fromString(str);
      final messageId = MessageId.fromString(str);

      expect(endpointId, isNot(equals(messageId)));
      expect(endpointId.runtimeType, isNot(equals(messageId.runtimeType)));
    });
  });
}
