import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:airgrid/core/foreground_service_bridge.dart';
import 'package:airgrid/core/rider_audio_bridge.dart';
import 'package:airgrid/data/storage/rider_mode_settings_store.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/models/rider_mode_event.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

const _riderSampleRate = 8000;
const _riderChannels = 1;
const _riderFrameBytes = 3200; // 200ms of mono PCM16 at 8kHz.
const _voiceRmsThreshold = 950.0;
const _voiceHangoverFrames = 6;
const _levelUpdateInterval = Duration(milliseconds: 250);
const _maxPendingPlaybackFrames = 12;

final riderModeSettingsStoreProvider = Provider<RiderModeSettingsStore>(
  (ref) => InMemoryRiderModeSettingsStore(),
);

final riderAudioPlaybackProvider = Provider<RiderAudioPlayback>(
  (ref) => const RiderAudioBridge(),
);

final riderModeControllerProvider =
    NotifierProvider<RiderModeController, RiderModeState>(
      RiderModeController.new,
    );

class RiderModeState {
  final RiderModeSettings settings;
  final bool isArmed;
  final bool isActive;
  final bool isStarting;
  final bool isMuted;
  final bool remoteMuted;
  final bool isSendingVoice;
  final double inputLevel;
  final String? peerNodeId;
  final String? peerName;
  final String? sessionId;
  final String? incomingPeerNodeId;
  final String? incomingPeerName;
  final String? incomingSessionId;
  final String? lastError;

  const RiderModeState({
    this.settings = const RiderModeSettings(),
    this.isArmed = false,
    this.isActive = false,
    this.isStarting = false,
    this.isMuted = false,
    this.remoteMuted = false,
    this.isSendingVoice = false,
    this.inputLevel = 0,
    this.peerNodeId,
    this.peerName,
    this.sessionId,
    this.incomingPeerNodeId,
    this.incomingPeerName,
    this.incomingSessionId,
    this.lastError,
  });

  RiderModeState copyWith({
    RiderModeSettings? settings,
    bool? isArmed,
    bool? isActive,
    bool? isStarting,
    bool? isMuted,
    bool? remoteMuted,
    bool? isSendingVoice,
    double? inputLevel,
    String? peerNodeId,
    String? peerName,
    String? sessionId,
    String? incomingPeerNodeId,
    String? incomingPeerName,
    String? incomingSessionId,
    String? lastError,
    bool clearPeer = false,
    bool clearIncoming = false,
    bool clearLastError = false,
  }) {
    return RiderModeState(
      settings: settings ?? this.settings,
      isArmed: isArmed ?? this.isArmed,
      isActive: isActive ?? this.isActive,
      isStarting: isStarting ?? this.isStarting,
      isMuted: isMuted ?? this.isMuted,
      remoteMuted: remoteMuted ?? this.remoteMuted,
      isSendingVoice: isSendingVoice ?? this.isSendingVoice,
      inputLevel: inputLevel ?? this.inputLevel,
      peerNodeId: clearPeer ? null : peerNodeId ?? this.peerNodeId,
      peerName: clearPeer ? null : peerName ?? this.peerName,
      sessionId: clearPeer ? null : sessionId ?? this.sessionId,
      incomingPeerNodeId: clearIncoming
          ? null
          : incomingPeerNodeId ?? this.incomingPeerNodeId,
      incomingPeerName: clearIncoming
          ? null
          : incomingPeerName ?? this.incomingPeerName,
      incomingSessionId: clearIncoming
          ? null
          : incomingSessionId ?? this.incomingSessionId,
      lastError: clearLastError ? null : lastError ?? this.lastError,
    );
  }
}

