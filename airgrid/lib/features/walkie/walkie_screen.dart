import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/constants.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:airgrid/features/walkie/public_walkie_status_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

class WalkieScreen extends ConsumerStatefulWidget {
  const WalkieScreen({super.key});

  @override
  ConsumerState<WalkieScreen> createState() => _WalkieScreenState();
}

class _WalkieScreenState extends ConsumerState<WalkieScreen>
    with SingleTickerProviderStateMixin {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final DateTime _openedAt = DateTime.now();
  final Stopwatch _holdStopwatch = Stopwatch();
  final Set<String> _handledIncomingWalkieIds = <String>{};
  late final FixedExtentScrollController _channelWheelController;
  late final AnimationController _speakerPulseController;
  late final Animation<double> _speakerPulse;
  Timer? _channelDetentFlashTimer;
  Timer? _ticker;
  AudioPlayer? _incomingPlayer;

  Duration _elapsed = Duration.zero;
  String? _status;
  bool _channelDetentFlash = false;
  bool _chatLaunchFlash = false;
  int _lastChannelWheelIndex = 0;

  /// When true the user is in open public-channel broadcast mode.
  /// When false (default) the private invite/session flow is active.
  bool _isPublicMode = false;

  @override
  void initState() {
    super.initState();
    _lastChannelWheelIndex = _isPublicMode ? 1 : 0;
    _channelWheelController = FixedExtentScrollController(
      initialItem: _isPublicMode ? 1 : 0,
    );
    _speakerPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 760),
    );
    _speakerPulse = CurvedAnimation(
      parent: _speakerPulseController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _channelDetentFlashTimer?.cancel();
    _ticker?.cancel();
    unawaited(_incomingPlayer?.dispose() ?? Future<void>.value());
    unawaited(_audioRecorder.dispose());
    _speakerPulseController.dispose();
    _channelWheelController.dispose();
    super.dispose();
  }

  void _syncSpeakerPulse(bool active) {
    if (active) {
      if (!_speakerPulseController.isAnimating) {
        _speakerPulseController.repeat(reverse: true);
      }
      return;
    }
    if (_speakerPulseController.isAnimating ||
        _speakerPulseController.value != 0) {
      _speakerPulseController.stop();
      _speakerPulseController.value = 0;
    }
  }

  void _triggerChannelDetentFeedback() {
    _triggerButtonFeedback();
    if (!mounted) return;
    _channelDetentFlashTimer?.cancel();
    setState(() {
      _channelDetentFlash = true;
    });
    _channelDetentFlashTimer = Timer(const Duration(milliseconds: 110), () {
      if (!mounted) return;
      setState(() {
        _channelDetentFlash = false;
      });
    });
  }

  void _triggerButtonFeedback() {
    HapticFeedback.selectionClick();
    SystemSound.play(SystemSoundType.click);
  }

  String? _currentTargetNodeId() {
    final state = ref.read(chatControllerProvider);
    final selected = state.selectedConversation;
    if (selected is PrivateConversation) {
      return selected.peerNodeId;
    }
    return state.walkiePeerNodeId;
  }

  Future<void> _handleIncomingWalkieUpdates(
    List<AirGridMessage>? previous,
    List<AirGridMessage> next,
  ) async {
    if (previous == null) return;

    final state = ref.read(chatControllerProvider);
    final selected = state.selectedConversation;
    if (state.publicWalkieStayOnline ||
        (selected is PrivateConversation &&
            state.knownContacts.any(
              (contact) =>
                  contact.nodeId == selected.peerNodeId &&
                  contact.isTrusted &&
                  contact.walkieAlwaysOn,
            ))) {
      return;
    }

    final previousIds = previous.map((m) => m.id).toSet();
    AirGridMessage? incoming;

    if (_isPublicMode) {
      // Public channel: play any new public walkie audio from any peer.
      for (final message in next) {
        if (!previousIds.contains(message.id) &&
            !_handledIncomingWalkieIds.contains(message.id) &&
            !message.isLocal &&
            message.conversationType == 'public' &&
            message.messageKind == 'audio' &&
            message.content == '[walkie]' &&
            message.timestamp.isAfter(_openedAt)) {
          incoming = message;
          break;
        }
      }
    } else {
      final targetNodeId = _currentTargetNodeId();
      if (targetNodeId == null || targetNodeId.isEmpty) return;

      // Drop incoming audio if no active session with this peer.
      final activeSessionNodeId = ref
          .read(chatControllerProvider)
          .walkieSessionActivePeerNodeId;
      if (activeSessionNodeId != targetNodeId) return;

      for (final message in next) {
        final shouldHandle =
            !previousIds.contains(message.id) &&
            !_handledIncomingWalkieIds.contains(message.id) &&
            !message.isLocal &&
            message.conversationType == 'private' &&
            message.messageKind == 'audio' &&
            message.content == '[walkie]' &&
            message.peerNodeId == targetNodeId &&
            message.timestamp.isAfter(_openedAt);
        if (shouldHandle) {
          incoming = message;
          break;
        }
      }
    }

    if (incoming == null) return;

    _handledIncomingWalkieIds.add(incoming.id);
    if (_handledIncomingWalkieIds.length > 200) {
      _handledIncomingWalkieIds.remove(_handledIncomingWalkieIds.first);
    }

    await _playIncomingWalkie(incoming);
  }

  Future<void> _playIncomingWalkie(AirGridMessage message) async {
    final senderName = message.peerName ?? message.senderName;
    final controller = ref.read(chatControllerProvider.notifier);
    if (!mounted) return;
    controller.setWalkieLastError(null);
    setState(() {
      _status = 'Incoming walkie from $senderName';
    });

    final path = message.mediaTempPath;
    if (path == null || path.isEmpty) {
      controller.setWalkieLastError('Incoming walkie audio unavailable');
      await controller.discardWalkieMessage(message.id, deleteTempFile: false);
      if (!mounted) return;
      setState(() {
        _status = 'Incoming walkie audio unavailable';
      });
      return;
    }

    try {
      final player = _incomingPlayer ??= AudioPlayer();
      await player.stop();
      await player.setFilePath(path);
      await player.play();
      await controller.discardWalkieMessage(message.id);
      if (!mounted) return;
      setState(() {
        _status = 'Played walkie from $senderName';
      });
    } catch (_) {
      controller.setWalkieLastError('Failed to play incoming walkie');
      await controller.discardWalkieMessage(message.id);
      if (!mounted) return;
      setState(() {
        _status = 'Failed to play incoming walkie';
      });
    }
  }

  PrivateConversation? _currentTarget() {
    final state = ref.read(chatControllerProvider);
    final selected = state.selectedConversation;
    if (selected is PrivateConversation) {
      return selected;
    }

    final firstOnline = state.peers.cast<MeshPeer?>().firstWhere(
      (peer) => peer?.nodeId != null,
      orElse: () => null,
    );
    if (firstOnline == null || firstOnline.nodeId == null) {
      return null;
    }

    final target = PrivateConversation(
      peerNodeId: firstOnline.nodeId!,
      peerName: firstOnline.displayName,
    );
    ref.read(chatControllerProvider.notifier).selectConversation(target);
    return target;
  }

  MeshPeer? _peerByNodeId(String? nodeId) {
    if (nodeId == null) return null;
    final state = ref.read(chatControllerProvider);
    return state.peers.cast<MeshPeer?>().firstWhere(
      (peer) => peer?.nodeId == nodeId,
      orElse: () => null,
    );
  }

  Future<void> _invitePeer(MeshPeer peer) async {
    final ok = await ref
        .read(chatControllerProvider.notifier)
        .sendWalkieInvite(peer);
    if (!mounted) return;
    setState(() {
      _status = ok
          ? 'Invite sent to ${peer.displayName}'
          : 'Failed to send invite';
    });
  }

  Future<void> _autoStartPrivateWalkieIfEnabled(
    PrivateConversation target,
  ) async {
    final state = ref.read(chatControllerProvider);
    final contact = state.knownContacts.cast<KnownContact?>().firstWhere(
      (item) => item?.nodeId == target.peerNodeId,
      orElse: () => null,
    );
    if (contact == null || !contact.isTrusted || !contact.walkieAlwaysOn) {
      return;
    }
    if (state.walkieInvitePeerNodeId == target.peerNodeId ||
        state.walkieSessionActivePeerNodeId == target.peerNodeId) {
      return;
    }

    final peer = _peerByNodeId(target.peerNodeId);
    if (peer == null) return;
    await _invitePeer(peer);
  }

  Future<void> _chooseTarget() async {
    final state = ref.read(chatControllerProvider);
    final candidates = state.peers
        .where((peer) => peer.nodeId != null)
        .toList();
    if (candidates.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No online private peers available yet.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final selectedNodeId = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Choose walkie target')),
            for (final peer in candidates)
              ListTile(
                leading: Icon(
                  Icons.person,
                  color: peer.nodeId != null ? Colors.green : null,
                ),
                title: Text(peer.displayName),
                subtitle: Text(
                  peer.nodeId ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: peer.nodeId != null
                    ? TextButton(
                        onPressed: () =>
                            Navigator.of(ctx).pop('invite:${peer.nodeId}'),
                        child: const Text('Invite'),
                      )
                    : const Text('Offline'),
                onTap: () => Navigator.of(ctx).pop(peer.nodeId),
              ),
          ],
        ),
      ),
    );

    if (selectedNodeId == null) return;

    if (selectedNodeId.startsWith('invite:')) {
      final peerNodeId = selectedNodeId.substring('invite:'.length);
      final selectedPeer = candidates.cast<MeshPeer?>().firstWhere(
        (peer) => peer?.nodeId == peerNodeId,
        orElse: () => null,
      );
      if (selectedPeer == null) return;
      await _invitePeer(selectedPeer);
      return;
    }

    final selectedPeer = candidates.cast<MeshPeer?>().firstWhere(
      (peer) => peer?.nodeId == selectedNodeId,
      orElse: () => null,
    );
    if (selectedPeer == null) return;

    ref
        .read(chatControllerProvider.notifier)
        .selectConversation(
          PrivateConversation(
            peerNodeId: selectedNodeId,
            peerName: selectedPeer.displayName,
          ),
        );

    await _autoStartPrivateWalkieIfEnabled(
      PrivateConversation(
        peerNodeId: selectedNodeId,
        peerName: selectedPeer.displayName,
      ),
    );
  }

  Future<void> _startHoldRecording() async {
    final current = ref.read(chatControllerProvider);
    if (current.walkieIsTransmitting || current.walkieIsSending) return;

    String? peerNodeIdForSession;
    if (!_isPublicMode) {
      final target = _currentTarget();
      if (target == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Select an online private peer first.'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }

      if (current.walkieSessionActivePeerNodeId != target.peerNodeId) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No active walkie session. Invite and wait for accept.',
            ),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
      peerNodeIdForSession = target.peerNodeId;

      final contact = current.knownContacts.cast<KnownContact?>().firstWhere(
        (item) => item?.nodeId == target.peerNodeId,
        orElse: () => null,
      );
      if (contact != null && contact.isTrusted && contact.walkieAlwaysOn) {
        if (current.walkieInvitePeerNodeId != target.peerNodeId &&
            current.walkieSessionActivePeerNodeId != target.peerNodeId) {
          final peer = _peerByNodeId(target.peerNodeId);
          if (peer != null) {
            unawaited(_invitePeer(peer));
          }
        }
      }
    }

    final micPermission = await Permission.microphone.request();
    if (!micPermission.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Microphone permission denied.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final hasRecordPermission = await _audioRecorder.hasPermission();
    if (!hasRecordPermission) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Microphone permission denied.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final filePath =
        '${tempDir.path}${Platform.pathSeparator}airgrid_walkie_${const Uuid().v4()}.m4a';

    try {
      await _audioRecorder.start(
        const RecordConfig(bitRate: 24000, sampleRate: 16000),
        path: filePath,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to start walkie recording.'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    _ticker?.cancel();
    _holdStopwatch
      ..reset()
      ..start();
    if (!mounted) return;
    ref
        .read(chatControllerProvider.notifier)
        .setWalkieTransmitting(
          isTransmitting: true,
          peerNodeId: peerNodeIdForSession,
        );
    ref.read(chatControllerProvider.notifier).setWalkieLastError(null);
    setState(() {
      _elapsed = Duration.zero;
      _status = 'Transmitting... release to send';
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || !ref.read(chatControllerProvider).walkieIsTransmitting) {
        return;
      }
      setState(() {
        _elapsed = _holdStopwatch.elapsed;
      });
    });
  }

  Future<void> _cancelHoldRecording() async {
    if (!ref.read(chatControllerProvider).walkieIsTransmitting) return;
    _ticker?.cancel();
    _ticker = null;
    _holdStopwatch
      ..stop()
      ..reset();

    String? path;
    try {
      path = await _audioRecorder.stop();
    } catch (_) {
      path = null;
    }

    if (path != null && path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Best-effort cleanup only.
      }
    }

    if (!mounted) return;
    ref
        .read(chatControllerProvider.notifier)
        .setWalkieTransmitting(isTransmitting: false);
    setState(() {
      _elapsed = Duration.zero;
      _status = 'Canceled';
    });
  }

  Future<void> _stopHoldAndSend() async {
    final current = ref.read(chatControllerProvider);
    if (!current.walkieIsTransmitting || current.walkieIsSending) return;

    _ticker?.cancel();
    _ticker = null;
    _holdStopwatch.stop();
    final duration = _holdStopwatch.elapsed;
    _holdStopwatch.reset();

    if (!mounted) return;
    ref
        .read(chatControllerProvider.notifier)
        .setWalkieTransmitting(isTransmitting: false);
    ref.read(chatControllerProvider.notifier).setWalkieSending(isSending: true);
    setState(() {
      _status = 'Sending...';
    });

    String? recordedPath;
    try {
      recordedPath = await _audioRecorder.stop();
    } catch (_) {
      recordedPath = null;
    }

    if (recordedPath == null || recordedPath.isEmpty) {
      if (!mounted) return;
      ref
          .read(chatControllerProvider.notifier)
          .setWalkieSending(isSending: false);
      ref
          .read(chatControllerProvider.notifier)
          .setWalkieLastError('Recording unavailable');
      setState(() {
        _status = 'Recording unavailable';
      });
      return;
    }

    try {
      if (duration < AirGridConstants.kWalkieMinDuration) {
        throw const _WalkieSendException('Clip too short');
      }
      if (duration > AirGridConstants.kWalkieMaxDuration) {
        throw _WalkieSendException(
          'Clip too long (max ${AirGridConstants.kWalkieMaxDuration.inSeconds}s)',
        );
      }

      final file = File(recordedPath);
      if (!await file.exists()) {
        throw const _WalkieSendException('Recorded file missing');
      }

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > AirGridConstants.kWalkieMaxBytes) {
        throw const _WalkieSendException('Clip exceeds size limit');
      }

      final payload = AudioAttachmentPayload(
        transferId: const Uuid().v4(),
        mimeType: 'audio/m4a',
        byteLength: bytes.length,
        durationMs: duration.inMilliseconds,
        source: AudioAttachmentPayload.sourceWalkie,
        dataBase64: base64Encode(bytes),
        localTempPath: recordedPath,
      );

      final controller = ref.read(chatControllerProvider.notifier);
      if (_isPublicMode) {
        try {
          await controller.sendPublicWalkieAudio(payload);
        } on StateError catch (e) {
          throw _WalkieSendException(e.message);
        }
        if (!mounted) return;
        ref
            .read(chatControllerProvider.notifier)
            .setWalkieSending(isSending: false);
        ref.read(chatControllerProvider.notifier).setWalkieLastError(null);
        setState(() {
          _status = 'Sent ${_formatDuration(duration)}';
        });
        return;
      }
      final selectedState = ref.read(chatControllerProvider);
      final conv = selectedState.selectedConversation;
      if (conv is! PrivateConversation) {
        throw const _WalkieSendException('Choose a private target first');
      }

      final meshReady = await controller.waitForMeshReady();
      if (!meshReady) {
        throw const _WalkieSendException('Mesh is reconnecting');
      }

      final online = await controller.waitForPeerOnline(
        conv.peerNodeId,
        timeout: const Duration(seconds: 8),
      );
      if (!online) {
        throw const _WalkieSendException('Peer is not online');
      }

      final refreshedState = ref.read(chatControllerProvider);
      final peer = refreshedState.peers.cast<MeshPeer?>().firstWhere(
        (item) => item?.nodeId == conv.peerNodeId,
        orElse: () => null,
      );

      final result = peer != null
          ? await controller.sendPrivateAudio(peer, payload)
          : await _sendToKnownContact(
              conv.peerNodeId,
              payload,
              refreshedState.knownContacts,
              controller,
            );

      final sent =
          result == PrivateSendResult.sentEncrypted ||
          result == PrivateSendResult.sentPlaintext;
      if (!sent) {
        throw _WalkieSendException(
          result == PrivateSendResult.needsPlaintextConfirmation
              ? 'Encryption key not ready yet'
              : 'Send failed',
        );
      }

      if (!mounted) return;
      ref
          .read(chatControllerProvider.notifier)
          .setWalkieSending(isSending: false);
      ref.read(chatControllerProvider.notifier).setWalkieLastError(null);
      setState(() {
        _status = 'Sent ${_formatDuration(duration)}';
      });
    } on _WalkieSendException catch (e) {
      if (!mounted) return;
      ref
          .read(chatControllerProvider.notifier)
          .setWalkieSending(isSending: false);
      ref.read(chatControllerProvider.notifier).setWalkieLastError(e.message);
      setState(() {
        _status = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      ref
          .read(chatControllerProvider.notifier)
          .setWalkieSending(isSending: false);
      ref
          .read(chatControllerProvider.notifier)
          .setWalkieLastError('Failed to send');
      setState(() {
        _status = 'Failed to send';
      });
    }
  }

  Future<PrivateSendResult> _sendToKnownContact(
    String nodeId,
    AudioAttachmentPayload payload,
    List<KnownContact> contacts,
    ChatController controller,
  ) async {
    final contact = contacts.cast<KnownContact?>().firstWhere(
      (item) => item?.nodeId == nodeId,
      orElse: () => null,
    );
    if (contact == null) {
      return PrivateSendResult.peerUnavailable;
    }
    return controller.sendPrivateAudioToContact(contact, payload);
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  static const Color _radioAmber = Color(0xFFFFA126);
  static const Color _radioShell = Color(0xFF343A41);
  static const Color _radioShellDark = Color(0xFF1B1E24);

  Widget _buildLatchingPushButton({
    required bool isOn,
    required bool enabled,
    required String hintText,
    required bool openChatEnabled,
    required bool chatLaunchFlash,
    required Color pingDotColor,
    required bool pingEnabled,
    required VoidCallback? onPressed,
    required VoidCallback? onOpenChat,
    required VoidCallback? onPing,
  }) {
    final indicatorColor = isOn
        ? const Color(0xFF57D163)
        : enabled
        ? _radioAmber
        : Colors.grey.shade500;
    final buttonFill = isOn ? const Color(0xFF2E4A35) : const Color(0xFF2C333D);
    final buttonTextColor = isOn ? Colors.white : Colors.white.withAlpha(220);
    final chatDotColor = chatLaunchFlash
        ? const Color(0xFF57D163)
        : openChatEnabled
        ? _radioAmber
        : Colors.grey.shade500;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              hintText,
              style: TextStyle(
                color: Colors.white.withAlpha(enabled ? 180 : 120),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 146,
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  margin: EdgeInsets.only(
                    top: isOn ? 3 : 0,
                    bottom: isOn ? 0 : 3,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: buttonFill,
                    border: Border.all(
                      color: isOn ? Colors.white54 : Colors.white24,
                    ),
                    boxShadow: isOn
                        ? [
                            BoxShadow(
                              color: indicatorColor.withAlpha(90),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ]
                        : [
                            BoxShadow(
                              color: Colors.black.withAlpha(70),
                              blurRadius: 10,
                              offset: const Offset(0, 5),
                            ),
                          ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: enabled ? onPressed : null,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Text(
                                    'ONLINE',
                                    style: TextStyle(
                                      color: buttonTextColor,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Positioned(
                                    right: 6,
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: indicatorColor,
                                        boxShadow: [
                                          BoxShadow(
                                            color: indicatorColor.withAlpha(
                                              130,
                                            ),
                                            blurRadius: 6,
                                            spreadRadius: 1,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: const Color(0xFF2C333D),
                    border: Border.all(color: Colors.white24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(70),
                        blurRadius: 10,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: openChatEnabled ? onOpenChat : null,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Text(
                                    'CHAT',
                                    style: TextStyle(
                                      color: Colors.white.withAlpha(220),
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.4,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Positioned(
                                    right: 6,
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: chatDotColor,
                                        boxShadow: [
                                          BoxShadow(
                                            color: chatDotColor.withAlpha(130),
                                            blurRadius: 6,
                                            spreadRadius: 1,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: const Color(0xFF2C333D),
                    border: Border.all(color: Colors.white24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(70),
                        blurRadius: 10,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: pingEnabled ? onPing : null,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 10,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Text(
                                    'PING',
                                    style: TextStyle(
                                      color: Colors.white.withAlpha(220),
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.4,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Positioned(
                                    right: 6,
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: pingDotColor,
                                        boxShadow: [
                                          BoxShadow(
                                            color: pingDotColor.withAlpha(130),
                                            blurRadius: 6,
                                            spreadRadius: 1,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelSelector({
    required bool isLocked,
    required List<_ChannelWheelEntry> entries,
    required int selectedIndex,
    required String selectedDescription,
    required ValueChanged<int> onSelectIndex,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_channelWheelController.hasClients) return;
      final current = _channelWheelController.selectedItem;
      if (current == selectedIndex) return;
      _channelWheelController.jumpToItem(selectedIndex);
      _lastChannelWheelIndex = selectedIndex;
    });

    Future<void> snapBackToCurrent() async {
      if (!_channelWheelController.hasClients) return;
      await _channelWheelController.animateToItem(
        selectedIndex,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withAlpha(26)),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_radioShell, _radioShellDark],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(72),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'CHANNEL SELECT',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withAlpha(210),
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: 106,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withAlpha(24)),
              gradient: const LinearGradient(
                colors: [Color(0xFF0D1117), Color(0xFF04060A)],
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.unfold_more_rounded,
                  color: Colors.white.withAlpha(130),
                ),
                Expanded(
                  child: AbsorbPointer(
                    absorbing: isLocked,
                    child: ListWheelScrollView.useDelegate(
                      controller: _channelWheelController,
                      itemExtent: 44,
                      diameterRatio: 1.5,
                      physics: const FixedExtentScrollPhysics(),
                      onSelectedItemChanged: (index) {
                        if (index < 0 || index >= entries.length) return;
                        if (index == _lastChannelWheelIndex) return;
                        _lastChannelWheelIndex = index;
                        if (isLocked) {
                          unawaited(snapBackToCurrent());
                          return;
                        }
                        _triggerChannelDetentFeedback();
                        onSelectIndex(index);
                      },
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: entries.length,
                        builder: (context, index) {
                          final item = entries[index];
                          final selected = index == selectedIndex;
                          return Center(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 120),
                              opacity: selected ? 1 : 0.55,
                              child: Text(
                                'CH-${item.number.toString().padLeft(2, '0')}  ${item.displayName}',
                                style: TextStyle(
                                  color: selected
                                      ? _radioAmber
                                      : Colors.white.withAlpha(170),
                                  fontFamily: 'monospace',
                                  fontSize: selected ? 18 : 16,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                Icon(
                  Icons.unfold_more_rounded,
                  color: Colors.white.withAlpha(130),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 85),
              opacity: _channelDetentFlash ? 1 : 0.14,
              child: Container(
                width: 52,
                height: 3,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: _radioAmber,
                  boxShadow: [
                    BoxShadow(
                      color: _radioAmber.withAlpha(140),
                      blurRadius: 7,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            selectedDescription,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildSignalBars({required int onlineCount}) {
    final level = onlineCount <= 0
        ? 0
        : onlineCount == 1
        ? 1
        : onlineCount <= 3
        ? 2
        : onlineCount <= 5
        ? 3
        : 4;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(5, (index) {
        final active = index <= level;
        return Container(
          width: 8,
          height: 8 + (index * 5),
          margin: const EdgeInsets.only(right: 5),
          decoration: BoxDecoration(
            color: active ? _radioAmber : _radioAmber.withAlpha(50),
            borderRadius: BorderRadius.circular(3),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: _radioAmber.withAlpha(120),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
        );
      }),
    );
  }

  Widget _buildDisplayPanel({
    required String callLabel,
    required int peerCount,
    required String? alwaysOnlineLabel,
    required bool isPublicMode,
    required bool isTargetOnline,
    required String linkStatusLabel,
    required String actionHintLabel,
    required ThemeData theme,
  }) {
    final peerLabelColor = peerCount > 0
        ? Colors.greenAccent.shade200
        : _radioAmber;
    final showOnlineBadge = !isPublicMode && isTargetOnline;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withAlpha(20)),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0E1116), Color(0xFF06080D)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(90),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: _radioAmber.withAlpha(24),
            blurRadius: 16,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  callLabel.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: _radioAmber,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    shadows: [
                      Shadow(color: _radioAmber.withAlpha(130), blurRadius: 12),
                    ],
                  ),
                ),
              ),
              if (showOnlineBadge) ...[
                const SizedBox(width: 8),
                Text(
                  'ONLINE',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: Colors.greenAccent.shade200,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          _buildSignalBars(onlineCount: peerCount),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(80),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _radioAmber.withAlpha(54)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  linkStatusLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: isTargetOnline || isPublicMode
                        ? Colors.greenAccent.shade200
                        : _radioAmber,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  actionHintLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withAlpha(205),
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 28,
            child: alwaysOnlineLabel == null
                ? const SizedBox.shrink()
                : _AutoScrollMarquee(
                    text: 'Always Online: $alwaysOnlineLabel',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: _radioAmber,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      fontSize: 15,
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                'PEERS - $peerCount',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: peerLabelColor,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPttButton({
    required bool isEnabled,
    required bool isHolding,
    required bool isSending,
    required bool speakerActive,
    required String idleLabel,
    required double size,
    required VoidCallback? onCancel,
  }) {
    final glowColor = isHolding
        ? Colors.redAccent
        : (isEnabled ? _radioAmber : Colors.grey.shade600);

    return GestureDetector(
      onLongPressStart: isEnabled
          ? (_) => unawaited(_startHoldRecording())
          : null,
      onLongPressEnd: isEnabled ? (_) => unawaited(_stopHoldAndSend()) : null,
      onLongPressCancel: isEnabled
          ? () => unawaited(_cancelHoldRecording())
          : null,
      onTap: isHolding ? onCancel : null,
      child: AnimatedBuilder(
        animation: _speakerPulse,
        builder: (context, child) {
          final pulse = speakerActive ? _speakerPulse.value : 0.0;
          final pulseScale = 1.0 + (0.032 * pulse);
          return Transform.scale(
            scale: pulseScale,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: size,
              height: size,
              padding: EdgeInsets.all(size * 0.075),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                  colors: [Color(0xFF474E58), Color(0xFF1B1F26)],
                ),
                border: Border.all(color: Colors.white.withAlpha(22), width: 2),
                boxShadow: [
                  BoxShadow(
                    color: glowColor.withAlpha(
                      speakerActive
                          ? 150 + (40 * pulse).toInt()
                          : isHolding
                          ? 170
                          : 120,
                    ),
                    blurRadius: speakerActive
                        ? 18 + (10 * pulse)
                        : isHolding
                        ? 30
                        : 18,
                    spreadRadius: speakerActive
                        ? 2 + (2 * pulse)
                        : isHolding
                        ? 5
                        : 1,
                  ),
                  BoxShadow(
                    color: Colors.black.withAlpha(100),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: child,
            ),
          );
        },
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: glowColor, width: 6),
            gradient: const RadialGradient(
              colors: [Color(0xFF313841), Color(0xFF171B22)],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isHolding
                      ? Icons.graphic_eq_rounded
                      : Icons.keyboard_voice_rounded,
                  size: size * 0.176,
                  color: isEnabled ? _radioAmber : Colors.white70,
                ),
                const SizedBox(height: 8),
                Text(
                  isHolding
                      ? 'TRANSMITTING'
                      : isSending
                      ? 'SENDING'
                      : idleLabel,
                  style: TextStyle(
                    color: isEnabled ? _radioAmber : Colors.white70,
                    fontFamily: 'monospace',
                    fontSize: size * 0.058,
                    letterSpacing: 1.0,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (isHolding) ...[
                  const SizedBox(height: 6),
                  Text(
                    _formatDuration(_elapsed),
                    style: TextStyle(
                      color: Colors.white.withAlpha(220),
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(
      chatControllerProvider.select((state) => state.walkieLastError),
      (previous, next) {
        if (!mounted || next == null || next.isEmpty || next == previous) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      },
    );

    ref.listen<List<AirGridMessage>>(
      chatControllerProvider.select((state) => state.messages),
      (previous, next) {
        unawaited(_handleIncomingWalkieUpdates(previous, next));
      },
    );

    final state = ref.watch(chatControllerProvider);
    final isHolding = state.walkieIsTransmitting;
    final isSending = state.walkieIsSending;
    final selected = state.selectedConversation;
    final targetNodeId = selected is PrivateConversation
        ? selected.peerNodeId
        : state.walkiePeerNodeId;
    final hasTarget = targetNodeId != null && targetNodeId.isNotEmpty;
    final isTargetOnline =
        hasTarget && state.peers.any((p) => p.nodeId == targetNodeId);
    final targetName = selected is PrivateConversation
        ? selected.peerName
        : 'No private target selected';
    final invitePeer = _peerByNodeId(state.walkieInvitePeerNodeId);
    final isIncomingInvite = state.walkieInviteIsIncoming;
    final isActiveSessionForTarget = _isPublicMode
        ? state.meshStarted
        : hasTarget && state.walkieSessionActivePeerNodeId == targetNodeId;
    final isOutgoingInviteForTarget =
        !_isPublicMode &&
        !isIncomingInvite &&
        hasTarget &&
        state.walkieInvitePeerNodeId == targetNodeId &&
        !isActiveSessionForTarget;
    final pingEnabled = !(isHolding || isSending) && !_isPublicMode;
    final pingDotColor = _isPublicMode
        ? Colors.grey.shade500
        : isActiveSessionForTarget
        ? Colors.greenAccent.shade200
        : isOutgoingInviteForTarget
        ? Colors.redAccent.shade100
        : (hasTarget && isTargetOnline)
        ? _radioAmber
        : Colors.grey.shade500;
    final theme = Theme.of(context);
    final selectedPrivateContact = selected is PrivateConversation
        ? state.knownContacts.cast<KnownContact?>().firstWhere(
            (item) => item?.nodeId == selected.peerNodeId,
            orElse: () => null,
          )
        : null;
    final privateStayOnlineEligible =
        selected is PrivateConversation &&
        selectedPrivateContact != null &&
        selectedPrivateContact.isTrusted;
    final stayOnlineOn = _isPublicMode
        ? state.publicWalkieStayOnline
        : (selectedPrivateContact?.walkieAlwaysOn ?? false);
    final stayOnlineEnabled =
        !(isHolding || isSending) &&
        (_isPublicMode || privateStayOnlineEligible);
    final stayOnlineHint = _isPublicMode
        ? 'Keep receiving public walkie voice across screens.'
        : selected is! PrivateConversation
        ? 'Select a private target to enable stay online.'
        : privateStayOnlineEligible
        ? 'Latches always-on walkie for this trusted friend.'
        : 'Trust this friend first to enable private stay online.';
    final privateAlwaysOnCount = state.knownContacts
        .where((contact) => contact.isTrusted && contact.walkieAlwaysOn)
        .length;
    final alwaysOnlineChannelParts = <String>[];
    if (state.publicWalkieStayOnline) {
      alwaysOnlineChannelParts.add('CH-07 PUBLIC');
    }
    if (privateAlwaysOnCount > 0) {
      final suffix = privateAlwaysOnCount > 1 ? ' ($privateAlwaysOnCount)' : '';
      alwaysOnlineChannelParts.add('CH-01 PRIVATE$suffix');
    }
    final alwaysOnlineLabel = alwaysOnlineChannelParts.isEmpty
        ? null
        : alwaysOnlineChannelParts.join('  •  ');
    final speakerActive =
        isHolding ||
        isSending ||
        (_status?.startsWith('Incoming walkie') ?? false);
    _syncSpeakerPulse(speakerActive);

    final callLabel = _isPublicMode
        ? 'CH-PUBLIC MESH'
        : (hasTarget ? 'CH-${targetName.toUpperCase()}' : 'CH-NO TARGET');
    final onlinePrivatePeers = state.peers
        .where((peer) => peer.nodeId != null)
        .toList(growable: false);
    final channelEntries = <_ChannelWheelEntry>[
      for (var i = 0; i < onlinePrivatePeers.length; i++)
        _ChannelWheelEntry(
          number: i + 1,
          displayName: onlinePrivatePeers[i].displayName,
          isPublic: false,
          peerNodeId: onlinePrivatePeers[i].nodeId,
          peerName: onlinePrivatePeers[i].displayName,
        ),
      if (onlinePrivatePeers.isEmpty)
        const _ChannelWheelEntry(
          number: 1,
          displayName: 'PRIVATE LINK',
          isPublic: false,
        ),
      const _ChannelWheelEntry(
        number: 7,
        displayName: 'PUBLIC MESH',
        isPublic: true,
      ),
    ];
    final selectedChannelIndex = _isPublicMode
        ? channelEntries.indexWhere((entry) => entry.isPublic)
        : (() {
            final nodeId = targetNodeId;
            if (nodeId == null || nodeId.isEmpty) return 0;
            final idx = channelEntries.indexWhere(
              (entry) => !entry.isPublic && entry.peerNodeId == nodeId,
            );
            return idx >= 0 ? idx : 0;
          })();
    final selectedEntry = channelEntries[selectedChannelIndex];
    final selectedChannelDescription = selectedEntry.isPublic
        ? 'Channel 07: Open broadcast'
        : selectedEntry.peerNodeId == null
        ? 'Channel 01: Paired private session'
        : 'Channel ${selectedEntry.number.toString().padLeft(2, '0')}: ${selectedEntry.displayName}';
    final linkStatusLabel = _isPublicMode
        ? (state.meshStarted
              ? 'PUBLIC BROADCAST READY'
              : 'PUBLIC CHANNEL OFFLINE')
        : !hasTarget
        ? 'NO PRIVATE TARGET'
        : isActiveSessionForTarget
        ? 'PRIVATE SESSION ACTIVE'
        : isOutgoingInviteForTarget
        ? 'INVITE SENT'
        : isTargetOnline
        ? 'TARGET ONLINE'
        : 'TARGET OFFLINE';
    final actionHintLabel = _isPublicMode
        ? (state.meshStarted
              ? 'Hold the mic to broadcast to nearby public peers.'
              : 'Start the mesh before using the public walkie channel.')
        : !hasTarget
        ? 'Choose an online private peer before starting a session.'
        : isActiveSessionForTarget
        ? 'Hold the mic to talk privately with $targetName.'
        : isOutgoingInviteForTarget
        ? 'Waiting for $targetName to accept your walkie invite.'
        : isTargetOnline
        ? 'Tap the link button to invite $targetName.'
        : '$targetName is not online yet.';
    final pttIdleLabel = isActiveSessionForTarget
        ? 'HOLD TO TALK'
        : _isPublicMode
        ? 'START MESH'
        : hasTarget
        ? 'INVITE FIRST'
        : 'CHOOSE TARGET';

    return Scaffold(
      backgroundColor: const Color(0xFF07090D),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Walkie Talkie'),
        actions: [
          const PublicWalkieStatusIcon(),
          IconButton(
            tooltip: 'Choose target',
            onPressed: isHolding || isSending ? null : _chooseTarget,
            icon: const Icon(Icons.people_alt_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.75),
              radius: 1.25,
              colors: [Color(0xFF10151D), Color(0xFF06080D)],
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final uiScale = 1.0;

              final shellPadding = 14.0 * uiScale;
              final controlSectionHeight = 190.0 * uiScale;
              final pttSize = 238.0 * uiScale;
              final sectionGap = 14.0 * uiScale;
              final statusGap = 16.0 * uiScale;

              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: 460,
                      child: Container(
                        padding: EdgeInsets.all(shellPadding),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: Colors.white.withAlpha(20)),
                          gradient: const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [_radioShell, _radioShellDark],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(110),
                              blurRadius: 26,
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildChannelSelector(
                              isLocked: isHolding || isSending,
                              entries: channelEntries,
                              selectedIndex: selectedChannelIndex,
                              selectedDescription: selectedChannelDescription,
                              onSelectIndex: (index) {
                                final selected = channelEntries[index];
                                if (selected.isPublic) {
                                  if (_isPublicMode) return;
                                  setState(() {
                                    _isPublicMode = true;
                                    _status = null;
                                  });
                                  return;
                                }

                                setState(() {
                                  _isPublicMode = false;
                                  _status = null;
                                });

                                final nodeId = selected.peerNodeId;
                                final peerName = selected.peerName;
                                if (nodeId == null || peerName == null) return;
                                final target = PrivateConversation(
                                  peerNodeId: nodeId,
                                  peerName: peerName,
                                );
                                ref
                                    .read(chatControllerProvider.notifier)
                                    .selectConversation(target);
                                unawaited(
                                  _autoStartPrivateWalkieIfEnabled(target),
                                );
                              },
                            ),
                            SizedBox(height: sectionGap),
                            _buildDisplayPanel(
                              callLabel: callLabel,
                              peerCount: state.peers.length,
                              alwaysOnlineLabel: alwaysOnlineLabel,
                              isPublicMode: _isPublicMode,
                              isTargetOnline: isTargetOnline,
                              linkStatusLabel: linkStatusLabel,
                              actionHintLabel: actionHintLabel,
                              theme: theme,
                            ),
                            SizedBox(height: 10 * uiScale),
                            SizedBox(
                              height: controlSectionHeight,
                              child: SingleChildScrollView(
                                child: Column(
                                  children: [
                                    _buildLatchingPushButton(
                                      isOn: stayOnlineOn,
                                      enabled: stayOnlineEnabled,
                                      hintText: stayOnlineHint,
                                      openChatEnabled:
                                          !(isHolding || isSending),
                                      chatLaunchFlash: _chatLaunchFlash,
                                      pingDotColor: pingDotColor,
                                      pingEnabled: pingEnabled,
                                      onPressed: () {
                                        _triggerButtonFeedback();
                                        if (_isPublicMode) {
                                          ref
                                              .read(
                                                chatControllerProvider.notifier,
                                              )
                                              .setPublicWalkieStayOnline(
                                                !stayOnlineOn,
                                              );
                                          return;
                                        }
                                        if (selected is PrivateConversation &&
                                            privateStayOnlineEligible) {
                                          ref
                                              .read(
                                                chatControllerProvider.notifier,
                                              )
                                              .setWalkieAlwaysOn(
                                                selected.peerNodeId,
                                                !stayOnlineOn,
                                              );
                                        }
                                      },
                                      onOpenChat: () async {
                                        if (isHolding ||
                                            isSending ||
                                            _chatLaunchFlash) {
                                          return;
                                        }
                                        _triggerButtonFeedback();
                                        final navigator = Navigator.of(context);
                                        if (!mounted) return;
                                        setState(() {
                                          _chatLaunchFlash = true;
                                        });
                                        await Future<void>.delayed(
                                          const Duration(milliseconds: 120),
                                        );
                                        if (!mounted) return;
                                        await navigator.pushNamed(
                                          AppRouter.chat,
                                        );
                                        if (!mounted) return;
                                        setState(() {
                                          _chatLaunchFlash = false;
                                        });
                                      },
                                      onPing: () async {
                                        if (!pingEnabled) return;
                                        _triggerButtonFeedback();
                                        if (isActiveSessionForTarget) {
                                          await ref
                                              .read(
                                                chatControllerProvider.notifier,
                                              )
                                              .endWalkieSession();
                                          return;
                                        }
                                        if (isOutgoingInviteForTarget) {
                                          await ref
                                              .read(
                                                chatControllerProvider.notifier,
                                              )
                                              .cancelWalkieInvite();
                                          return;
                                        }
                                        if (!hasTarget || !isTargetOnline) {
                                          return;
                                        }
                                        final peer = _peerByNodeId(
                                          targetNodeId,
                                        );
                                        if (peer == null) return;
                                        await _invitePeer(peer);
                                      },
                                    ),
                                    if (!_isPublicMode) ...[
                                      if (isIncomingInvite &&
                                          invitePeer != null) ...[
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: FilledButton(
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor:
                                                        _radioAmber,
                                                    foregroundColor:
                                                        Colors.black,
                                                  ),
                                                  onPressed: () async {
                                                    await ref
                                                        .read(
                                                          chatControllerProvider
                                                              .notifier,
                                                        )
                                                        .acceptWalkieInvite();
                                                  },
                                                  child: const Text(
                                                    'Accept invite',
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: OutlinedButton(
                                                  onPressed: () async {
                                                    await ref
                                                        .read(
                                                          chatControllerProvider
                                                              .notifier,
                                                        )
                                                        .declineWalkieInvite();
                                                  },
                                                  child: const Text('Decline'),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(height: sectionGap),
                            Center(
                              child: _buildPttButton(
                                isEnabled: isActiveSessionForTarget,
                                isHolding: isHolding,
                                isSending: isSending,
                                speakerActive: speakerActive,
                                idleLabel: pttIdleLabel,
                                size: pttSize,
                                onCancel: isActiveSessionForTarget
                                    ? () => unawaited(_cancelHoldRecording())
                                    : null,
                              ),
                            ),
                            SizedBox(height: statusGap),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WalkieSendException implements Exception {
  final String message;

  const _WalkieSendException(this.message);
}

class _ChannelWheelEntry {
  final int number;
  final String displayName;
  final bool isPublic;
  final String? peerNodeId;
  final String? peerName;

  const _ChannelWheelEntry({
    required this.number,
    required this.displayName,
    required this.isPublic,
    this.peerNodeId,
    this.peerName,
  });
}

class _AutoScrollMarquee extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const _AutoScrollMarquee({required this.text, this.style});

  @override
  State<_AutoScrollMarquee> createState() => _AutoScrollMarqueeState();
}

class _AutoScrollMarqueeState extends State<_AutoScrollMarquee> {
  final ScrollController _controller = ScrollController();
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startIfNeeded();
    });
  }

  @override
  void didUpdateWidget(covariant _AutoScrollMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _startIfNeeded();
      });
    }
  }

  Future<void> _startIfNeeded() async {
    if (!mounted || !_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    if (max <= 0 || _running) return;
    _running = true;
    while (mounted && _running) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted || !_controller.hasClients) break;
      await _controller.animateTo(
        max,
        duration: Duration(milliseconds: (max * 22).clamp(1800, 7000).toInt()),
        curve: Curves.linear,
      );
      if (!mounted || !_controller.hasClients) break;
      await Future<void>.delayed(const Duration(milliseconds: 550));
      _controller.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _running = false;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(widget.text, style: widget.style, maxLines: 1),
        ),
      ),
    );
  }
}
