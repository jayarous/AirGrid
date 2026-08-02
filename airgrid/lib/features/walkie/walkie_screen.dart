import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/help_provider.dart';
import 'package:airgrid/core/help_target.dart';
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
  late final AnimationController _speakerPulseController;
  late final Animation<double> _speakerPulse;
  Timer? _ticker;
  Timer? _statusClearTimer;
  AudioPlayer? _incomingPlayer;

  Duration _elapsed = Duration.zero;
  String? _status;

  /// When true the user is in open public-channel broadcast mode.
  /// When false (default) the private invite/session flow is active.
  bool _isPublicMode = false;
  bool _isRiderMode = false;

  @override
  void initState() {
    super.initState();
    final selectedConv = ref.read(chatControllerProvider).selectedConversation;
    _isPublicMode = selectedConv is PublicConversation;
    // Restore rider mode from the controller so re-entering the screen doesn't
    // silently drop an armed rider session (leaving isArmed latched).
    _isRiderMode =
        !_isPublicMode && ref.read(riderModeControllerProvider).isArmed;

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
          : state.walkie.peerNodeId;
      final keepAvailable =
          !_isPublicMode &&
          _isAlwaysOnTrusted(state.knownContacts, targetNodeId);
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
    _ticker?.cancel();
    _statusClearTimer?.cancel();
    unawaited(_incomingPlayer?.dispose() ?? Future<void>.value());
    unawaited(_audioRecorder.dispose());
    _speakerPulseController.dispose();
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

  void _triggerButtonFeedback() {
    HapticFeedback.selectionClick();
    SystemSound.play(SystemSoundType.click);
  }

  void _setStatus(String message) {
    if (!mounted) return;
    setState(() {
      _status = message;
    });
    _scheduleStatusClear();
  }

  /// Clears a one-off [_status] message after a few seconds so the
  /// contextual action hint (driven by live controller state) becomes
  /// visible again, instead of staying masked for the rest of the screen's
  /// lifetime. Reschedules itself while a transmit/send is in flight so it
  /// never wipes live recording/sending feedback out from under the user.
  void _scheduleStatusClear() {
    _statusClearTimer?.cancel();
    _statusClearTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      final state = ref.read(chatControllerProvider);
      if (state.walkie.isTransmitting || state.walkie.isSending) {
        _scheduleStatusClear();
        return;
      }
      setState(() {
        _status = null;
      });
    });
  }

  String? _currentTargetNodeId() {
    final state = ref.read(chatControllerProvider);
    final selected = state.selectedConversation;
    if (selected is PrivateConversation) {
      return selected.peerNodeId;
    }
    return state.walkie.peerNodeId;
  }

  Future<void> _handleIncomingWalkieUpdates(
    List<AirGridMessage>? previous,
    List<AirGridMessage> next,
  ) async {
    if (previous == null) return;

    final state = ref.read(chatControllerProvider);
    final selected = state.selectedConversation;
    if ((_isPublicMode && state.walkie.publicStayOnline) ||
        (!_isPublicMode &&
            selected is PrivateConversation &&
            _isAlwaysOnTrusted(state.knownContacts, selected.peerNodeId))) {
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
          .walkie
          .sessionActivePeerNodeId;
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

  /// Resolves the current private walkie target without mutating state.
  ///
  /// Returns the selected [PrivateConversation], or reconstructs one from the
  /// rider/latched [WalkieState.peerNodeId] if a peer for it is online.
  /// Returns null when no target is chosen — callers surface a "choose a peer"
  /// prompt rather than silently latching onto an arbitrary online peer.
  PrivateConversation? _currentTarget() {
    final state = ref.read(chatControllerProvider);
    final selected = state.selectedConversation;
    if (selected is PrivateConversation) {
      return selected;
    }

    final peer = _peerByNodeId(state.walkie.peerNodeId);
    if (peer == null || peer.nodeId == null) {
      return null;
    }
    return PrivateConversation(
      peerNodeId: peer.nodeId!,
      peerName: peer.displayName,
    );
  }

  MeshPeer? _peerByNodeId(String? nodeId) {
    if (nodeId == null) return null;
    final state = ref.read(chatControllerProvider);
    return state.peers.cast<MeshPeer?>().firstWhere(
      (peer) => peer?.nodeId == nodeId,
      orElse: () => null,
    );
  }

  /// True when [nodeId] belongs to a trusted contact with always-on walkie
  /// enabled — the condition that lets private walkie skip the invite/accept
  /// flow (keep-available on dispose, auto-play incoming audio, auto-invite).
  bool _isAlwaysOnTrusted(List<KnownContact> knownContacts, String? nodeId) {
    if (nodeId == null) return false;
    return knownContacts.any(
      (contact) =>
          contact.nodeId == nodeId &&
          contact.isTrusted &&
          contact.walkieAlwaysOn,
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
    if (!_isAlwaysOnTrusted(state.knownContacts, target.peerNodeId)) {
      return;
    }
    if (state.walkie.invitePeerNodeId == target.peerNodeId ||
        state.walkie.sessionActivePeerNodeId == target.peerNodeId) {
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
      _setStatus('No online private peers available yet');
      return;
    }

    final selectedNodeId = await _showChooseTargetSheet(candidates);
    if (selectedNodeId == null) {
      _setStatus('Target selection canceled');
      return;
    }

    if (selectedNodeId.startsWith('invite:')) {
      final peerNodeId = selectedNodeId.substring('invite:'.length);
      final selectedPeer = candidates.cast<MeshPeer?>().firstWhere(
        (peer) => peer?.nodeId == peerNodeId,
        orElse: () => null,
      );
      if (selectedPeer == null) return;
      if (_isRiderMode) {
        ref
            .read(chatControllerProvider.notifier)
            .setWalkiePeerNodeId(peerNodeId);
        _setStatus('Rider target set to ${selectedPeer.displayName}');
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
      _setStatus('Rider target set to ${selectedPeer.displayName}');
    } else {
      controller.selectConversation(
        PrivateConversation(
          peerNodeId: selectedNodeId,
          peerName: selectedPeer.displayName,
        ),
      );
      _setStatus('Private target set to ${selectedPeer.displayName}');
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
                        color: Colors.white,
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
                  separatorBuilder: (_, _) => const Divider(
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

  Future<void> _startHoldRecording() async {
    _triggerButtonFeedback();
    final current = ref.read(chatControllerProvider);
    if (current.walkie.isTransmitting || current.walkie.isSending) {
      _setStatus('Walkie is already busy');
      return;
    }

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
        _setStatus('Select an online private peer first');
        return;
      }

      if (current.walkie.sessionActivePeerNodeId != target.peerNodeId) {
        // No active session yet. For trusted always-on contacts, transparently
        // re-invite so pressing PTT reconnects instead of dead-ending on an
        // error. For everyone else, ask the user to invite and wait for accept.
        final canAutoInvite = _isAlwaysOnTrusted(
          current.knownContacts,
          target.peerNodeId,
        );
        if (canAutoInvite) {
          if (current.walkie.invitePeerNodeId != target.peerNodeId) {
            final peer = _peerByNodeId(target.peerNodeId);
            if (peer != null) {
              unawaited(_invitePeer(peer));
            }
          }
          _setStatus('Reconnecting walkie... invite sent');
          return;
        }

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
        _setStatus('Invite and wait for accept before talking');
        return;
      }
      peerNodeIdForSession = target.peerNodeId;
    }

    // record's hasPermission() requests the OS mic permission itself when
    // not already granted, so a separate permission_handler request here
    // would just be a redundant duplicate prompt.
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
      _setStatus('Microphone permission denied');
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
      _setStatus('Failed to start walkie recording');
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
      if (!mounted || !ref.read(chatControllerProvider).walkie.isTransmitting) {
        return;
      }
      setState(() {
        _elapsed = _holdStopwatch.elapsed;
      });
    });
  }

  /// Best-effort deletion of a recorded walkie temp file. No-op on null/empty
  /// paths; swallows filesystem errors since cleanup must never block the flow.
  Future<void> _deleteRecordedFile(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cleanup only.
    }
  }

  Future<void> _cancelHoldRecording() async {
    if (!ref.read(chatControllerProvider).walkie.isTransmitting) return;
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

    await _deleteRecordedFile(path);

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
    if (!current.walkie.isTransmitting || current.walkie.isSending) return;

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

    // Once a send is attempted the controller owns the temp file (it may
    // persist the message with localTempPath for playback/retry), so we only
    // clean up the recording on failures that occur *before* the send.
    var sendAttempted = false;
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
      if (bytes.isEmpty) {
        throw const _WalkieSendException('Recording was empty');
      }
      if (bytes.length > AirGridConstants.kWalkieMaxBytes) {
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
          sendAttempted = true;
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
                        peer.displayName,
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
        await _deleteRecordedFile(recordedPath);

        // The delete is awaited, so the screen may be gone by now; the branch
        // below only navigates, which is exactly what a disposed screen must
        // not do.
        if (!mounted) return;

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

      sendAttempted = true;
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
      if (!sendAttempted) await _deleteRecordedFile(recordedPath);
      if (!mounted) return;
      ref
          .read(chatControllerProvider.notifier)
          .setWalkieSending(isSending: false);
      ref.read(chatControllerProvider.notifier).setWalkieLastError(e.message);
      setState(() {
        _status = e.message;
      });
    } catch (_) {
      if (!sendAttempted) await _deleteRecordedFile(recordedPath);
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
  static const Color _meshOffFill = Color(0xFF2A3038);
  static const Color _meshOffBorder = Color(0xFF545B66);
  static const Color _meshOffForeground = Color(0xFFB6BDC7);

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
      return Semantics(
        label: '$label walkie mode',
        hint: selected ? 'Currently selected' : 'Switch to $label mode',
        button: true,
        selected: selected,
        child: AnimatedContainer(
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
    final canStart = meshStarted && hasUsableTarget && isTrustedTarget;
    final riderSegmentStyle = ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? _radioAmber
            : const Color(0xFF151C25);
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? Colors.black
            : Colors.white.withAlpha(220);
      }),
      iconColor: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? Colors.black
            : Colors.white.withAlpha(220);
      }),
      side: WidgetStateProperty.resolveWith((states) {
        return BorderSide(
          color: states.contains(WidgetState.selected)
              ? _radioAmber
              : Colors.white.withAlpha(55),
        );
      }),
      overlayColor: WidgetStatePropertyAll(Colors.white.withAlpha(18)),
    );
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
                  style: riderSegmentStyle,
                  onSelectionChanged: (value) {
                    final mode = value.first;
                    _triggerButtonFeedback();
                    _setStatus(
                      mode == RiderMicMode.alwaysOpen
                          ? 'Rider mic set to open'
                          : 'Rider mic set to voice activated',
                    );
                    unawaited(riderController.setMicMode(mode));
                  },
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
                  style: riderSegmentStyle,
                  onSelectionChanged: (value) {
                    final policy = value.first;
                    _triggerButtonFeedback();
                    _setStatus(
                      policy == RiderStartPolicy.trustedAutoJoin
                          ? 'Rider auto-join enabled'
                          : 'Rider ask-to-start enabled',
                    );
                    unawaited(riderController.setStartPolicy(policy));
                  },
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
              onPressed: () {
                _triggerButtonFeedback();
                _setStatus('Trusting ${targetPeer.displayName}...');
                onTrustTarget();
              },
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
                    onPressed: () {
                      _triggerButtonFeedback();
                      _setStatus('Rider Mode invite declined');
                      unawaited(riderController.declineIncoming());
                    },
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      _triggerButtonFeedback();
                      _setStatus('Accepting Rider Mode invite...');
                      unawaited(riderController.acceptIncoming());
                    },
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
                        ? () {
                            _triggerButtonFeedback();
                            _setStatus('Ending Rider Mode...');
                            unawaited(riderController.endSession());
                          }
                        : canStart && !rider.isStarting
                        ? () {
                            _triggerButtonFeedback();
                            _setStatus('Starting Rider Mode...');
                            unawaited(riderController.startSession(targetPeer));
                          }
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
                    onPressed: () {
                      _triggerButtonFeedback();
                      _setStatus(
                        rider.isMuted
                            ? 'Rider microphone unmuted'
                            : 'Rider microphone muted',
                      );
                      unawaited(riderController.setMuted(!rider.isMuted));
                    },
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
          const SizedBox(height: 16),
          SizedBox(
            height: 40,
            child: isPublicMode
                ? const SizedBox.shrink()
                : FilledButton.tonal(
                    onPressed: isHolding || isSending ? null : onChooseTarget,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1D2630),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFF232B36),
                      disabledForegroundColor: Colors.white38,
                    ),
                    child: const Text('Choose person'),
                  ),
          ),
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

    return Semantics(
      label: 'Push to talk',
      hint: isEnabled
          ? 'Hold and release to send a walkie voice clip'
          : 'Start a walkie session first',
      button: true,
      child: GestureDetector(
        onLongPressStart: isEnabled
            ? (_) => unawaited(_startHoldRecording())
            : null,
        onLongPressEnd: isEnabled ? (_) => unawaited(_stopHoldAndSend()) : null,
        onLongPressCancel: isEnabled
            ? () => unawaited(_cancelHoldRecording())
            : null,
        onTap: isHolding
            ? onCancel
            : !isEnabled
            ? () {
                _triggerButtonFeedback();
                _setStatus(idleLabel);
              }
            : null,
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
                  border: Border.all(
                    color: Colors.white.withAlpha(22),
                    width: 2,
                  ),
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(
      chatControllerProvider.select((state) => state.walkie.lastError),
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
    final isHolding = state.walkie.isTransmitting;
    final isSending = state.walkie.isSending;
    final selected = state.selectedConversation;
    final targetNodeId = selected is PrivateConversation
        ? selected.peerNodeId
        : state.walkie.peerNodeId;
    final hasTarget = targetNodeId != null && targetNodeId.isNotEmpty;
    final targetPeer = hasTarget ? _peerByNodeId(targetNodeId) : null;
    final targetName = selected is PrivateConversation
        ? selected.peerName
        : targetPeer?.displayName ?? 'Private target';
    final isTargetOnline =
        hasTarget && state.peers.any((p) => p.nodeId == targetNodeId);
    final isIncomingInvite = state.walkie.inviteIsIncoming;
    final isActiveSessionForTarget = _isRiderMode
        ? false
        : _isPublicMode
        ? state.meshStarted
        : hasTarget && state.walkie.sessionActivePeerNodeId == targetNodeId;
    final isOutgoingInviteForTarget =
        !_isPublicMode &&
        !_isRiderMode &&
        !isIncomingInvite &&
        hasTarget &&
        state.walkie.invitePeerNodeId == targetNodeId &&
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
        ? state.walkie.publicStayOnline
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
    final riderTrustNodeId = _isRiderMode && isTargetOnline
        ? targetPeer?.nodeId
        : null;
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
        actions: [
          Consumer(
            builder: (context, ref, _) {
              final helpMode = ref.watch(helpModeProvider);
              return IconButton(
                icon: Icon(helpMode ? Icons.help : Icons.help_outline),
                tooltip: helpMode ? 'Exit help mode' : 'Help',
                onPressed: () =>
                    ref.read(helpModeProvider.notifier).state = !helpMode,
              );
            },
          ),
          const PublicWalkieStatusIcon(),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const padding = EdgeInsets.fromLTRB(16, 12, 16, 24);
                final contentWidth = math.min(
                  560.0,
                  math.max(0.0, constraints.maxWidth - padding.horizontal),
                );

                return SingleChildScrollView(
                  padding: padding,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(
                        0.0,
                        constraints.maxHeight - padding.vertical,
                      ),
                    ),
                    child: Center(
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
                                  ? () {
                                      _triggerButtonFeedback();
                                      _setStatus(
                                        state.meshStarted
                                            ? 'Stopping mesh...'
                                            : 'Starting mesh...',
                                      );
                                      unawaited(
                                        state.meshStarted
                                            ? controller.stopMesh()
                                            : controller.startMesh(),
                                      );
                                    }
                                  : null,
                              onToggleAdvertising:
                                  state.playServicesAvailable &&
                                      state.meshStarted
                                  ? () {
                                      final next = !state.isAdvertising;
                                      _triggerButtonFeedback();
                                      _setStatus(
                                        next
                                            ? 'Availability turned on'
                                            : 'Availability turned off',
                                      );
                                      unawaited(
                                        controller.setAdvertisingEnabled(next),
                                      );
                                    }
                                  : null,
                              onToggleDiscovering:
                                  state.playServicesAvailable &&
                                      state.meshStarted
                                  ? () {
                                      final next = !state.isDiscovering;
                                      _triggerButtonFeedback();
                                      _setStatus(
                                        next
                                            ? 'Scanning turned on'
                                            : 'Scanning turned off',
                                      );
                                      unawaited(
                                        controller.setDiscoveryEnabled(next),
                                      );
                                    }
                                  : null,
                              onRefreshPeers:
                                  state.playServicesAvailable &&
                                      state.meshStarted
                                  ? () {
                                      _triggerButtonFeedback();
                                      _setStatus('Refreshing nearby peers...');
                                      unawaited(
                                        controller.startMesh(
                                          forceRestart: true,
                                        ),
                                      );
                                    }
                                  : null,
                            ),
                            const SizedBox(height: 14),
                            HelpTarget(
                              title: 'Walkie Mode',
                              description:
                                  'Choose how you want to use walkie:\n'
                                  '• Private: one-to-one session with a specific peer.\n'
                                  '• Public: broadcast to all nearby AirGrid users.\n'
                                  '• Rider: hands-free mode with a trusted peer.',
                              child: _buildModeSelector(
                                isPublicMode: _isPublicMode,
                                isRiderMode: _isRiderMode,
                                onPrivate: () {
                                  setState(() {
                                    _isPublicMode = false;
                                    _isRiderMode = false;
                                  });
                                  _setStatus('Private mode selected');
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
                                  });
                                  _setStatus('Public mode selected');
                                  unawaited(
                                    ref
                                        .read(chatControllerProvider.notifier)
                                        .publishWalkieAvailability(
                                          ref
                                              .read(chatControllerProvider)
                                              .walkie
                                              .publicStayOnline,
                                        ),
                                  );
                                },
                                onRider: () {
                                  setState(() {
                                    _isPublicMode = false;
                                    _isRiderMode = true;
                                  });
                                  _setStatus('Rider mode selected');
                                  unawaited(
                                    ref
                                        .read(
                                          riderModeControllerProvider.notifier,
                                        )
                                        .armPresence(true),
                                  );
                                },
                              ),
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
                                            behavior: SnackBarBehavior.floating,
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
                                onAcceptInvite: () {
                                  _triggerButtonFeedback();
                                  _setStatus('Accepting walkie invite...');
                                  unawaited(controller.acceptWalkieInvite());
                                },
                                onCancelInvite: () {
                                  _triggerButtonFeedback();
                                  _setStatus('Walkie invite canceled');
                                  unawaited(controller.cancelWalkieInvite());
                                },
                                onEndSession: () {
                                  _triggerButtonFeedback();
                                  _setStatus('Ending walkie session...');
                                  unawaited(controller.endWalkieSession());
                                },
                                onInvite:
                                    targetPeer != null &&
                                        hasTarget &&
                                        isTargetOnline
                                    ? () {
                                        _triggerButtonFeedback();
                                        _setStatus(
                                          'Sending invite to $targetName...',
                                        );
                                        unawaited(_invitePeer(targetPeer));
                                      }
                                    : null,
                                onStartMesh:
                                    state.playServicesAvailable &&
                                        !state.meshStarted
                                    ? () {
                                        _triggerButtonFeedback();
                                        _setStatus('Starting mesh...');
                                        unawaited(controller.startMesh());
                                      }
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
                                  _setStatus('Opening chat...');
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
                                    _setStatus(
                                      !stayOnlineOn
                                          ? 'Public stay online turned on'
                                          : 'Public stay online turned off',
                                    );
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
                                      _setStatus(
                                        'Private profile is still syncing',
                                      );
                                      return;
                                    }
                                    if (!contact.isTrusted) {
                                      controller.trustContact(targetNodeId);
                                    }
                                    _setStatus(
                                      !stayOnlineOn
                                          ? 'Private stay online turned on'
                                          : 'Private stay online turned off',
                                    );
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
                                child: HelpTarget(
                                  title: 'Push to Talk',
                                  description:
                                      'Hold the mic button to start recording. '
                                      'Release to send your walkie voice clip. '
                                      'Make sure you have an active session '
                                      '(invite accepted) before using PTT.',
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
                              ),
                            const SizedBox(height: 12),
                            Text(
                              _status ?? actionHintLabel,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _status == null
                                    ? Colors.white.withAlpha(210)
                                    : Colors.greenAccent.shade200,
                                fontSize: 13,
                                height: 1.4,
                                fontWeight: _status == null
                                    ? FontWeight.w400
                                    : FontWeight.w600,
                              ),
                            ),
                          ],
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
