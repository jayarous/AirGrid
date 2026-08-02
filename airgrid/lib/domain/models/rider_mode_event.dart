import 'dart:convert';
import 'dart:typed_data';

enum RiderControlAction { invite, accept, decline, end, mute, unmute }

/// Why an active Rider Mode session stopped.
///
/// Rider Mode has no screen the rider can safely look at, so the reason drives
/// an audible cue rather than a visual one.
enum RiderSessionEndReason {
  /// This device hung up.
  endedLocally,

  /// The peer sent an explicit [RiderControlAction.end].
  endedByPeer,

  /// The peer stopped answering: out of range, app killed, or battery dead.
  /// Nothing arrives on the wire in this case, so it is inferred by the
  /// keepalive watchdog or a transport disconnect.
  peerLost,
}

class RiderControlPayload {
  final RiderControlAction action;
  final String sessionId;
  final bool autoJoin;

  const RiderControlPayload({
    required this.action,
    required this.sessionId,
    this.autoJoin = false,
  });

  String toWire() => jsonEncode({
    'kind': 'rider_control',
    'action': action.name,
    'sessionId': sessionId,
    'autoJoin': autoJoin,
  });

  static RiderControlPayload? fromWire(String wire) {
    try {
      final decoded = jsonDecode(wire);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['kind'] != 'rider_control') return null;
      final actionRaw = decoded['action'] as String?;
      final sessionId = decoded['sessionId'] as String?;
      if (actionRaw == null || sessionId == null || sessionId.isEmpty) {
        return null;
      }
      // An unknown action must be dropped, never coerced. Coercing to `invite`
      // would let any future action pop an invite prompt on an older build.
      final action = RiderControlAction.values
          .cast<RiderControlAction?>()
          .firstWhere((v) => v!.name == actionRaw, orElse: () => null);
      if (action == null) return null;
      return RiderControlPayload(
        action: action,
        sessionId: sessionId,
        autoJoin: decoded['autoJoin'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Liveness ping for an active session.
///
/// In voice-activated mic mode no audio frames are sent while the rider is
/// quiet, so silence cannot be read as absence. This is sent on a fixed
/// interval regardless of mic mode to give the far end something to time out
/// against.
///
/// It rides inside a `rider_control` packet so routing needs no new packet
/// type, but carries a distinct wire `kind`: builds that predate this payload
/// parse it with [RiderControlPayload.fromWire], get null back because the kind
/// does not match, and drop it harmlessly.
class RiderKeepalivePayload {
  final String sessionId;

  const RiderKeepalivePayload({required this.sessionId});

  String toWire() =>
      jsonEncode({'kind': 'rider_keepalive', 'sessionId': sessionId});

  static RiderKeepalivePayload? fromWire(String wire) {
    try {
      final decoded = jsonDecode(wire);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['kind'] != 'rider_keepalive') return null;
      final sessionId = decoded['sessionId'] as String?;
      if (sessionId == null || sessionId.isEmpty) return null;
      return RiderKeepalivePayload(sessionId: sessionId);
    } catch (_) {
      return null;
    }
  }
}

class RiderAudioFramePayload {
  final String sessionId;
  final int sequence;
  final int sampleRate;
  final int channels;
  final Uint8List pcm;

  const RiderAudioFramePayload({
    required this.sessionId,
    required this.sequence,
    required this.sampleRate,
    required this.channels,
    required this.pcm,
  });

  String toWire() => jsonEncode({
    'kind': 'rider_audio_frame',
    'sessionId': sessionId,
    'sequence': sequence,
    'sampleRate': sampleRate,
    'channels': channels,
    'pcm': base64Encode(pcm),
  });

  static RiderAudioFramePayload? fromWire(String wire) {
    try {
      final decoded = jsonDecode(wire);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['kind'] != 'rider_audio_frame') return null;
      final sessionId = decoded['sessionId'] as String?;
      final sequence = decoded['sequence'] as int?;
      final sampleRate = decoded['sampleRate'] as int?;
      final channels = decoded['channels'] as int?;
      final pcmRaw = decoded['pcm'] as String?;
      if (sessionId == null ||
          sessionId.isEmpty ||
          sequence == null ||
          sampleRate == null ||
          channels == null ||
          pcmRaw == null) {
        return null;
      }
      return RiderAudioFramePayload(
        sessionId: sessionId,
        sequence: sequence,
        sampleRate: sampleRate,
        channels: channels,
        pcm: base64Decode(pcmRaw),
      );
    } catch (_) {
      return null;
    }
  }
}

sealed class RiderModeEvent {
  final String peerNodeId;
  final String peerName;

  const RiderModeEvent({required this.peerNodeId, required this.peerName});
}

class RiderControlEvent extends RiderModeEvent {
  final RiderControlPayload control;

  const RiderControlEvent({
    required super.peerNodeId,
    required super.peerName,
    required this.control,
  });
}

class RiderAudioFrameEvent extends RiderModeEvent {
  final RiderAudioFramePayload frame;

  const RiderAudioFrameEvent({
    required super.peerNodeId,
    required super.peerName,
    required this.frame,
  });
}

class RiderKeepaliveEvent extends RiderModeEvent {
  final RiderKeepalivePayload keepalive;

  const RiderKeepaliveEvent({
    required super.peerNodeId,
    required super.peerName,
    required this.keepalive,
  });
}
