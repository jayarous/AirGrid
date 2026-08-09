import 'package:airgrid/core/constants.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';

/// Renders stored messages as a readable plain-text transcript.
///
/// Pure and platform-free, in the spirit of `feature_gates.dart`: everything
/// worth testing about the export lives here and needs no widget pump, no
/// database and no share sheet.
///
/// Plain text rather than JSON because of what this is for. Someone exporting a
/// conversation wants to read it, keep it, or hand it to somebody — and
/// `AirGridMessage` has no `toJson`, so JSON would mean inventing and then
/// maintaining a serialisation format for a file nobody reads.
///
/// Returns an empty string when [messages] is empty, leaving the caller to
/// decide what to say about it. A formatter that returned "no messages yet"
/// would be putting UI copy in the wrong layer, and the caller has to branch
/// anyway to avoid sharing an empty file.
String formatMessageHistory({
  required List<AirGridMessage> messages,
  required String deviceName,
  required String deviceNodeId,
  required DateTime exportedAt,
}) {
  if (messages.isEmpty) return '';

  final buffer = StringBuffer()
    ..writeln('AirGrid message history')
    ..writeln('Exported: ${_timestamp(exportedAt)}')
    ..writeln('Device: $deviceName ($deviceNodeId)')
    ..writeln('Messages: ${messages.length}')
    ..writeln()
    // Said plainly, because a short export otherwise reads as data loss. The
    // history is pruned on a schedule the user never sees, so the file has to
    // explain its own boundaries.
    ..writeln(
      'AirGrid keeps the last ${AirGridConstants.kChatMaxMessages} messages '
      'from the past ${AirGridConstants.kChatMaxAge.inDays} days. Anything '
      'older is no longer on this device.',
    );

  for (final section in _sections(messages)) {
    buffer
      ..writeln()
      ..writeln('==== ${section.title} ====')
      ..writeln();
    for (final message in section.messages) {
      buffer.writeln(_line(message, deviceName: deviceName));
    }
  }

  return buffer.toString();
}

/// One conversation's worth of the transcript.
class _Section {
  final String title;
  final List<AirGridMessage> messages;

  const _Section(this.title, this.messages);

  /// Newest message in the section, used only for ordering sections.
  DateTime get lastActivity => messages.last.timestamp;
}

/// Splits [messages] into the public bucket plus one bucket per peer.
///
/// Public comes first, then private threads with the most recent activity —
/// the same order the chat list uses, so the file reads the way the app looks.
/// Within a section messages run oldest-first, which is the opposite of
/// `loadRecent`'s newest-first and the reason this sorts rather than trusting
/// the caller's order.
List<_Section> _sections(List<AirGridMessage> messages) {
  final public = <AirGridMessage>[];
  final byPeer = <String, List<AirGridMessage>>{};

  for (final message in messages) {
    final peerNodeId = message.peerNodeId;
    if (message.conversationType == 'private' &&
        peerNodeId != null &&
        peerNodeId.isNotEmpty) {
      byPeer.putIfAbsent(peerNodeId, () => []).add(message);
    } else {
      public.add(message);
    }
  }

  int byTime(AirGridMessage a, AirGridMessage b) =>
      a.timestamp.compareTo(b.timestamp);

  final sections = <_Section>[];
  if (public.isNotEmpty) {
    public.sort(byTime);
    sections.add(_Section('Public mesh', public));
  }

  final private = <_Section>[];
  for (final entry in byPeer.entries) {
    entry.value.sort(byTime);
    private.add(
      _Section('Private: ${_peerLabel(entry.key, entry.value)}', entry.value),
    );
  }
  private.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));

  return [...sections, ...private];
}

/// Names a private thread.
///
/// Peers rename themselves, and the stored `peerName` is whatever they were
/// called at the time, so the most recent one wins. Falls back to the node id
/// rather than "Unknown": an id still identifies the thread, and this file may
/// be the only record left of it.
String _peerLabel(String peerNodeId, List<AirGridMessage> messages) {
  for (final message in messages.reversed) {
    final name = message.peerName?.trim();
    if (name != null && name.isNotEmpty) return '$name ($peerNodeId)';
  }
  return peerNodeId;
}

String _line(AirGridMessage message, {required String deviceName}) {
  final who = message.isLocal ? '$deviceName (you)' : message.senderName;
  final body = _body(message);
  final status = _status(message);

  final buffer = StringBuffer('[${_timestamp(message.timestamp)}] $who:');
  for (final line in body.split('\n')) {
    buffer.write('\n  $line');
  }
  if (status != null) buffer.write('\n  ($status)');
  return buffer.toString();
}

/// What the message actually said, or a description of what it carried.
///
/// Attachments are described rather than bundled. `mediaTempPath` is documented
/// as ephemeral — "may be null after restart" — so the bytes usually are not
/// there to attach, and a transcript that silently dropped every photo would be
/// worse than one that names them.
String _body(AirGridMessage message) {
  switch (message.messageKind) {
    case 'image':
      return '[photo${_sizeSuffix(message.mediaByteLength)}]';
    case 'audio':
      final duration = message.mediaDurationMs;
      final length = duration == null ? '' : ', ${_duration(duration)}';
      return '[voice note$length]';
    case 'file':
      final type = message.mediaMimeType;
      final detail = [
        if (type != null && type.isNotEmpty) type,
        if (message.mediaByteLength != null) _bytes(message.mediaByteLength!),
      ].join(', ');
      return detail.isEmpty ? '[file]' : '[file: $detail]';
    default:
      return message.content;
  }
}

/// Delivery state, for outgoing private messages only.
///
/// Public messages and received messages have no delivery model, and printing
/// "sent" against every line would be noise rather than information.
String? _status(AirGridMessage message) {
  if (!message.isLocal || message.conversationType != 'private') return null;
  return switch (message.deliveryStatus) {
    DeliveryStatus.pending => 'not sent yet',
    DeliveryStatus.sent => null,
    DeliveryStatus.delivered => 'delivered',
    DeliveryStatus.read => 'read',
    DeliveryStatus.failed => 'failed to send',
  };
}

String _sizeSuffix(int? byteLength) =>
    byteLength == null ? '' : ', ${_bytes(byteLength)}';

String _bytes(int byteLength) {
  if (byteLength < 1024) return '$byteLength B';
  if (byteLength < 1024 * 1024) return '${(byteLength / 1024).round()} KB';
  return '${(byteLength / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _duration(int milliseconds) {
  final totalSeconds = (milliseconds / 1000).round();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${_two(seconds)}';
}

/// `yyyy-MM-dd HH:mm` in local time.
///
/// Hand-rolled because `intl` is not a dependency, and adding a package to
/// print eight numbers would be a poor trade.
String _timestamp(DateTime time) {
  final local = time.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
}

String _two(int value) => value.toString().padLeft(2, '0');