class RiderModeController extends Notifier<RiderModeState> {
  final _recorder = AudioRecorder();
  final _pendingPlayback = SplayTreeMap<int, RiderAudioFramePayload>();
  final _captureBuffer = BytesBuilder(copy: false);
  StreamSubscription<RiderModeEvent>? _riderSub;
  StreamSubscription<RiderModeSettings>? _settingsSub;
  StreamSubscription<void>? _muteSub;
  StreamSubscription<void>? _endSub;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _playbackTimer;
  RiderAudioPlayback? _playback;
  int _sendSequence = 0;
  int _expectedPlaybackSequence = 0;
  int _voiceHangover = 0;
  bool _frameSendInFlight = false;
  DateTime _lastLevelUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  RiderModeState build() {
    final settingsStore = ref.read(riderModeSettingsStoreProvider);
    _playback = ref.read(riderAudioPlaybackProvider);
    _settingsSub = settingsStore.settingsStream.listen((settings) {
      state = state.copyWith(settings: settings);
    });
    _riderSub = _mesh.riderEvents.listen(_handleRiderEvent);
    _muteSub = _foreground.riderMuteRequests.listen((_) {
      unawaited(setMuted(!state.isMuted));
    });
    _endSub = _foreground.riderEndRequests.listen((_) {
      unawaited(endSession());
    });
    ref.onDispose(() {
      _settingsSub?.cancel();
      _riderSub?.cancel();
      _muteSub?.cancel();
      _endSub?.cancel();
      _playbackTimer?.cancel();
      unawaited(_micSub?.cancel());
      unawaited(_recorder.dispose());
      unawaited(_playback?.stopPlayback());
    });
    return RiderModeState(settings: settingsStore.current);
  }

  AirGridMeshService get _mesh => ref.read(meshServiceProvider);
  MeshForegroundService get _foreground => ref.read(foregroundServiceProvider);
  RiderAudioPlayback get _audio =>
      _playback ?? ref.read(riderAudioPlaybackProvider);

  Future<void> setMicMode(RiderMicMode mode) async {
    await ref
        .read(riderModeSettingsStoreProvider)
        .save(state.settings.copyWith(micMode: mode));
  }

  Future<void> setStartPolicy(RiderStartPolicy policy) async {
    await ref
        .read(riderModeSettingsStoreProvider)
        .save(state.settings.copyWith(startPolicy: policy));
  }

  Future<void> armPresence(bool armed) async {
    state = state.copyWith(isArmed: armed);
    await _publishPresence(armed: armed);
  }

  Future<void> startSession(MeshPeer peer) async {
    if (state.isStarting || state.isActive) return;
    final nodeId = peer.nodeId;
    if (nodeId == null) return;
    if (!_canUseRiderWith(nodeId, peer)) {
      state = state.copyWith(lastError: 'Trust this online peer first');
      return;
    }

    final sessionId = const Uuid().v4();
    state = state.copyWith(
      isStarting: true,
      isArmed: true,
      peerNodeId: nodeId,
      peerName: peer.displayName,
      sessionId: sessionId,
      clearLastError: true,
    );
    await _publishPresence(armed: true);

    final sent = await _mesh.sendRiderControl(
      peer: peer,
      control: RiderControlPayload(
        action: RiderControlAction.invite,
        sessionId: sessionId,
        autoJoin:
            state.settings.startPolicy == RiderStartPolicy.trustedAutoJoin,
      ),
    );
    if (!sent) {
      state = state.copyWith(
        isStarting: false,
        lastError: 'Failed to start Rider Mode',
        clearPeer: true,
      );
      return;
    }

    if (state.settings.startPolicy == RiderStartPolicy.trustedAutoJoin) {
      await _activate(peer, sessionId);
    }
  }

  Future<void> acceptIncoming() async {
    final peerNodeId = state.incomingPeerNodeId;
    final sessionId = state.incomingSessionId;
    if (peerNodeId == null || sessionId == null) return;
    final peer = _peerByNodeId(peerNodeId);
    if (peer == null || !_canUseRiderWith(peerNodeId, peer)) return;
    await _mesh.sendRiderControl(
      peer: peer,
      control: RiderControlPayload(
        action: RiderControlAction.accept,
        sessionId: sessionId,
      ),
    );
    await _activate(peer, sessionId);
    state = state.copyWith(clearIncoming: true);
  }

  Future<void> declineIncoming() async {
    final peerNodeId = state.incomingPeerNodeId;
    final sessionId = state.incomingSessionId;
    final peer = _peerByNodeId(peerNodeId);
    if (peer != null && sessionId != null) {
      await _mesh.sendRiderControl(
        peer: peer,
        control: RiderControlPayload(
          action: RiderControlAction.decline,
          sessionId: sessionId,
        ),
      );
    }
    state = state.copyWith(clearIncoming: true);
  }

