import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class RiderAudioPlayback {
  Future<void> startPlayback({int sampleRate, int channels});
  Future<void> enqueuePcm(Uint8List pcm);
  Future<void> stopPlayback();
}

class RiderAudioBridge implements RiderAudioPlayback {
  const RiderAudioBridge();

  static const _channel = MethodChannel('com.airgrid/rider_audio');

  @override
  Future<void> startPlayback({int sampleRate = 8000, int channels = 1}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('startPlayback', {
      'sampleRate': sampleRate,
      'channels': channels,
    });
  }

  @override
  Future<void> enqueuePcm(Uint8List pcm) async {
    if (defaultTargetPlatform != TargetPlatform.android || pcm.isEmpty) return;
    await _channel.invokeMethod<void>('enqueuePcm', pcm);
  }

  @override
  Future<void> stopPlayback() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await _channel.invokeMethod<void>('stopPlayback');
  }
}

class NoopRiderAudioPlayback implements RiderAudioPlayback {
  const NoopRiderAudioPlayback();

  @override
  Future<void> startPlayback({int sampleRate = 8000, int channels = 1}) async {}

  @override
  Future<void> enqueuePcm(Uint8List pcm) async {}

  @override
  Future<void> stopPlayback() async {}
}
