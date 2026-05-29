import 'package:airgrid/core/validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DisplayNameValidator', () {
    group('validateLocal', () {
      test('accepts valid name', () {
        final result = DisplayNameValidator.validateLocal('Alice');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Alice');
        expect(result.error, null);
      });

      test('trims leading and trailing whitespace', () {
        final result = DisplayNameValidator.validateLocal('  Bob  ');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Bob');
      });

      test('collapses multiple consecutive whitespace to single space', () {
        final result = DisplayNameValidator.validateLocal('Alice   Bob');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Alice Bob');
      });

      test('collapses tabs and spaces', () {
        final result = DisplayNameValidator.validateLocal('Alice\t\t  Bob');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Alice Bob');
      });

      test('rejects empty string', () {
        final result = DisplayNameValidator.validateLocal('');
        expect(result.isValid, false);
        expect(result.error, contains('cannot be empty'));
      });

      test('rejects whitespace-only string', () {
        final result = DisplayNameValidator.validateLocal('   ');
        expect(result.isValid, false);
        expect(result.error, contains('cannot be empty'));
      });

      test('rejects name with control characters (newline)', () {
        final result = DisplayNameValidator.validateLocal('Alice\nBob');
        expect(result.isValid, false);
        expect(result.error, contains('invalid characters'));
      });

      test('rejects name with control characters (null)', () {
        final result = DisplayNameValidator.validateLocal('Alice\x00Bob');
        expect(result.isValid, false);
        expect(result.error, contains('invalid characters'));
      });

      test('rejects name exceeding 32 characters', () {
        final longName = 'A' * 33;
        final result = DisplayNameValidator.validateLocal(longName);
        expect(result.isValid, false);
        expect(result.error, contains('cannot exceed 32 characters'));
      });

      test('accepts name with exactly 32 characters', () {
        final name = 'A' * 32;
        final result = DisplayNameValidator.validateLocal(name);
        expect(result.isValid, true);
        expect(result.sanitizedValue, name);
      });

      test('accepts name with Unicode characters', () {
        final result = DisplayNameValidator.validateLocal('Alice 🌟');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Alice 🌟');
      });
    });

    group('validateRemote', () {
      test('accepts valid remote name', () {
        final result = DisplayNameValidator.validateRemote('Alice');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Alice');
      });

      test('rejects name with leading whitespace', () {
        final result = DisplayNameValidator.validateRemote(' Alice');
        expect(result.isValid, false);
        expect(result.error, contains('leading/trailing whitespace'));
      });

      test('rejects name with trailing whitespace', () {
        final result = DisplayNameValidator.validateRemote('Alice ');
        expect(result.isValid, false);
        expect(result.error, contains('leading/trailing whitespace'));
      });

      test('rejects name with consecutive whitespace', () {
        final result = DisplayNameValidator.validateRemote('Alice  Bob');
        expect(result.isValid, false);
        expect(result.error, contains('consecutive whitespace'));
      });

      test('rejects empty string', () {
        final result = DisplayNameValidator.validateRemote('');
        expect(result.isValid, false);
        expect(result.error, contains('empty'));
      });

      test('rejects name with control characters', () {
        final result = DisplayNameValidator.validateRemote('Alice\nBob');
        expect(result.isValid, false);
        expect(result.error, contains('control characters'));
      });

      test('rejects name exceeding 32 characters', () {
        final longName = 'A' * 33;
        final result = DisplayNameValidator.validateRemote(longName);
        expect(result.isValid, false);
        expect(result.error, contains('exceeds 32 characters'));
      });

      test('accepts name with Unicode characters', () {
        final result = DisplayNameValidator.validateRemote('Alice 🌟');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Alice 🌟');
      });
    });
  });

  group('MessageContentValidator', () {
    group('validateLocal', () {
      test('accepts valid message', () {
        final result = MessageContentValidator.validateLocal('Hello, world!');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Hello, world!');
      });

      test('trims leading and trailing whitespace', () {
        final result = MessageContentValidator.validateLocal('  Hello  ');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Hello');
      });

      test('rejects empty string', () {
        final result = MessageContentValidator.validateLocal('');
        expect(result.isValid, false);
        expect(result.error, contains('cannot be empty'));
      });

      test('rejects whitespace-only string', () {
        final result = MessageContentValidator.validateLocal('   ');
        expect(result.isValid, false);
        expect(result.error, contains('cannot be empty'));
      });

      test('accepts message with newlines', () {
        final result = MessageContentValidator.validateLocal('Line 1\nLine 2');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Line 1\nLine 2');
      });

      test('accepts message with carriage returns', () {
        final result = MessageContentValidator.validateLocal(
          'Line 1\r\nLine 2',
        );
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Line 1\r\nLine 2');
      });

      test('accepts message with tabs', () {
        final result = MessageContentValidator.validateLocal('Col1\tCol2');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Col1\tCol2');
      });

      test('rejects message with null character', () {
        final result = MessageContentValidator.validateLocal('Hello\x00World');
        expect(result.isValid, false);
        expect(result.error, contains('invalid control characters'));
      });

      test('rejects message with bell character', () {
        final result = MessageContentValidator.validateLocal('Hello\x07World');
        expect(result.isValid, false);
        expect(result.error, contains('invalid control characters'));
      });

      test('rejects message exceeding byte limit', () {
        // Create a message slightly over 8 KB
        final largeMessage = 'A' * (8 * 1024 + 1);
        final result = MessageContentValidator.validateLocal(largeMessage);
        expect(result.isValid, false);
        expect(result.error, contains('exceeds maximum size'));
        expect(result.error, contains('8192 bytes'));
      });

      test('accepts message at byte limit', () {
        // Create a message exactly 8 KB
        final message = 'A' * (8 * 1024);
        final result = MessageContentValidator.validateLocal(message);
        expect(result.isValid, true);
      });

      test('checks byte length not character length for Unicode', () {
        // Emoji can be 4 bytes each
        // 2048 emoji * 4 bytes = 8192 bytes (at limit)
        final message = '🌟' * 2048;
        final result = MessageContentValidator.validateLocal(message);
        expect(result.isValid, true);

        // 2049 emoji * 4 bytes = 8196 bytes (over limit)
        final overLimit = '🌟' * 2049;
        final result2 = MessageContentValidator.validateLocal(overLimit);
        expect(result2.isValid, false);
        expect(result2.error, contains('exceeds maximum size'));
      });
    });

    group('validateRemote', () {
      test('accepts valid remote message', () {
        final result = MessageContentValidator.validateRemote('Hello, world!');
        expect(result.isValid, true);
        expect(result.sanitizedValue, 'Hello, world!');
      });

      test('rejects message with leading whitespace', () {
        final result = MessageContentValidator.validateRemote(' Hello');
        expect(result.isValid, false);
        expect(result.error, contains('untrimmed whitespace'));
      });

      test('rejects message with trailing whitespace', () {
        final result = MessageContentValidator.validateRemote('Hello ');
        expect(result.isValid, false);
        expect(result.error, contains('untrimmed whitespace'));
      });

      test('rejects empty string', () {
        final result = MessageContentValidator.validateRemote('');
        expect(result.isValid, false);
        expect(result.error, contains('empty'));
      });

      test('accepts message with newlines', () {
        final result = MessageContentValidator.validateRemote('Line 1\nLine 2');
        expect(result.isValid, true);
      });

      test('rejects message with disallowed control characters', () {
        final result = MessageContentValidator.validateRemote('Hello\x00World');
        expect(result.isValid, false);
        expect(result.error, contains('invalid control characters'));
      });

      test('rejects message exceeding byte limit', () {
        final largeMessage = 'A' * (8 * 1024 + 1);
        final result = MessageContentValidator.validateRemote(largeMessage);
        expect(result.isValid, false);
        expect(result.error, contains('exceeds maximum size'));
      });
    });
  });

  group('NodeIdValidator', () {
    group('validate', () {
      test('accepts valid UUID v4 lowercase', () {
        final result = NodeIdValidator.validate(
          '550e8400-e29b-41d4-a716-446655440000',
        );
        expect(result.isValid, true);
        expect(result.sanitizedValue, '550e8400-e29b-41d4-a716-446655440000');
      });

      test('accepts valid UUID v4 uppercase', () {
        final result = NodeIdValidator.validate(
          '550E8400-E29B-41D4-A716-446655440000',
        );
        expect(result.isValid, true);
      });

      test('accepts valid UUID v4 mixed case', () {
        final result = NodeIdValidator.validate(
          '550e8400-E29B-41d4-A716-446655440000',
        );
        expect(result.isValid, true);
      });

      test('rejects empty string', () {
        final result = NodeIdValidator.validate('');
        expect(result.isValid, false);
        expect(result.error, contains('empty'));
      });

      test('rejects UUID without hyphens', () {
        final result = NodeIdValidator.validate(
          '550e8400e29b41d4a716446655440000',
        );
        expect(result.isValid, false);
        expect(result.error, contains('not a valid UUID'));
      });

      test('rejects UUID with wrong segment lengths', () {
        final result = NodeIdValidator.validate(
          '550e840-e29b-41d4-a716-446655440000',
        );
        expect(result.isValid, false);
        expect(result.error, contains('not a valid UUID'));
      });

      test('rejects UUID with non-hex characters', () {
        final result = NodeIdValidator.validate(
          '550e8400-e29b-41d4-a716-44665544000g',
        );
        expect(result.isValid, false);
        expect(result.error, contains('not a valid UUID'));
      });

      test('rejects arbitrary string', () {
        final result = NodeIdValidator.validate('not-a-uuid');
        expect(result.isValid, false);
        expect(result.error, contains('not a valid UUID'));
      });

      test('rejects UUID with spaces', () {
        final result = NodeIdValidator.validate(
          '550e8400-e29b-41d4-a716-446655440000 ',
        );
        expect(result.isValid, false);
        expect(result.error, contains('not a valid UUID'));
      });
    });

    group('isValid', () {
      test('returns true for valid UUID', () {
        expect(
          NodeIdValidator.isValid('550e8400-e29b-41d4-a716-446655440000'),
          true,
        );
      });

      test('returns false for invalid UUID', () {
        expect(NodeIdValidator.isValid('not-a-uuid'), false);
      });

      test('returns false for empty string', () {
        expect(NodeIdValidator.isValid(''), false);
      });
    });
  });
}