  Future<void> endSession({bool notifyPeer = true}) async {
    final peer = _peerByNodeId(state.peerNodeId);
    final sessionId = state.sessionId;
    await _stopCapture();
    await _audio.stopPlayback();
    await _foreground.stopRiderService();
    if (notifyPeer && peer != null && sessionId != null) {
      await _mesh.sendRiderControl(
        peer: peer,
        control: RiderControlPayload(
          action: RiderControlAction.end,
          sessionId: sessionId,
        ),
      );
    }
    state = state.copyWith(
      isActive: false,
      isStarting: false,
      isMuted: false,
      remoteMuted: false,
      isSendingVoice: false,
      inputLevel: 0,
      clearPeer: true,
      clearIncoming: true,
    );
    await _publishPresence(armed: false);
  }

  Future<void> setMuted(bool muted) async {
    state = state.copyWith(isMuted: muted, isSendingVoice: false);
    final peer = _peerByNodeId(state.peerNodeId);
    final sessionId = state.sessionId;
    if (peer != null && sessionId != null) {
      await _mesh.sendRiderControl(
        peer: peer,
        control: RiderControlPayload(
          action: muted ? RiderControlAction.mute : RiderControlAction.unmute,
          sessionId: sessionId,
        ),
      );
    }
    await _foreground.updateRiderServiceMuted(muted);
  }

  Future<void> _handleRiderEvent(RiderModeEvent event) async {
    if (event is RiderControlEvent) {
      await _handleControl(event);
      return;
    }
    if (event is RiderAudioFrameEvent) {
      if (!state.isActive ||
          state.peerNodeId != event.peerNodeId ||
          state.sessionId != event.frame.sessionId) {
        return;
      }
      _pendingPlayback[event.frame.sequence] = event.frame;
      while (_pendingPlayback.length > _maxPendingPlaybackFrames) {
        _pendingPlayback.remove(_pendingPlayback.firstKey());
      }
    }
  }

  Future<void> _handleControl(RiderControlEvent event) async {
    final peer = _peerByNodeId(event.peerNodeId);
    if (peer == null) return;

    switch (event.control.action) {
      case RiderControlAction.invite:
        final canAutoJoin =
            event.control.autoJoin &&
            state.settings.startPolicy == RiderStartPolicy.trustedAutoJoin &&
            _canUseRiderWith(event.peerNodeId, peer);
        if (canAutoJoin) {
          await _mesh.sendRiderControl(
            peer: peer,
            control: RiderControlPayload(
              action: RiderControlAction.accept,
              sessionId: event.control.sessionId,
            ),
          );
          await _activate(peer, event.control.sessionId);
        } else {
          state = state.copyWith(
            incomingPeerNodeId: event.peerNodeId,
            incomingPeerName: event.peerName,
            incomingSessionId: event.control.sessionId,
          );
        }
        return;
      case RiderControlAction.accept:
        if (state.sessionId == event.control.sessionId) {
          await _activate(peer, event.control.sessionId);
        }
        return;
      case RiderControlAction.decline:
      case RiderControlAction.end:
        if (state.sessionId == event.control.sessionId) {
          await endSession(notifyPeer: false);
        }
        return;
      case RiderControlAction.mute:
        state = state.copyWith(remoteMuted: true);
        return;
      case RiderControlAction.unmute:
        state = state.copyWith(remoteMuted: false);
        return;
    }
  }

  Future<void> _activate(MeshPeer peer, String sessionId) async {
    if (state.isActive && state.sessionId == sessionId) return;
    final micPermission = await Permission.microphone.request();
    if (!micPermission.isGranted) {
      state = state.copyWith(
        isStarting: false,
        lastError: 'Microphone permission denied',
      );
      return;
    }

    await _audio.startPlayback(sampleRate: _riderSampleRate, channels: 1);
    await _foreground.startRiderService(
      peerName: peer.displayName,
      muted: state.isMuted,
    );
    state = state.copyWith(
      isActive: true,
      isStarting: false,
      isArmed: true,
      peerNodeId: peer.nodeId,
      peerName: peer.displayName,
      sessionId: sessionId,
      clearLastError: true,
    );
    _expectedPlaybackSequence = 0;
    _pendingPlayback.clear();
    _startPlaybackLoop();
    await _startCapture(peer, sessionId);
    await _publishPresence(armed: true);
  }

