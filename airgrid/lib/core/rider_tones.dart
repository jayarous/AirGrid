import 'dart:math' as math;
import 'dart:typed_data';

/// Short PCM16 cues for Rider Mode session transitions.
///
/// Rider Mode is used with a helmet on at speed, where there is no screen to
/// look at, so a session ending has to be *heard*. These are synthesised as
/// plain PCM and pushed through the existing playback path, which keeps the
/// cues on the same audio route as the peer's voice and needs no native code.
///
/// Frequencies sit in the 400-900 Hz band, which survives wind and engine
/// noise better than the higher beeps a phone would normally use.
class RiderTones {
  const RiderTones._();

  /// Rising pair: the session is live.
  static Uint8List sessionStarted({int sampleRate = 8000}) =>
      _render(const [_Step(587, 90), _Step(880, 150)], sampleRate);

  /// Falling pair: the other side hung up, or you did.
  static Uint8List sessionEnded({int sampleRate = 8000}) =>
      _render(const [_Step(880, 90), _Step(587, 190)], sampleRate);

  /// Three descending tones: the peer stopped answering. Deliberately longer
  /// and more distinct than [sessionEnded] — a clean hang-up and a peer that
  /// vanished mean different things to the rider.
  static Uint8List peerLost({int sampleRate = 8000}) => _render(const [
    _Step(587, 130),
    _Step(0, 70),
    _Step(494, 130),
    _Step(0, 70),
    _Step(392, 280),
  ], sampleRate);

  /// Playback duration of a cue produced by this class.
  static Duration durationOf(Uint8List pcm, {int sampleRate = 8000}) =>
      Duration(
        milliseconds: (pcm.lengthInBytes / 2 / sampleRate * 1000).round(),
      );

  static Uint8List _render(List<_Step> steps, int sampleRate) {
    final totalMs = steps.fold<int>(0, (sum, step) => sum + step.millis);
    final totalSamples = (sampleRate * totalMs / 1000).round();
    final bytes = Uint8List(totalSamples * 2);
    final view = ByteData.sublistView(bytes);

    // ~6 ms of ramp at each edge; without it the abrupt start and stop of the
    // waveform is audible as a click, which is worse than the tone itself.
    final rampSamples = math.max(1, (sampleRate * 0.006).round());
    const amplitude = 0.35 * 32767;

    var cursor = 0;
    for (final step in steps) {
      final stepSamples = (sampleRate * step.millis / 1000).round();
      for (var i = 0; i < stepSamples && cursor < totalSamples; i++, cursor++) {
        if (step.frequency == 0) continue; // silence between tones

        final envelope = math.min(
          1.0,
          math.min(i + 1, math.max(1, stepSamples - i)) / rampSamples,
        );
        final value =
            math.sin(2 * math.pi * step.frequency * i / sampleRate) *
            amplitude *
            envelope;
        view.setInt16(cursor * 2, value.round(), Endian.little);
      }
    }
    return bytes;
  }
}

class _Step {
  /// Hertz, or 0 for a gap.
  final int frequency;
  final int millis;

  const _Step(this.frequency, this.millis);
}
