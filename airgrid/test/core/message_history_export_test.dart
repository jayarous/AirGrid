import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/message_history_export.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 8, 9, 14, 32);

AirGridMessage _message({
  required String id,
  required String content,
  DateTime? at,
  String senderName = 'Rashid',
  bool isLocal = false,
  String conversationType = 'public',
  String? peerNodeId,
  String? peerName,
  String messageKind = 'text',
  String? mediaMimeType,
  int? mediaByteLength,
  int? mediaDurationMs,
  DeliveryStatus deliveryStatus = DeliveryStatus.sent,
}) {
  return AirGridMessage(
    id: id,
    senderNodeId: isLocal ? 'local-node' : 'peer-node',
    senderName: senderName,
    timestamp: at ?? _now,
    content: content,
    isLocal: isLocal,
    conversationType: conversationType,
    peerNodeId: peerNodeId,
    peerName: peerName,
    messageKind: messageKind,
    mediaMimeType: mediaMimeType,
    mediaByteLength: mediaByteLength,
    mediaDurationMs: mediaDurationMs,
    deliveryStatus: deliveryStatus,
  );
}

String _export(List<AirGridMessage> messages) => formatMessageHistory(
  messages: messages,
  deviceName: 'Jay',
  deviceNodeId: 'local-node',
  exportedAt: _now,
);

