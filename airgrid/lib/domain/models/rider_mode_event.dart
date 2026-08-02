import 'dart:convert';
import 'dart:typed_data';

enum RiderControlAction { invite, accept, decline, end, mute, unmute }

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
      final action = RiderControlAction.values.firstWhere(
        (v) => v.name == actionRaw,
        orElse: () => RiderControlAction.invite,
      );
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
