import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/constants.dart';
import 'package:airgrid/data/storage/rider_mode_settings_store.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/models/privacy_mode.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:airgrid/features/rider/rider_mode_controller.dart';
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
  int _lastChannelWheelIndex = 0;

  /// When true the user is in open public-channel broadcast mode.
  /// When false (default) the private invite/session flow is active.
  bool _isPublicMode = false;
  bool _isRiderMode = false;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = ref.read(chatControllerProvider);
      if (!s.meshStarted && !s.isMeshStarting) {
        ref.read(chatControllerProvider.notifier).startMesh();
      }
      // Announce initial walkie availability for this screen (best-effort).
      unawaited(
        ref
            .read(chatControllerProvider.notifier)
            .publishWalkieAvailability(!_isPublicMode),
      );
    });
  }

  @override
  void dispose() {
    // Publish offline only when private stay-online is not latched.
    try {
      final state = ref.read(chatControllerProvider);
      final selected = state.selectedConversation;
      final targetNodeId = selected is PrivateConversation
          ? selected.peerNodeId
          : state.walkiePeerNodeId;
      final keepAvailable =
          !_isPublicMode &&
          targetNodeId != null &&
          state.knownContacts.any(
            (contact) =>
                contact.nodeId == targetNodeId &&
                contact.isTrusted &&
                contact.walkieAlwaysOn,
          );
      unawaited(
        ref
            .read(chatControllerProvider.notifier)
            .publishWalkieAvailability(keepAvailable),
      );
      if (_isRiderMode) {
        unawaited(
          ref.read(riderModeControllerProvider.notifier).armPresence(false),
        );
      }
    } catch (_) {
      // Provider scopes may already be tearing down in widget tests/navigation.
    }
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
    if ((_isPublicMode && state.publicWalkieStayOnline) ||
        (!_isPublicMode &&
            selected is PrivateConversation &&
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
    if (await _requiresTrustedContactBeforeInvite(peer)) {
      return;
    }

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

  Future<bool> _requiresTrustedContactBeforeInvite(MeshPeer peer) async {
    final nodeId = peer.nodeId;
    if (nodeId == null) return false;

    final state = ref.read(chatControllerProvider);
    if (state.privacyMode != PrivacyMode.trustedContactsOnly ||
        state.trustedNodeIds.contains(nodeId)) {
      return false;
    }

    if (!mounted) return true;

    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(chatControllerProvider.notifier);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Add ${peer.displayName} to Invited Friends before starting private walkie.',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Add',
          onPressed: () async {
            await controller.trustContact(nodeId);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Added to invited friends'),
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 2),
              ),
            );
          },
        ),
      ),
    );

    setState(() {
      _status = 'Add ${peer.displayName} to Invited Friends first';
    });
    return true;
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

    final selectedNodeId = await _showChooseTargetSheet(candidates);
    if (selectedNodeId == null) return;

    if (selectedNodeId.startsWith('invite:')) {
      final peerNodeId = selectedNodeId.substring('invite:'.length);
      final selectedPeer = candidates.cast<MeshPeer?>().firstWhere(
        (peer) => peer?.nodeId == peerNodeId,
        orElse: () => null,
      );
      if (selectedPeer == null) return;
      if (_isRiderMode) {
        ref.read(chatControllerProvider.notifier).setWalkiePeerNodeId(peerNodeId);
        return;
      }
      await _invitePeer(selectedPeer);
      return;
    }

    final selectedPeer = candidates.cast<MeshPeer?>().firstWhere(
      (peer) => peer?.nodeId == selectedNodeId,
      orElse: () => null,
    );
    if (selectedPeer == null) return;

    final controller = ref.read(chatControllerProvider.notifier);
    if (_isRiderMode) {
      controller.setWalkiePeerNodeId(selectedNodeId);
    } else {
      controller.selectConversation(
        PrivateConversation(
          peerNodeId: selectedNodeId,
          peerName: selectedPeer.displayName,
        ),
      );
    }

    if (!_isRiderMode) {
      await _autoStartPrivateWalkieIfEnabled(
        PrivateConversation(
          peerNodeId: selectedNodeId,
          peerName: selectedPeer.displayName,
        ),
      );
    }
  }

  Future<String?> _showChooseTargetSheet(List<MeshPeer> candidates) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF0E1620),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _isRiderMode ? 'Choose rider' : 'Choose walkie target',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: Colors.white70,
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _isRiderMode
                    ? 'Pick an online AirGrid peer for Rider Mode.'
                    : 'Pick an online AirGrid peer to invite for a private walkie session.',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 380),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  separatorBuilder: (_, __) => const Divider(
                    color: Colors.white10,
                    height: 0,
                    indent: 72,
                  ),
                  itemBuilder: (ctx, index) {
                    final peer = candidates[index];
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => Navigator.of(ctx).pop(peer.nodeId),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 8,
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 22,
                                backgroundColor: Colors.white12,
                                child: const Icon(
                                  Icons.person,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      peer.displayName,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      peer.nodeId ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: Colors.white60),
                                    ),
                                  ],
                                ),
                              ),
                              if (!_isRiderMode) ...[
                                const SizedBox(width: 12),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFF4D35E),
                                    foregroundColor: Colors.black,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    elevation: 0,
                                    minimumSize: const Size(72, 36),
                                  ),
                                  onPressed: () => Navigator.of(
                                    ctx,
                                  ).pop('invite:${peer.nodeId}'),
                                  child: const Text('Invite'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAcceptInviteDialog(MeshPeer invitePeer) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1724),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Accept walkie invite'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Incoming private walkie invite from ${invitePeer.displayName}.',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.person_pin, color: Color(0xFFF4D35E)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    invitePeer.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFF4D35E),
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Accept invite'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await ref.read(chatControllerProvider.notifier).acceptWalkieInvite();
    }
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
        settleDelay: Duration.zero,
      );
      if (!online) {
        throw const _WalkieSendException('Peer is not online');
      }

      final refreshedState = ref.read(chatControllerProvider);
      final peer = refreshedState.peers.cast<MeshPeer?>().firstWhere(
        (item) => item?.nodeId == conv.peerNodeId,
        orElse: () => null,
      );
      if (peer == null) {
        throw const _WalkieSendException('Peer is not online');
      }

      // Ensure the remote peer has advertised they can receive private walkie.
      final selectedContact = refreshedState.knownContacts
          .cast<KnownContact?>()
          .firstWhere((c) => c?.nodeId == conv.peerNodeId, orElse: () => null);
      if (selectedContact != null && !(selectedContact.remoteWalkieAvailable)) {
        // Offer to navigate to chat instead of sending audio.
        if (!mounted) return;
        final choice = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF0F1724),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Text(
              'Receiver unavailable',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The receiver\'s walkie appears to be offline.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.person_pin, color: Color(0xFFF4D35E)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        peer.displayName ?? '',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Send a text instead to ask them to come/stay online?',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('OK'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFF4D35E),
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Chat'),
              ),
            ],
          ),
        );

        // Reset sending state and optionally navigate to chat.
        ref
            .read(chatControllerProvider.notifier)
            .setWalkieSending(isSending: false);
        ref
            .read(chatControllerProvider.notifier)
            .setWalkieLastError('Receiver walkie offline');

        // Delete the recorded file since we're not sending it now.
        try {
          final f = File(recordedPath);
          if (await f.exists()) await f.delete();
        } catch (_) {
          // ignore
        }

        if (choice == true) {
          // Select the private conversation and open chat.
          controller.selectConversation(
            PrivateConversation(
              peerNodeId: conv.peerNodeId,
              peerName: peer.displayName,
            ),
          );
          await Navigator.of(context).pushNamed(AppRouter.chat);
        }

        return;
      }

      final result = await controller.sendPrivateAudio(
        peer,
        payload,
        allowPlaintextFallback: true,
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

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  static const Color _radioAmber = Color(0xFFFFA126);
  static const Color _radioShell = Color(0xFF343A41);
  static const Color _radioShellDark = Color(0xFF1B1E24);
  static const Color _meshOffFill = Color(0xFF2A3038);
  static const Color _meshOffBorder = Color(0xFF545B66);
  static const Color _meshOffForeground = Color(0xFFB6BDC7);

  Widget _buildMeshControlDeck({
    required bool meshStarted,
    required bool isMeshStarting,
    required bool isAdvertising,
    required bool isDiscovering,
    required bool playServicesAvailable,
    required int peerCount,
    required bool isDisabled,
  }) {
    final controller = ref.read(chatControllerProvider.notifier);
    final meshBusy = isMeshStarting || isDisabled;
    final controlsEnabled = meshStarted && playServicesAvailable && !meshBusy;

    void showSnack(String msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    // Shared style helpers
    Widget buildLedDot(bool lit) {
      final color = lit ? Colors.greenAccent.shade200 : Colors.grey.shade700;
      return Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: lit
              ? [
                  BoxShadow(
                    color: Colors.greenAccent.withAlpha(160),
                    blurRadius: 6,
                  ),
                ]
              : null,
        ),
      );
    }

    Widget buildDeckButton({
      required String label,
      required bool isLatched,
      required bool enabled,
      required VoidCallback? onTap,
    }) {
      final isOn = isLatched && enabled;
      final fg = isOn
          ? Colors.greenAccent.shade200
          : enabled
          ? _meshOffForeground
          : Colors.white24;
      return GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: isOn ? const Color(0xFF0D2010) : _meshOffFill,
            border: Border.all(
              color: isOn
                  ? Colors.greenAccent.withAlpha(80)
                  : _meshOffBorder.withAlpha(enabled ? 150 : 60),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(80),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildLedDot(isOn),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 10,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // PWR knob-style button
    final pwrActive = meshStarted || isMeshStarting;
    final pwrColor = pwrActive ? _radioAmber : _meshOffForeground;
    Widget buildPwrButton() {
      return GestureDetector(
        onTap: isMeshStarting
            ? null
            : () {
                _triggerButtonFeedback();
                if (meshStarted) {
                  controller.stopMesh();
                } else {
                  controller.startMesh();
                }
              },
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: pwrActive ? const Color(0xFF171B21) : _meshOffFill,
            border: Border.all(
              color: pwrActive
                  ? _radioAmber.withAlpha(160)
                  : _meshOffBorder.withAlpha(150),
              width: 1.5,
            ),
            boxShadow: [
              if (pwrActive)
                BoxShadow(
                  color: _radioAmber.withAlpha(90),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              BoxShadow(
                color: Colors.black.withAlpha(100),
                blurRadius: 6,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.power_settings_new,
                size: 20,
                color: isMeshStarting ? _radioAmber.withAlpha(140) : pwrColor,
              ),
              const SizedBox(height: 2),
              Text(
                'PWR',
                style: TextStyle(
                  color: isMeshStarting ? _radioAmber.withAlpha(180) : pwrColor,
                  fontSize: 9,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // PEERS LCD badge
    final peersColor = peerCount > 0
        ? Colors.greenAccent.shade200
        : _radioAmber;
    Widget buildPeersBadge() {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: const Color(0xFF0A0D10),
          border: Border.all(color: _radioAmber.withAlpha(50)),
          boxShadow: [
            BoxShadow(
              color: _radioAmber.withAlpha(20),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              peerCount.toString().padLeft(2, '0'),
              style: TextStyle(
                color: peersColor,
                fontSize: 16,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                shadows: [
                  Shadow(color: peersColor.withAlpha(160), blurRadius: 8),
                ],
              ),
            ),
            Text(
              'PEERS',
              style: TextStyle(
                color: peersColor.withAlpha(180),
                fontSize: 9,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF0E1116),
        border: Border.all(color: Colors.white.withAlpha(18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(80),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          buildPwrButton(),
          const SizedBox(width: 8),
          buildDeckButton(
            label: 'SCAN',
            isLatched: isDiscovering,
            enabled: controlsEnabled,
            onTap: () {
              _triggerButtonFeedback();
              final next = !isDiscovering;
              controller.setDiscoveryEnabled(next);
              if (next) showSnack('Scanning for nearby AirGrid users');
            },
          ),
          const SizedBox(width: 6),
          buildDeckButton(
            label: 'AVAIL',
            isLatched: isAdvertising,
            enabled: controlsEnabled,
            onTap: () {
              _triggerButtonFeedback();
              final next = !isAdvertising;
              controller.setAdvertisingEnabled(next);
              if (next) {
                showSnack('Other AirGrid users nearby can find you');
              }
            },
          ),
          const SizedBox(width: 6),
          buildDeckButton(
            label: 'SYNC',
            isLatched: false,
            enabled: meshStarted && !isMeshStarting && !isDisabled,
            onTap: () {
              _triggerButtonFeedback();
              controller.startMesh(forceRestart: true);
            },
          ),
          const SizedBox(width: 8),
          buildPeersBadge(),
        ],
      ),
    );
  }

  Widget _buildHardwareHeader({
    required bool isPublicMode,
    required int peerCount,
    required bool isActive,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withAlpha(22)),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF3C434B), Color(0xFF20242B)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(80),
            blurRadius: 14,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        children: [
          _buildScrew(),
          const SizedBox(width: 12),
          Expanded(child: _buildSpeakerGrille()),
          const SizedBox(width: 12),
          _buildControlKnob(
            label: 'VOL',
            active: isActive,
            valueLabel: isPublicMode ? 'PUB' : 'PRI',
          ),
          const SizedBox(width: 10),
          _buildControlKnob(
            label: 'SQL',
            active: peerCount > 0,
            valueLabel: peerCount.toString().padLeft(2, '0'),
          ),
          const SizedBox(width: 12),
          _buildScrew(),
        ],
      ),
    );
  }

  Widget _buildSpeakerGrille() {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF171B21),
        border: Border.all(color: Colors.black.withAlpha(120)),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withAlpha(12),
            blurRadius: 1,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          for (var i = 0; i < 12; i++) ...[
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withAlpha(190),
                      const Color(0xFF2C333B),
                      Colors.black.withAlpha(220),
                    ],
                  ),
                ),
              ),
            ),
            if (i != 11) const SizedBox(width: 5),
          ],
        ],
      ),
    );
  }

  Widget _buildControlKnob({
    required String label,
    required bool active,
    required String valueLabel,
  }) {
    final glow = active ? _radioAmber : Colors.white38;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const RadialGradient(
              colors: [Color(0xFF505963), Color(0xFF1B2027)],
            ),
            border: Border.all(color: Colors.white.withAlpha(36), width: 2),
            boxShadow: [
              BoxShadow(
                color: glow.withAlpha(active ? 85 : 22),
                blurRadius: active ? 10 : 4,
                spreadRadius: active ? 1 : 0,
              ),
              BoxShadow(
                color: Colors.black.withAlpha(95),
                blurRadius: 7,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 6,
                height: 23,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  color: glow,
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Text(
                    valueLabel,
                    style: TextStyle(
                      color: Colors.white.withAlpha(180),
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withAlpha(150),
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }

  Widget _buildScrew() {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          colors: [Color(0xFF66707A), Color(0xFF1B2026)],
        ),
        border: Border.all(color: Colors.black.withAlpha(140)),
      ),
      child: Center(
        child: Container(
          width: 12,
          height: 2,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            color: Colors.black.withAlpha(155),
          ),
        ),
      ),
    );
  }

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

  Widget _buildStatusCard({
    required bool meshStarted,
    required bool isMeshStarting,
    required bool isAdvertising,
    required bool isDiscovering,
    required bool playServicesAvailable,
    required int peerCount,
    required VoidCallback? onToggleMesh,
    required VoidCallback? onToggleAdvertising,
    required VoidCallback? onToggleDiscovering,
    required VoidCallback? onRefreshPeers,
  }) {
    const cardSurface = Color(0xFF18212B);
    const cardSurfaceStrong = Color(0xFF222C38);
    final online = meshStarted && playServicesAvailable;
    const onlineIconBackground = Color(0xFFDCFCE7);
    const onlineIconColor = Color(0xFF16A34A);
    final meshIconBackground = online ? onlineIconBackground : _meshOffFill;
    final meshIconColor = online ? onlineIconColor : _meshOffForeground;
    final meshButtonBackground = online || isMeshStarting
        ? cardSurfaceStrong
        : _meshOffFill;
    final meshButtonBorder = online || isMeshStarting
        ? Colors.white12
        : _meshOffBorder.withAlpha(150);
    final title = online ? 'Mesh Online' : 'Mesh Offline';
    final subtitle = !playServicesAvailable
        ? 'AirGrid needs Google Play Services to go online.'
        : isMeshStarting
        ? 'Please wait while the mesh starts.'
        : !meshStarted
        ? 'Start mesh to connect to nearby peers.'
        : 'Nearby peers are ready to receive walkie audio.';

    Widget metricChip({
      required IconData icon,
      required String label,
      required bool active,
      required Color color,
      VoidCallback? onTap,
    }) {
      final labelColor = active ? color : Colors.white54;
      final iconColor = active ? color : Colors.white38;
      final backgroundColor = active ? color.withAlpha(40) : cardSurface;
      final borderColor = active ? color.withAlpha(100) : Colors.white12;

      return Material(
        color: cardSurface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showLabel = constraints.maxWidth >= 92;
              return Container(
                padding: EdgeInsets.symmetric(
                  horizontal: showLabel ? 12 : 8,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: backgroundColor,
                  border: Border.all(color: borderColor),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: color.withAlpha(18),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 16, color: iconColor),
                    if (showLabel) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: labelColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withAlpha(20)),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF131A23), Color(0xFF0B1017)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(80),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: meshIconBackground,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  online ? Icons.hub_rounded : Icons.hub_outlined,
                  color: meshIconColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                decoration: BoxDecoration(
                  color: meshButtonBackground,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: meshButtonBorder),
                ),
                child: IconButton(
                  onPressed: isMeshStarting ? null : onToggleMesh,
                  tooltip: meshStarted ? 'Stop mesh' : 'Start mesh',
                  color: online ? Colors.white : _meshOffForeground,
                  icon: isMeshStarting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          meshStarted ? Icons.power_settings_new : Icons.wifi,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final chipWidth = (constraints.maxWidth - 16) / 3;
              return Row(
                children: [
                  SizedBox(
                    width: chipWidth,
                    child: metricChip(
                      icon: Icons.people_outline,
                      label: '$peerCount peer${peerCount == 1 ? '' : 's'}',
                      active: online && peerCount > 0,
                      color: Colors.tealAccent.shade200,
                      onTap: onRefreshPeers,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: chipWidth,
                    child: metricChip(
                      icon: Icons.campaign_outlined,
                      label: online ? 'Available' : 'Offline',
                      active: online && isAdvertising,
                      color: Colors.greenAccent.shade200,
                      onTap: online ? onToggleAdvertising : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: chipWidth,
                    child: metricChip(
                      icon: Icons.search,
                      label: online ? 'Scanning' : 'Idle',
                      active: online && isDiscovering,
                      color: const Color(0xFFFFB347),
                      onTap: online ? onToggleDiscovering : null,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          if (!playServicesAvailable ||
              (!meshStarted && onToggleMesh != null)) ...[
            const SizedBox(height: 14),
            FilledButton.tonal(
              onPressed: playServicesAvailable ? onToggleMesh : null,
              style: FilledButton.styleFrom(
                backgroundColor: meshStarted
                    ? const Color(0xFF1D2630)
                    : _meshOffFill,
                foregroundColor: meshStarted
                    ? Colors.white
                    : _meshOffForeground,
                disabledBackgroundColor: _meshOffFill,
                disabledForegroundColor: _meshOffForeground.withAlpha(150),
              ),
              child: Text(meshStarted ? 'Mesh running' : 'Start mesh'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeSelector({
    required bool isPublicMode,
    required bool isRiderMode,
    required VoidCallback onPrivate,
    required VoidCallback onPublic,
    required VoidCallback onRider,
  }) {
    Widget buildButton({
      required String label,
      required bool selected,
      required IconData icon,
      required VoidCallback onTap,
    }) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0xFFFFA126), Color(0xFFFFB84D)],
                )
              : null,
          color: selected ? null : Colors.black.withAlpha(70),
          border: Border.all(
            color: selected ? Colors.transparent : Colors.white24,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: _radioAmber.withAlpha(120),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: selected ? Colors.black : Colors.white70,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        color: selected ? Colors.black : Colors.white70,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        Expanded(
          child: buildButton(
            label: 'Private',
            selected: !isPublicMode && !isRiderMode,
            icon: Icons.lock_outline,
            onTap: onPrivate,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: buildButton(
            label: 'Public',
            selected: isPublicMode && !isRiderMode,
            icon: Icons.campaign_outlined,
            onTap: onPublic,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: buildButton(
            label: 'Rider',
            selected: isRiderMode,
            icon: Icons.two_wheeler_rounded,
            onTap: onRider,
          ),
        ),
      ],
    );
  }

  Widget _buildRiderPanel({
    required RiderModeState rider,
    required MeshPeer? targetPeer,
    required KnownContact? contact,
    required bool meshStarted,
    required bool isTargetOnline,
    required VoidCallback? onTrustTarget,
  }) {
    final riderController = ref.read(riderModeControllerProvider.notifier);
    final hasUsableTarget = targetPeer != null && isTargetOnline;
    final isTrustedTarget =
        contact != null && contact.isTrusted && !contact.isBlocked;
    final canStart =
        meshStarted &&
        hasUsableTarget &&
        isTrustedTarget;
    final status = rider.isActive
        ? 'Live with ${rider.peerName ?? 'rider'}'
        : rider.isStarting
        ? 'Starting Rider Mode...'
        : rider.incomingPeerName != null
        ? '${rider.incomingPeerName} wants to start Rider Mode'
        : canStart
        ? 'Ready for trusted 1:1 rider audio'
        : hasUsableTarget && !isTrustedTarget
        ? 'Trust ${targetPeer.displayName} to enable Rider Mode'
        : 'Choose an online private peer';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(86),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                rider.isActive
                    ? Icons.radio_button_checked
                    : Icons.two_wheeler_rounded,
                color: rider.isActive ? Colors.greenAccent : _radioAmber,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: rider.inputLevel.clamp(0.0, 1.0),
            minHeight: 5,
            color: rider.isMuted ? Colors.white38 : Colors.greenAccent,
            backgroundColor: Colors.white12,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<RiderMicMode>(
                  segments: const [
                    ButtonSegment(
                      value: RiderMicMode.alwaysOpen,
                      label: Text('Open'),
                      icon: Icon(Icons.mic_rounded),
                    ),
                    ButtonSegment(
                      value: RiderMicMode.voiceActivated,
                      label: Text('Voice'),
                      icon: Icon(Icons.graphic_eq_rounded),
                    ),
                  ],
                  selected: {rider.settings.micMode},
                  onSelectionChanged: (value) =>
                      unawaited(riderController.setMicMode(value.first)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<RiderStartPolicy>(
                  segments: const [
                    ButtonSegment(
                      value: RiderStartPolicy.trustedAutoJoin,
                      label: Text('Auto'),
                      icon: Icon(Icons.bolt_rounded),
                    ),
                    ButtonSegment(
                      value: RiderStartPolicy.mutualStart,
                      label: Text('Ask'),
                      icon: Icon(Icons.handshake_outlined),
                    ),
                  ],
                  selected: {rider.settings.startPolicy},
                  onSelectionChanged: (value) =>
                      unawaited(riderController.setStartPolicy(value.first)),
                ),
              ),
            ],
          ),
          if (rider.lastError != null) ...[
            const SizedBox(height: 10),
            Text(
              rider.lastError!,
              style: TextStyle(color: Colors.redAccent.shade100),
            ),
          ],
          const SizedBox(height: 12),
          if (!rider.isActive &&
              hasUsableTarget &&
              !isTrustedTarget &&
              onTrustTarget != null) ...[
            FilledButton.icon(
              onPressed: onTrustTarget,
              icon: const Icon(Icons.verified_rounded),
              label: Text('Trust ${targetPeer.displayName}'),
            ),
            const SizedBox(height: 10),
          ],
          if (rider.incomingPeerName != null && !rider.isActive)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        unawaited(riderController.declineIncoming()),
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () =>
                        unawaited(riderController.acceptIncoming()),
                    icon: const Icon(Icons.call_rounded),
                    label: const Text('Accept'),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: rider.isActive
                        ? () => unawaited(riderController.endSession())
                        : canStart && !rider.isStarting
                        ? () => unawaited(
                            riderController.startSession(targetPeer),
                          )
                        : null,
                    icon: Icon(
                      rider.isActive
                          ? Icons.call_end_rounded
                          : Icons.call_rounded,
                    ),
                    label: Text(
                      rider.isActive ? 'End Rider Mode' : 'Start Rider Mode',
                    ),
                  ),
                ),
                if (rider.isActive) ...[
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    onPressed: () =>
                        unawaited(riderController.setMuted(!rider.isMuted)),
                    icon: Icon(
                      rider.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                    ),
                    tooltip: rider.isMuted ? 'Unmute' : 'Mute',
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildTargetCard({
    required bool isPublicMode,
    required bool hasTarget,
    required String targetName,
    required bool isTargetOnline,
    required bool canReceivePrivate,
    required bool isHolding,
    required bool isSending,
    required VoidCallback onChooseTarget,
  }) {
    final caption = isPublicMode
        ? 'Broadcast to nearby AirGrid users.'
        : hasTarget
        ? targetName
        : 'No private target selected';
    final description = isPublicMode
        ? 'Hold to broadcast when mesh is running.'
        : hasTarget
        ? isTargetOnline
              ? (canReceivePrivate
                    ? '$targetName is online and ready to talk.'
                    : '$targetName is online but away from the private walkie screen.')
              : '$targetName is not online yet.'
        : 'Choose someone nearby to start a private walkie.';
    final badgeColor = isPublicMode
        ? _radioAmber
        : isTargetOnline
        ? (canReceivePrivate ? const Color(0xFF57D163) : _radioAmber)
        : Colors.white60;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF10151D),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withAlpha(18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(60),
            blurRadius: 10,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  isPublicMode ? 'Public channel' : 'Private target',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: badgeColor.withAlpha(24),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: badgeColor.withAlpha(80)),
                ),
                child: Text(
                  isPublicMode
                      ? 'Open'
                      : isTargetOnline
                      ? 'Online'
                      : 'Offline',
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            caption,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: TextStyle(
              color: Colors.white.withAlpha(190),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          if (!isPublicMode) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: isHolding || isSending ? null : onChooseTarget,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1D2630),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF232B36),
                disabledForegroundColor: Colors.white38,
              ),
              child: const Text('Choose person'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSessionActionCard({
    required bool isPublicMode,
    required bool meshStarted,
    required bool isMeshStarting,
    required bool playServicesAvailable,
    required bool hasTarget,
    required bool isTargetOnline,
    required bool isActiveSessionForTarget,
    required bool isIncomingInvite,
    required bool isOutgoingInviteForTarget,
    required VoidCallback? onAcceptInvite,
    required VoidCallback? onCancelInvite,
    required VoidCallback? onEndSession,
    required VoidCallback? onInvite,
    required VoidCallback? onStartMesh,
  }) {
    String label;
    VoidCallback? onPressed;
    var enabled = false;
    var useActiveStyle = false;
    if (isPublicMode) {
      if (!playServicesAvailable) {
        label = 'Play Services unavailable';
      } else if (isMeshStarting) {
        label = 'Starting...';
        useActiveStyle = true;
      } else if (!meshStarted) {
        label = 'Start mesh';
        enabled = onStartMesh != null;
        onPressed = onStartMesh;
      } else {
        label = 'Public broadcast ready';
        useActiveStyle = true;
      }
    } else if (isIncomingInvite) {
      label = 'Accept invite';
      enabled = onAcceptInvite != null;
      onPressed = onAcceptInvite;
      useActiveStyle = enabled;
    } else if (isOutgoingInviteForTarget) {
      label = 'Cancel invite';
      enabled = onCancelInvite != null;
      onPressed = onCancelInvite;
      useActiveStyle = enabled;
    } else if (isActiveSessionForTarget) {
      label = 'End session';
      enabled = onEndSession != null;
      onPressed = onEndSession;
      useActiveStyle = enabled;
    } else if (hasTarget) {
      label = 'Invite';
      enabled = isTargetOnline && onInvite != null;
      onPressed = enabled ? onInvite : null;
      useActiveStyle = enabled;
    } else {
      label = 'Choose someone';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          onPressed: enabled ? onPressed : null,
          style: FilledButton.styleFrom(
            backgroundColor: useActiveStyle ? _radioAmber : _meshOffFill,
            foregroundColor: useActiveStyle ? Colors.black : _meshOffForeground,
            disabledBackgroundColor: Colors.white10,
            disabledForegroundColor: Colors.white70,
            elevation: enabled ? 2 : 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        if (isIncomingInvite && onCancelInvite != null) ...[
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: onCancelInvite,
            child: const Text('Decline invite'),
          ),
        ],
      ],
    );
  }

  Widget _buildSecondaryActions({
    required bool isHolding,
    required bool isSending,
    required bool stayOnlineOn,
    required bool stayOnlineEnabled,
    required String stayOnlineHint,
    required VoidCallback? onOpenChat,
    required VoidCallback? onToggleStayOnline,
  }) {
    final stayOnlineIconColor = stayOnlineOn
        ? Colors.green.shade600
        : Colors.grey.shade500;
    final stayOnlineBorderColor = stayOnlineOn
        ? Colors.green.shade600.withAlpha(150)
        : Colors.white.withAlpha(30);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: isHolding || isSending ? null : onOpenChat,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1D2630),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFF232B36),
                  disabledForegroundColor: Colors.white38,
                ),
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('Chat'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: stayOnlineEnabled ? onToggleStayOnline : null,
                style: FilledButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: const Color(0xFF1A212B),
                  disabledBackgroundColor: const Color(0xFF141920),
                  disabledForegroundColor: Colors.white38,
                  side: BorderSide(color: stayOnlineBorderColor),
                ),
                icon: Icon(
                  Icons.wifi_tethering_rounded,
                  size: 18,
                  color: stayOnlineEnabled
                      ? stayOnlineIconColor
                      : Colors.grey.shade700,
                ),
                label: Text(stayOnlineOn ? 'Online' : 'Offline'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          stayOnlineHint,
          style: TextStyle(
            color: Colors.white.withAlpha(180),
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ],
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
                    letterSpacing: 0.9,
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

  Widget _buildWalkieBackdrop() {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: -130,
            left: -100,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFFA126).withAlpha(28),
              ),
            ),
          ),
          Positioned(
            top: 220,
            right: -90,
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF57D163).withAlpha(22),
              ),
            ),
          ),
          Positioned(
            bottom: -120,
            left: 30,
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withAlpha(10),
              ),
            ),
          ),
        ],
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
    final riderState = ref.watch(riderModeControllerProvider);
    final isHolding = state.walkieIsTransmitting;
    final isSending = state.walkieIsSending;
    final selected = state.selectedConversation;
    final targetNodeId = selected is PrivateConversation
        ? selected.peerNodeId
        : state.walkiePeerNodeId;
    final hasTarget = targetNodeId != null && targetNodeId.isNotEmpty;
    final targetPeer = hasTarget ? _peerByNodeId(targetNodeId) : null;
    final targetName = selected is PrivateConversation
        ? selected.peerName
        : targetPeer?.displayName ?? 'Private target';
    final isTargetOnline =
        hasTarget && state.peers.any((p) => p.nodeId == targetNodeId);
    final isIncomingInvite = state.walkieInviteIsIncoming;
    final isActiveSessionForTarget = _isRiderMode
        ? false
        : _isPublicMode
        ? state.meshStarted
        : hasTarget && state.walkieSessionActivePeerNodeId == targetNodeId;
    final isOutgoingInviteForTarget =
        !_isPublicMode &&
        !_isRiderMode &&
        !isIncomingInvite &&
        hasTarget &&
        state.walkieInvitePeerNodeId == targetNodeId &&
        !isActiveSessionForTarget;
    final selectedPrivateContact = !_isPublicMode && hasTarget
        ? state.knownContacts.cast<KnownContact?>().firstWhere(
            (item) => item?.nodeId == targetNodeId,
            orElse: () => null,
          )
        : null;
    final privateStayOnlineEligible =
        selectedPrivateContact != null && selectedPrivateContact.isTrusted;
    final stayOnlineOn = _isPublicMode
        ? state.publicWalkieStayOnline
        : (selectedPrivateContact?.walkieAlwaysOn ?? false);
    final stayOnlineEnabled =
        !_isRiderMode &&
        !(isHolding || isSending) &&
        (_isPublicMode || hasTarget);
    final stayOnlineHint = _isPublicMode
        ? 'Keep receiving public walkie voice across screens.'
        : !hasTarget
        ? 'Select a private target to enable stay online.'
        : privateStayOnlineEligible
        ? 'Latches always-on walkie for this trusted friend.'
        : 'Trust this friend first to enable private stay online.';
    final riderTrustNodeId =
        _isRiderMode && isTargetOnline ? targetPeer?.nodeId : null;
    final riderTrustName = targetPeer?.displayName ?? targetName;
    final speakerActive =
        isHolding ||
        isSending ||
        (_status?.startsWith('Incoming walkie') ?? false);
    _syncSpeakerPulse(speakerActive);
    final controller = ref.read(chatControllerProvider.notifier);
    final actionHintLabel = _isRiderMode
        ? (riderState.isActive
              ? (riderState.isMuted
                    ? 'Rider Mode is live and your mic is muted.'
                    : 'Rider Mode is live. Use mute when needed.')
              : 'Start Rider Mode with a trusted online private peer.')
        : _isPublicMode
        ? (!state.playServicesAvailable
              ? 'Play Services is unavailable on this device.'
              : state.isMeshStarting
              ? 'Mesh is starting up, please wait...'
              : !state.meshStarted
              ? 'Tap Start mesh to go online.'
              : state.peers.isEmpty
              ? 'Scanning for nearby AirGrid users.'
              : 'Hold the mic to broadcast to nearby public peers.')
        : state.isMeshStarting
        ? 'Mesh is starting up, please wait...'
        : !state.meshStarted
        ? 'Start mesh to use walkie.'
        : !hasTarget
        ? 'Choose an online private peer before starting a session.'
        : isActiveSessionForTarget
        ? 'Hold the mic to talk privately with $targetName.'
        : isOutgoingInviteForTarget
        ? 'Waiting for $targetName to accept your walkie invite.'
        : isTargetOnline
        ? 'Tap Invite to start a private session with $targetName.'
        : '$targetName is not online yet.';
    final pttIdleLabel = isActiveSessionForTarget
        ? 'HOLD TO TALK'
        : _isPublicMode
        ? 'START MESH'
        : hasTarget
        ? 'INVITE FIRST'
        : 'CHOOSE SOMEONE';

    return Scaffold(
      backgroundColor: const Color(0xFF07090D),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: Theme.of(context).textTheme.headlineSmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
        title: const Text('Walkie Talkie'),
        actions: [const PublicWalkieStatusIcon()],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _buildWalkieBackdrop()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const padding = EdgeInsets.fromLTRB(16, 12, 16, 24);
                final contentWidth = math.min(
                  560.0,
                  math.max(0.0, constraints.maxWidth - padding.horizontal),
                );

                return Padding(
                  padding: padding,
                  child: Center(
                    child: SizedBox(
                      width: contentWidth,
                      height: math.max(
                        0.0,
                        constraints.maxHeight - padding.vertical,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: contentWidth,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildStatusCard(
                                meshStarted: state.meshStarted,
                                isMeshStarting: state.isMeshStarting,
                                isAdvertising: state.isAdvertising,
                                isDiscovering: state.isDiscovering,
                                playServicesAvailable:
                                    state.playServicesAvailable,
                                peerCount: state.peers.length,
                                onToggleMesh: state.playServicesAvailable
                                    ? () => unawaited(
                                        state.meshStarted
                                            ? controller.stopMesh()
                                            : controller.startMesh(),
                                      )
                                    : null,
                                onToggleAdvertising:
                                    state.playServicesAvailable &&
                                        state.meshStarted
                                    ? () => unawaited(
                                        controller.setAdvertisingEnabled(
                                          !state.isAdvertising,
                                        ),
                                      )
                                    : null,
                                onToggleDiscovering:
                                    state.playServicesAvailable &&
                                        state.meshStarted
                                    ? () => unawaited(
                                        controller.setDiscoveryEnabled(
                                          !state.isDiscovering,
                                        ),
                                      )
                                    : null,
                                onRefreshPeers:
                                    state.playServicesAvailable &&
                                        state.meshStarted
                                    ? () => unawaited(
                                        controller.startMesh(
                                          forceRestart: true,
                                        ),
                                      )
                                    : null,
                              ),
                              const SizedBox(height: 14),
                              _buildModeSelector(
                                isPublicMode: _isPublicMode,
                                isRiderMode: _isRiderMode,
                                onPrivate: () {
                                  setState(() {
                                    _isPublicMode = false;
                                    _isRiderMode = false;
                                    _status = null;
                                  });
                                  unawaited(
                                    ref
                                        .read(chatControllerProvider.notifier)
                                        .publishWalkieAvailability(true),
                                  );
                                },
                                onPublic: () {
                                  setState(() {
                                    _isPublicMode = true;
                                    _isRiderMode = false;
                                    _status = null;
                                  });
                                  unawaited(
                                    ref
                                        .read(chatControllerProvider.notifier)
                                        .publishWalkieAvailability(
                                          stayOnlineOn,
                                        ),
                                  );
                                },
                                onRider: () {
                                  setState(() {
                                    _isPublicMode = false;
                                    _isRiderMode = true;
                                    _status = null;
                                  });
                                  unawaited(
                                    ref
                                        .read(
                                          riderModeControllerProvider.notifier,
                                        )
                                        .armPresence(true),
                                  );
                                },
                              ),
                              const SizedBox(height: 14),
                              _buildTargetCard(
                                isPublicMode: _isPublicMode,
                                hasTarget: hasTarget,
                                targetName: hasTarget
                                    ? targetName
                                    : 'Private target',
                                isTargetOnline: isTargetOnline,
                                canReceivePrivate:
                                    !_isPublicMode &&
                                    isTargetOnline &&
                                    (selectedPrivateContact
                                            ?.remoteWalkieAvailable ??
                                        false),
                                isHolding: isHolding,
                                isSending: isSending,
                                onChooseTarget: _chooseTarget,
                              ),
                              const SizedBox(height: 12),
                              if (_isRiderMode)
                                _buildRiderPanel(
                                  rider: riderState,
                                  targetPeer: targetPeer,
                                  contact: selectedPrivateContact,
                                  meshStarted: state.meshStarted,
                                  isTargetOnline: isTargetOnline,
                                  onTrustTarget: riderTrustNodeId != null
                                      ? () {
                                          unawaited(
                                            controller.trustContact(
                                              riderTrustNodeId,
                                            ),
                                          );
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                '$riderTrustName trusted for Rider Mode',
                                              ),
                                              behavior:
                                                  SnackBarBehavior.floating,
                                              duration: const Duration(
                                                seconds: 2,
                                              ),
                                            ),
                                          );
                                        }
                                      : null,
                                )
                              else
                                _buildSessionActionCard(
                                  isPublicMode: _isPublicMode,
                                  meshStarted: state.meshStarted,
                                  isMeshStarting: state.isMeshStarting,
                                  playServicesAvailable:
                                      state.playServicesAvailable,
                                  hasTarget: hasTarget,
                                  isTargetOnline: isTargetOnline,
                                  isActiveSessionForTarget:
                                      isActiveSessionForTarget,
                                  isIncomingInvite: isIncomingInvite,
                                  isOutgoingInviteForTarget:
                                      isOutgoingInviteForTarget,
                                  onAcceptInvite: () => unawaited(
                                    controller.acceptWalkieInvite(),
                                  ),
                                  onCancelInvite: () => unawaited(
                                    controller.cancelWalkieInvite(),
                                  ),
                                  onEndSession: () =>
                                      unawaited(controller.endWalkieSession()),
                                  onInvite:
                                      targetPeer != null &&
                                          hasTarget &&
                                          isTargetOnline
                                      ? () => unawaited(_invitePeer(targetPeer))
                                      : null,
                                  onStartMesh:
                                      state.playServicesAvailable &&
                                          !state.meshStarted
                                      ? () => unawaited(controller.startMesh())
                                      : null,
                                ),
                              const SizedBox(height: 12),
                              if (!_isRiderMode)
                                _buildSecondaryActions(
                                  isHolding: isHolding,
                                  isSending: isSending,
                                  stayOnlineOn: stayOnlineOn,
                                  stayOnlineEnabled: stayOnlineEnabled,
                                  stayOnlineHint: stayOnlineHint,
                                  onOpenChat: () async {
                                    if (isHolding || isSending) return;
                                    _triggerButtonFeedback();
                                    if (!_isPublicMode) {
                                      unawaited(
                                        controller.publishWalkieAvailability(
                                          stayOnlineOn,
                                        ),
                                      );
                                    }
                                    final navigator = Navigator.of(context);
                                    if (!mounted) return;
                                    await navigator.pushNamed(AppRouter.chat);
                                  },
                                  onToggleStayOnline: () {
                                    if (!stayOnlineEnabled) return;
                                    _triggerButtonFeedback();
                                    if (_isPublicMode) {
                                      controller.setPublicWalkieStayOnline(
                                        !stayOnlineOn,
                                      );
                                    } else if (targetNodeId != null) {
                                      final contact = state.knownContacts
                                          .cast<KnownContact?>()
                                          .firstWhere(
                                            (item) =>
                                                item?.nodeId == targetNodeId,
                                            orElse: () => null,
                                          );
                                      if (contact == null) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Private profile is still syncing. Try again in a moment.',
                                            ),
                                            behavior: SnackBarBehavior.floating,
                                            duration: Duration(seconds: 2),
                                          ),
                                        );
                                        return;
                                      }
                                      if (!contact.isTrusted) {
                                        controller.trustContact(targetNodeId);
                                      }
                                      controller.setWalkieAlwaysOn(
                                        targetNodeId,
                                        !stayOnlineOn,
                                      );
                                    }
                                  },
                                ),
                              const SizedBox(height: 18),
                              if (!_isRiderMode)
                                Center(
                                  child: _buildPttButton(
                                    isEnabled: isActiveSessionForTarget,
                                    isHolding: isHolding,
                                    isSending: isSending,
                                    speakerActive: speakerActive,
                                    idleLabel: pttIdleLabel,
                                    size: 220,
                                    onCancel: isActiveSessionForTarget
                                        ? () =>
                                              unawaited(_cancelHoldRecording())
                                        : null,
                                  ),
                                ),
                              const SizedBox(height: 12),
                              Text(
                                actionHintLabel,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white.withAlpha(210),
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                              if (_status != null) ...[
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.greenAccent.withAlpha(24),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: Colors.greenAccent.withAlpha(90),
                                    ),
                                  ),
                                  child: Text(
                                    _status!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.greenAccent.shade200,
                                      fontSize: 13,
                                      height: 1.3,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
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
        ],
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