void main() {
  group('empty history', () {
    test('produces an empty string, not a placeholder transcript', () {
      // The caller has to branch anyway to avoid sharing an empty file, and UI
      // copy does not belong in a formatter.
      expect(_export([]), isEmpty);
    });
  });

  group('header', () {
    test('names the device and the export time', () {
      final text = _export([_message(id: '1', content: 'hi')]);

      expect(text, contains('AirGrid message history'));
      expect(text, contains('Exported: 2026-08-09 14:32'));
      expect(text, contains('Device: Jay (local-node)'));
    });

    test('states the retention rule so a short export is not read as loss', () {
      final text = _export([_message(id: '1', content: 'hi')]);

      expect(text, contains('${AirGridConstants.kChatMaxMessages} messages'));
      expect(text, contains('${AirGridConstants.kChatMaxAge.inDays} days'));
    });

    test('counts the messages it exported', () {
      final text = _export([
        _message(id: '1', content: 'one'),
        _message(id: '2', content: 'two'),
      ]);

      expect(text, contains('Messages: 2'));
    });
  });

  group('grouping', () {
    test('separates public from each private thread', () {
      final text = _export([
        _message(id: '1', content: 'public one'),
        _message(
          id: '2',
          content: 'private to Rashid',
          conversationType: 'private',
          peerNodeId: 'peer-a',
          peerName: 'Rashid',
        ),
        _message(
          id: '3',
          content: 'private to Sara',
          conversationType: 'private',
          peerNodeId: 'peer-b',
          peerName: 'Sara',
        ),
      ]);

      expect(text, contains('==== Public mesh ===='));
      expect(text, contains('==== Private: Rashid (peer-a) ===='));
      expect(text, contains('==== Private: Sara (peer-b) ===='));
    });

    test('omits the public section when there are no public messages', () {
      final text = _export([
        _message(
          id: '1',
          content: 'only private',
          conversationType: 'private',
          peerNodeId: 'peer-a',
          peerName: 'Rashid',
        ),
      ]);

      expect(text, isNot(contains('Public mesh')));
    });

    test('puts public first, then threads by most recent activity', () {
      final text = _export([
        _message(id: '1', content: 'public', at: DateTime(2026, 8, 1)),
        _message(
          id: '2',
          content: 'older thread',
          at: DateTime(2026, 8, 2),
          conversationType: 'private',
          peerNodeId: 'peer-a',
          peerName: 'Rashid',
        ),
        _message(
          id: '3',
          content: 'newer thread',
          at: DateTime(2026, 8, 5),
          conversationType: 'private',
          peerNodeId: 'peer-b',
          peerName: 'Sara',
        ),
      ]);

      expect(
        text.indexOf('Public mesh'),
        lessThan(text.indexOf('Private: Sara')),
      );
      expect(
        text.indexOf('Private: Sara'),
        lessThan(text.indexOf('Private: Rashid')),
        reason: 'the thread used most recently should come first',
      );
    });

    test('treats a private message with no peer id as public', () {
      // Defensive: the column is nullable, and a transcript must not drop a
      // message just because its thread cannot be identified.
      final text = _export([
        _message(id: '1', content: 'orphaned', conversationType: 'private'),
      ]);

      expect(text, contains('==== Public mesh ===='));
      expect(text, contains('orphaned'));
    });
  });

  group('ordering within a conversation', () {
    test('runs oldest-first, reversing loadRecent order', () {
      // loadRecent returns newest-first; a transcript read in that order is
      // backwards.
      final text = _export([
        _message(id: '2', content: 'second', at: DateTime(2026, 8, 2)),
        _message(id: '1', content: 'first', at: DateTime(2026, 8, 1)),
      ]);

      expect(text.indexOf('first'), lessThan(text.indexOf('second')));
    });
  });

  group('attribution', () {
    test('marks the local side with the device name', () {
      final text = _export([
        _message(id: '1', content: 'mine', isLocal: true, senderName: 'Jay'),
      ]);

      expect(text, contains('Jay (you):'));
    });

    test('uses the sender name for everyone else', () {
      final text = _export([
        _message(id: '1', content: 'theirs', senderName: 'Rashid'),
      ]);

      expect(text, contains('Rashid:'));
      expect(text, isNot(contains('(you)')));
    });

    test('falls back to the node id when a peer was never named', () {
      final text = _export([
        _message(
          id: '1',
          content: 'anonymous',
          conversationType: 'private',
          peerNodeId: 'peer-a',
        ),
      ]);

      expect(text, contains('==== Private: peer-a ===='));
    });

    test('prefers the most recent name a peer used', () {
      final text = _export([
        _message(
          id: '1',
          content: 'before',
          at: DateTime(2026, 8, 1),
          conversationType: 'private',
          peerNodeId: 'peer-a',
          peerName: 'Old Name',
        ),
        _message(
          id: '2',
          content: 'after',
          at: DateTime(2026, 8, 2),
          conversationType: 'private',
          peerNodeId: 'peer-a',
          peerName: 'New Name',
        ),
      ]);

      expect(text, contains('Private: New Name (peer-a)'));
      expect(text, isNot(contains('Old Name')));
    });
  });

  group('attachments are described, not dropped', () {
    test('a photo names its size', () {
      final text = _export([
        _message(
          id: '1',
          content: '[photo]',
          messageKind: 'image',
          mediaByteLength: 245760,
        ),
      ]);

      expect(text, contains('[photo, 240 KB]'));
    });

    test('a voice note names its length', () {
      final text = _export([
        _message(
          id: '1',
          content: '[voice]',
          messageKind: 'audio',
          mediaDurationMs: 7400,
        ),
      ]);

      expect(text, contains('[voice note, 0:07]'));
    });

    test('a file names its type and size, since no filename is stored', () {
      final text = _export([
        _message(
          id: '1',
          content: '[file]',
          messageKind: 'file',
          mediaMimeType: 'application/pdf',
          mediaByteLength: 2202009,
        ),
      ]);

      expect(text, contains('[file: application/pdf, 2.1 MB]'));
    });

    test('media with no metadata still appears', () {
      final text = _export([
        _message(id: '1', content: '[file]', messageKind: 'file'),
      ]);

      expect(text, contains('[file]'));
    });
  });

  group('delivery state', () {
    test('is shown for outgoing private messages', () {
      final text = _export([
        _message(
          id: '1',
          content: 'did you get this',
          isLocal: true,
          conversationType: 'private',
          peerNodeId: 'peer-a',
          peerName: 'Rashid',
          deliveryStatus: DeliveryStatus.read,
        ),
      ]);

      expect(text, contains('(read)'));
    });

    test('is left off public messages, which have no delivery model', () {
      final text = _export([
        _message(
          id: '1',
          content: 'broadcast',
          isLocal: true,
          deliveryStatus: DeliveryStatus.delivered,
        ),
      ]);

      expect(text, isNot(contains('(delivered)')));
    });

    test('is left off incoming messages', () {
      final text = _export([
        _message(
          id: '1',
          content: 'from them',
          conversationType: 'private',
          peerNodeId: 'peer-a',
          peerName: 'Rashid',
          deliveryStatus: DeliveryStatus.delivered,
        ),
      ]);

      expect(text, isNot(contains('(delivered)')));
    });

    test('says nothing for the ordinary sent case', () {
      // Printing "sent" against every outgoing line would be noise.
      final text = _export([
        _message(
          id: '1',
          content: 'ordinary',
          isLocal: true,
          conversationType: 'private',
          peerNodeId: 'peer-a',
          peerName: 'Rashid',
        ),
      ]);

      expect(text, isNot(contains('(sent)')));
    });
  });

  group('message bodies', () {
    test('indent under the attribution line', () {
      final text = _export([_message(id: '1', content: 'hello there')]);

      expect(text, contains('\n  hello there'));
    });

    test('keep multi-line content readable', () {
      final text = _export([_message(id: '1', content: 'line one\nline two')]);

      expect(text, contains('\n  line one\n  line two'));
    });
  });
}