  Future<void> _startCapture(MeshPeer peer, String sessionId) async {
    await _stopCapture();
    _sendSequence = 0;
    _captureBuffer.clear();
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _riderSampleRate,
        numChannels: _riderChannels,
        echoCancel: true,
        noiseSuppress: true,
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.voiceCommunication,
        ),
      ),
    );
    _micSub = stream.listen((chunk) => _handleMicChunk(peer, sessionId, chunk));
  }

  Future<void> _stopCapture() async {
    await _micSub?.cancel();
    _micSub = null;
    _frameSendInFlight = false;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
  }

  void _handleMicChunk(MeshPeer peer, String sessionId, Uint8List chunk) {
    _captureBuffer.add(chunk);
    var bytes = _captureBuffer.toBytes();
    while (bytes.length >= _riderFrameBytes) {
      final frame = Uint8List.fromList(bytes.sublist(0, _riderFrameBytes));
      final remaining = bytes.sublist(_riderFrameBytes);
      _captureBuffer.clear();
      _captureBuffer.add(remaining);
      bytes = remaining;
      unawaited(_sendFrameIfAllowed(peer, sessionId, frame));
    }
  }

  Future<void> _sendFrameIfAllowed(
    MeshPeer peer,
    String sessionId,
    Uint8List frame,
  ) async {
    final rms = _rms(frame);
    final normalized = (rms / 6000.0).clamp(0.0, 1.0);
    var shouldSend = !state.isMuted;
    if (state.settings.micMode == RiderMicMode.voiceActivated) {
      final speaking = rms >= _voiceRmsThreshold;
      if (speaking) {
        _voiceHangover = _voiceHangoverFrames;
      } else if (_voiceHangover > 0) {
        _voiceHangover--;
      }
      shouldSend = shouldSend && (speaking || _voiceHangover > 0);
    }

    final now = DateTime.now();
    if (now.difference(_lastLevelUpdate) >= _levelUpdateInterval) {
      _lastLevelUpdate = now;
      state = state.copyWith(inputLevel: normalized, isSendingVoice: shouldSend);
    }
    if (!shouldSend) return;
    if (_frameSendInFlight) return;

    _frameSendInFlight = true;
    try {
      await _mesh.sendRiderAudioFrame(
        peer: peer,
        frame: RiderAudioFramePayload(
          sessionId: sessionId,
          sequence: _sendSequence++,
          sampleRate: _riderSampleRate,
          channels: _riderChannels,
          pcm: frame,
        ),
      );
    } finally {
      _frameSendInFlight = false;
    }
  }

  void _startPlaybackLoop() {
    _playbackTimer?.cancel();
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      final frame = _pendingPlayback.remove(_expectedPlaybackSequence);
      if (frame != null) {
        _expectedPlaybackSequence++;
        unawaited(_audio.enqueuePcm(frame.pcm));
        return;
      }

      if (_pendingPlayback.length > 8) {
        final firstKey = _pendingPlayback.firstKey()!;
        _expectedPlaybackSequence = firstKey + 1;
        final recovered = _pendingPlayback.remove(firstKey);
        if (recovered != null) {
          unawaited(_audio.enqueuePcm(recovered.pcm));
        }
      }
    });
  }

  double _rms(Uint8List pcm) {
    if (pcm.length < 2) return 0;
    var sumSquares = 0.0;
    var samples = 0;
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      final value = ByteData.sublistView(
        pcm,
        i,
        i + 2,
      ).getInt16(0, Endian.little);
      sumSquares += value * value;
      samples++;
    }
    if (samples == 0) return 0;
    return math.sqrt(sumSquares / samples);
  }

  bool _canUseRiderWith(String nodeId, MeshPeer peer) {
    final chatState = ref.read(chatControllerProvider);
    final contact = chatState.knownContacts.cast<dynamic>().firstWhere(
      (c) => c.nodeId == nodeId,
      orElse: () => null,
    );
    return contact != null &&
        contact.isTrusted == true &&
        contact.isBlocked != true &&
        peer.nodeId != null;
  }

  MeshPeer? _peerByNodeId(String? nodeId) {
    if (nodeId == null) return null;
    return ref
        .read(chatControllerProvider)
        .peers
        .cast<MeshPeer?>()
        .firstWhere((peer) => peer?.nodeId == nodeId, orElse: () => null);
  }

  Future<void> _publishPresence({required bool armed}) async {
    await _mesh.sendKeyAnnounce(
      extraMeta: {'riderSupported': true, 'riderArmed': armed},
    );
  }
}
