import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/ephemeral_media_cache.dart';
import 'package:airgrid/core/help_provider.dart';
import 'package:airgrid/core/help_target.dart';
import 'package:airgrid/core/mesh_permissions.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/local_report.dart';
import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/chat_state.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:airgrid/features/chat/message_bubble.dart';
import 'package:airgrid/features/mesh_status/mesh_status_panel.dart';
import 'package:airgrid/features/profile/peer_profile_sheet.dart';
import 'package:airgrid/features/walkie/public_walkie_status_icon.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  late final FocusNode _inputFocusNode;
  final _imagePicker = ImagePicker();
  final _mediaCache = EphemeralMediaCache();
  final _audioRecorder = AudioRecorder();
  bool _showStatus = false;
  bool _dismissPermissionBanner = false;
  MeshPermissionsSnapshot? _permissionsSnapshot;
  bool _isRecordingVoice = false;
  bool _isVoiceRecordingPaused = false;
  final Stopwatch _voiceStopwatch = Stopwatch();
  Duration _voiceRecordingElapsed = Duration.zero;
  Timer? _voiceTicker;

  @override
  void initState() {
    super.initState();
    _inputFocusNode = FocusNode();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(chatControllerProvider.notifier).startMesh();
    });
    _refreshPermissionStatus();
    unawaited(_mediaCache.cleanup());
  }

  Future<void> _restoreFocus() async {
    // Restore focus after a short delay to allow the widget tree to stabilize
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted || _isRecordingVoice) return;
    _inputFocusNode.requestFocus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    _voiceTicker?.cancel();
    unawaited(_audioRecorder.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionStatus();
    }
    ref.read(chatControllerProvider.notifier).handleAppLifecycleState(state);
  }

  Future<void> _refreshPermissionStatus() async {
    final snapshot = await ref.read(meshPermissionsProvider).checkStatuses();
    if (!mounted) return;
    setState(() {
      _permissionsSnapshot = snapshot;
      if (!snapshot.hasMissingCriticalPermissions) {
        _dismissPermissionBanner = false;
      }
    });
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();

    final chatState = ref.read(chatControllerProvider);
    final conv = chatState.selectedConversation;

    if (conv is PrivateConversation) {
      final peer = _resolvePrivatePeer(chatState, conv);

      if (peer != null) {
        _selectResolvedPeerIfNeeded(conv, peer);
        // Direct peer — allow plaintext fallback after confirmation.
        var result = await ref
            .read(chatControllerProvider.notifier)
            .sendPrivateMessage(peer, text);

        if (result == PrivateSendResult.needsPlaintextConfirmation) {
          if (!mounted) return;
          final confirmed = await _showPlaintextConfirmDialog(
            context,
            peer.displayName,
          );
          if (!mounted || !confirmed) return;
          result = await ref
              .read(chatControllerProvider.notifier)
              .sendPrivateMessage(peer, text, allowPlaintextFallback: true);
        }

        if (!mounted) return;
        if (result == PrivateSendResult.blockedContact) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('This user is blocked'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        final ok =
            result == PrivateSendResult.sentEncrypted ||
            result == PrivateSendResult.sentPlaintext;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? 'Sent' : 'Failed to send message'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        // Not directly connected — use encrypted relay via known contact.
        final contact = chatState.knownContacts
            .cast<KnownContact?>()
            .firstWhere(
              (c) => c?.nodeId == conv.peerNodeId,
              orElse: () => null,
            );
        if (contact == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Contact not reachable'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        final result = await ref
            .read(chatControllerProvider.notifier)
            .sendPrivateMessageToContact(contact, text);
        if (!mounted) return;
        if (result == PrivateSendResult.blockedContact) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('This user is blocked'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        final ok = result == PrivateSendResult.sentEncrypted;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? 'Sent (encrypted)' : 'Failed to send message'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else {
      // Public send.
      final ok = await ref
          .read(chatControllerProvider.notifier)
          .sendMessage(text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? 'Sent' : 'Failed to send message'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    
    await _restoreFocus();
  }

  MeshPeer? _resolvePrivatePeer(ChatState chatState, PrivateConversation conv) {
    final exact = chatState.peers.cast<MeshPeer?>().firstWhere(
      (p) => p?.nodeId == conv.peerNodeId,
      orElse: () => null,
    );
    if (exact != null) return exact;

    final contact = chatState.knownContacts.cast<KnownContact?>().firstWhere(
      (c) => c?.nodeId == conv.peerNodeId,
      orElse: () => null,
    );
    if (contact == null) return null;

    final matchingOnlinePeers = chatState.peers
        .where(
          (peer) =>
              peer.nodeId != null &&
              peer.displayName.trim().toLowerCase() ==
                  contact.displayName.trim().toLowerCase(),
        )
        .toList();
    return matchingOnlinePeers.length == 1 ? matchingOnlinePeers.single : null;
  }

  void _selectResolvedPeerIfNeeded(PrivateConversation conv, MeshPeer peer) {
    final nodeId = peer.nodeId;
    if (nodeId == null || nodeId == conv.peerNodeId) return;
    ref
        .read(chatControllerProvider.notifier)
        .selectConversation(
          PrivateConversation(peerNodeId: nodeId, peerName: peer.displayName),
        );
  }

  Future<void> _pickAndSendImage() async {
    final controller = ref.read(chatControllerProvider.notifier);
    controller.beginForegroundCriticalAction();
    try {
      final chatState = ref.read(chatControllerProvider);
      if (chatState.selectedConversation is! PrivateConversation) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Photo sharing is available only in private chats'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      var permission = await Permission.photos.request();
      if (!permission.isGranted && Platform.isAndroid) {
        permission = await Permission.storage.request();
      }
      if (!permission.isGranted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Photo permission denied'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      Uint8List bytes;
      try {
        bytes = await picked.readAsBytes();
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to read image'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        quality: 72,
        minWidth: 1280,
        minHeight: 1280,
      );

      if (compressed.isEmpty ||
          compressed.length > AirGridConstants.kPrivatePhotoMaxBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Photo is too large after compression. Maximum is '
              '${_formatBytes(AirGridConstants.kPrivatePhotoMaxBytes)}.',
            ),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      int? width;
      int? height;
      try {
        final codec = await ui.instantiateImageCodec(
          Uint8List.fromList(compressed),
        );
        final frame = await codec.getNextFrame();
        width = frame.image.width;
        height = frame.image.height;
      } catch (_) {
        // Best effort dimensions.
      }

      final transferId = const Uuid().v4();
      String localPath;
      try {
        localPath = await _mediaCache.writeImageBytes(
          transferId,
          Uint8List.fromList(compressed),
        );
      } catch (_) {
        // Keep picker file path fallback so the sender still has a preview.
        localPath = picked.path;
      }
      final payload = ImageAttachmentPayload(
        transferId: transferId,
        mimeType: 'image/jpeg',
        byteLength: compressed.length,
        width: width,
        height: height,
        dataBase64: base64Encode(compressed),
        localTempPath: localPath,
      );

      if (!await controller.waitForMeshReady()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mesh is still reconnecting. Please try again.'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      if (!await controller.waitForPeerOnline(
        ref.read(chatControllerProvider).selectedConversation
                is PrivateConversation
            ? (ref.read(chatControllerProvider).selectedConversation
                      as PrivateConversation)
                  .peerNodeId
            : '',
      )) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Recipient is still coming online. Please try again.',
            ),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      await _sendImagePayload(payload);
    } finally {
      controller.endForegroundCriticalAction();
    }
  }

  Future<void> _pickAndSendFile() async {
    final controller = ref.read(chatControllerProvider.notifier);
    controller.beginForegroundCriticalAction();
    try {
      final chatState = ref.read(chatControllerProvider);
      if (chatState.selectedConversation is! PrivateConversation) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File sharing is available only in private chats'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      FocusScope.of(context).unfocus();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Attach a file',
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;
      final fileName = file.name;
      if (file.size > AirGridConstants.kPrivateFileMaxBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'File is too large. Maximum is '
              '${_formatBytes(AirGridConstants.kPrivateFileMaxBytes)}.',
            ),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      Uint8List bytes;
      if (file.bytes != null) {
        bytes = file.bytes!;
      } else if (file.path != null && file.path!.isNotEmpty) {
        bytes = await File(file.path!).readAsBytes();
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Selected file is unavailable'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final payload = FileAttachmentPayload(
        transferId: const Uuid().v4(),
        fileName: fileName,
        mimeType:
            lookupMimeType(fileName, headerBytes: bytes) ??
            'application/octet-stream',
        byteLength: bytes.length,
        dataBase64: base64Encode(bytes),
        localTempPath: file.path,
      );

      if (!await controller.waitForMeshReady()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mesh is still reconnecting. Please try again.'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final selectedConversation = ref
          .read(chatControllerProvider)
          .selectedConversation;
      if (selectedConversation is! PrivateConversation) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File sharing is available only in private chats'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      if (!await controller.waitForPeerOnline(
        selectedConversation.peerNodeId,
      )) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Recipient is still coming online. Please try again.',
            ),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      await _sendFilePayload(payload, messageId: const Uuid().v4());
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('File picker failed: ${e.message ?? e.code}'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      controller.endForegroundCriticalAction();
    }
  }

  Future<void> _sendFilePayload(
    FileAttachmentPayload payload, {
    required String messageId,
  }) async {
    final chatState = ref.read(chatControllerProvider);
    final conv = chatState.selectedConversation;
    if (conv is! PrivateConversation) return;

    final peer = _resolvePrivatePeer(chatState, conv);

    PrivateSendResult result;
    if (peer != null) {
      _selectResolvedPeerIfNeeded(conv, peer);
      result = await ref
          .read(chatControllerProvider.notifier)
          .sendPrivateFile(
            peer,
            payload,
            messageId: messageId,
            packetId: messageId,
            onProgress: (progress) {
              if (!mounted) return;
              ref
                  .read(chatControllerProvider.notifier)
                  .updateOutgoingFileProgress(messageId, progress);
            },
          );

      if (result == PrivateSendResult.needsPlaintextConfirmation) {
        if (!mounted) return;
        final confirmed = await _showPlaintextConfirmDialog(
          context,
          peer.displayName,
        );
        if (!mounted || !confirmed) return;
        result = await ref
            .read(chatControllerProvider.notifier)
            .sendPrivateFile(
              peer,
              payload,
              messageId: messageId,
              packetId: messageId,
              allowPlaintextFallback: true,
              onProgress: (progress) {
                if (!mounted) return;
                ref
                    .read(chatControllerProvider.notifier)
                    .updateOutgoingFileProgress(messageId, progress);
              },
            );
      }
    } else {
      final contact = chatState.knownContacts.cast<KnownContact?>().firstWhere(
        (c) => c?.nodeId == conv.peerNodeId,
        orElse: () => null,
      );
      if (contact == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contact not reachable'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      result = await ref
          .read(chatControllerProvider.notifier)
          .sendPrivateFileToContact(
            contact,
            payload,
            messageId: messageId,
            packetId: messageId,
            onProgress: (progress) {
              if (!mounted) return;
              ref
                  .read(chatControllerProvider.notifier)
                  .updateOutgoingFileProgress(messageId, progress);
            },
          );
    }

    if (!mounted) return;
    final ok =
        result == PrivateSendResult.sentEncrypted ||
        result == PrivateSendResult.sentPlaintext;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'File sent' : 'Failed to send file'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _sendImagePayload(ImageAttachmentPayload payload) async {
    final chatState = ref.read(chatControllerProvider);
    final conv = chatState.selectedConversation;
    if (conv is! PrivateConversation) return;

    final peer = _resolvePrivatePeer(chatState, conv);

    PrivateSendResult result;
    if (peer != null) {
      _selectResolvedPeerIfNeeded(conv, peer);
      result = await ref
          .read(chatControllerProvider.notifier)
          .sendPrivateImage(peer, payload);

      if (result == PrivateSendResult.needsPlaintextConfirmation) {
        if (!mounted) return;
        final confirmed = await _showPlaintextConfirmDialog(
          context,
          peer.displayName,
        );
        if (!mounted || !confirmed) return;
        result = await ref
            .read(chatControllerProvider.notifier)
            .sendPrivateImage(peer, payload, allowPlaintextFallback: true);
      }
    } else {
      final contact = chatState.knownContacts.cast<KnownContact?>().firstWhere(
        (c) => c?.nodeId == conv.peerNodeId,
        orElse: () => null,
      );
      if (contact == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contact not reachable'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      result = await ref
          .read(chatControllerProvider.notifier)
          .sendPrivateImageToContact(contact, payload);
    }

    if (!mounted) return;
    final ok =
        result == PrivateSendResult.sentEncrypted ||
        result == PrivateSendResult.sentPlaintext;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Photo sent' : 'Failed to send photo'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleVoiceControlTap() async {
    if (!_isRecordingVoice) {
      await _startVoiceRecording();
      return;
    }

    if (_isVoiceRecordingPaused) {
      await _resumeVoiceRecording();
      return;
    }

    await _pauseVoiceRecording();
  }

  Future<void> _startVoiceRecording() async {
    final chatState = ref.read(chatControllerProvider);
    if (chatState.selectedConversation is! PrivateConversation) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Voice notes are available only in private chats'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final micPermission = await Permission.microphone.request();
    if (!micPermission.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Microphone permission denied'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final hasRecordPermission = await _audioRecorder.hasPermission();
    if (!hasRecordPermission && !await _audioRecorder.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Microphone permission denied'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final tempDir = await getTemporaryDirectory();
    final filePath = '${tempDir.path}\\airgrid_voice_${const Uuid().v4()}.m4a';

    try {
      await _audioRecorder.start(
        const RecordConfig(bitRate: 24000, sampleRate: 16000),
        path: filePath,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to start recording'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    _voiceTicker?.cancel();
    _voiceStopwatch
      ..reset()
      ..start();
    if (!mounted) return;
    setState(() {
      _isRecordingVoice = true;
      _isVoiceRecordingPaused = false;
      _voiceRecordingElapsed = Duration.zero;
    });
    _voiceTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_isRecordingVoice) return;
      setState(() {
        _voiceRecordingElapsed = _voiceStopwatch.elapsed;
      });
    });
  }

  Future<void> _pauseVoiceRecording() async {
    if (!_isRecordingVoice || _isVoiceRecordingPaused) return;
    try {
      await _audioRecorder.pause();
      _voiceStopwatch.stop();
      if (!mounted) return;
      setState(() {
        _isVoiceRecordingPaused = true;
        _voiceRecordingElapsed = _voiceStopwatch.elapsed;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to pause recording'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _resumeVoiceRecording() async {
    if (!_isRecordingVoice || !_isVoiceRecordingPaused) return;
    try {
      await _audioRecorder.resume();
      _voiceStopwatch.start();
      if (!mounted) return;
      setState(() {
        _isVoiceRecordingPaused = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to resume recording'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _stopAndSendVoiceNote() async {
    if (!_isRecordingVoice) return;

    _voiceTicker?.cancel();
    _voiceTicker = null;
    _voiceStopwatch.stop();
    final duration = _voiceStopwatch.elapsed;
    _voiceStopwatch.reset();
    setState(() {
      _isRecordingVoice = false;
      _isVoiceRecordingPaused = false;
      _voiceRecordingElapsed = Duration.zero;
    });

    final controller = ref.read(chatControllerProvider.notifier);
    controller.beginForegroundCriticalAction();
    try {
      String? recordedPath;
      try {
        recordedPath = await _audioRecorder.stop();
      } catch (_) {
        recordedPath = null;
      }

      if (recordedPath == null || recordedPath.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording canceled'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final file = File(recordedPath);
      if (!file.existsSync()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recorded audio is unavailable'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      if (duration < AirGridConstants.kPrivateVoiceNoteMinDuration) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Voice note is too short. Minimum is '
              '${_formatDuration(AirGridConstants.kPrivateVoiceNoteMinDuration)}.',
            ),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      if (duration > AirGridConstants.kPrivateVoiceNoteMaxDuration) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Voice note is too long. Maximum is '
              '${_formatDuration(AirGridConstants.kPrivateVoiceNoteMaxDuration)}.',
            ),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to read recorded audio'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      if (bytes.isEmpty ||
          bytes.length > AirGridConstants.kPrivateVoiceNoteMaxBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Voice note is too large. Maximum is '
              '${_formatBytes(AirGridConstants.kPrivateVoiceNoteMaxBytes)}.',
            ),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final payload = AudioAttachmentPayload(
        transferId: const Uuid().v4(),
        mimeType: 'audio/m4a',
        byteLength: bytes.length,
        durationMs: duration.inMilliseconds,
        source: AudioAttachmentPayload.sourceVoiceNote,
        dataBase64: base64Encode(bytes),
        localTempPath: recordedPath,
      );

      if (!await controller.waitForMeshReady()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mesh is still reconnecting. Please try again.'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final selectedConversation = ref
          .read(chatControllerProvider)
          .selectedConversation;
      if (selectedConversation is! PrivateConversation) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Voice notes are available only in private chats'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      if (!await controller.waitForPeerOnline(
        selectedConversation.peerNodeId,
      )) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Recipient is still coming online. Please try again.',
            ),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      await _sendAudioPayload(payload);
    } finally {
      controller.endForegroundCriticalAction();
    }
  }

  Future<void> _cancelVoiceRecording() async {
    if (!_isRecordingVoice) return;

    _voiceTicker?.cancel();
    _voiceTicker = null;
    _voiceStopwatch
      ..stop()
      ..reset();

    String? recordedPath;
    try {
      recordedPath = await _audioRecorder.stop();
    } catch (_) {
      recordedPath = null;
    }

    if (recordedPath != null && recordedPath.isNotEmpty) {
      try {
        final file = File(recordedPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _isRecordingVoice = false;
      _isVoiceRecordingPaused = false;
      _voiceRecordingElapsed = Duration.zero;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Voice recording discarded'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _sendAudioPayload(AudioAttachmentPayload payload) async {
    final chatState = ref.read(chatControllerProvider);
    final conv = chatState.selectedConversation;
    if (conv is! PrivateConversation) return;

    final peer = _resolvePrivatePeer(chatState, conv);

    PrivateSendResult result;
    if (peer != null) {
      _selectResolvedPeerIfNeeded(conv, peer);
      result = await ref
          .read(chatControllerProvider.notifier)
          .sendPrivateAudio(peer, payload);

      if (result == PrivateSendResult.needsPlaintextConfirmation) {
        if (!mounted) return;
        final confirmed = await _showPlaintextConfirmDialog(
          context,
          peer.displayName,
        );
        if (!mounted || !confirmed) return;
        result = await ref
            .read(chatControllerProvider.notifier)
            .sendPrivateAudio(peer, payload, allowPlaintextFallback: true);
      }
    } else {
      final contact = chatState.knownContacts.cast<KnownContact?>().firstWhere(
        (c) => c?.nodeId == conv.peerNodeId,
        orElse: () => null,
      );
      if (contact == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contact not reachable'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      result = await ref
          .read(chatControllerProvider.notifier)
          .sendPrivateAudioToContact(contact, payload);
    }

    if (!mounted) return;
    final ok =
        result == PrivateSendResult.sentEncrypted ||
        result == PrivateSendResult.sentPlaintext;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Voice note sent' : 'Failed to send voice note'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<bool?> _showBlockConfirmDialog(BuildContext context, String peerName) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block user?'),
        content: const Text(
          'You will no longer see messages or nearby updates from this user. '
          'Existing chat history stays on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
  }

  void _showReportUserDialog(
    BuildContext context,
    WidgetRef ref,
    String reportedNodeId,
    String reportedDisplayName,
  ) {
    ReportReason selectedReason = ReportReason.spam;
    final notesController = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Report $reportedDisplayName'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<ReportReason>(
                isExpanded: true,
                value: selectedReason,
                items: ReportReason.values
                    .map(
                      (r) => DropdownMenuItem(value: r, child: Text(r.label)),
                    )
                    .toList(),
                onChanged: (r) {
                  if (r != null) setState(() => selectedReason = r);
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: notesController,
                decoration: const InputDecoration(
                  labelText: 'Additional notes (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                ref
                    .read(chatControllerProvider.notifier)
                    .reportUser(
                      reportedNodeId: reportedNodeId,
                      reportedDisplayName: reportedDisplayName,
                      reason: selectedReason,
                      notes: notesController.text.trim().isEmpty
                          ? null
                          : notesController.text.trim(),
                    );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Report submitted')),
                );
              },
              child: const Text('Submit'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _showPlaintextConfirmDialog(
    BuildContext context,
    String peerName,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send without encryption?'),
        content: Text(
          'Encryption is not yet available for $peerName. '
          'This message will be sent in plaintext directly to them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Send anyway'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    // Select only the peer count for the AppBar badge — avoids full rebuild.
    final peerCount = ref.watch(
      chatControllerProvider.select((s) => s.peers.length),
    );
    final meshStarted = ref.watch(
      chatControllerProvider.select((s) => s.meshStarted),
    );
    final isMeshStarting = ref.watch(
      chatControllerProvider.select((s) => s.isMeshStarting),
    );
    final playServicesAvailable = ref.watch(
      chatControllerProvider.select((s) => s.playServicesAvailable),
    );
    final playServicesMessage = ref.watch(
      chatControllerProvider.select((s) => s.playServicesMessage),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('AirGrid'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(
              child: _PeerBadge(count: peerCount, meshOn: meshStarted),
            ),
          ),
          const PublicWalkieStatusIcon(),
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
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).pushNamed(AppRouter.settings);
              if (!mounted) return;
              await _refreshPermissionStatus();
            },
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'clear_all') {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear all chats?'),
                    content: const Text(
                      'This will permanently remove all local chat history.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ref
                      .read(chatControllerProvider.notifier)
                      .clearAllChats();
                }
              } else if (value == 'trust_contact') {
                final messenger = ScaffoldMessenger.of(context);
                final conv = ref
                    .read(chatControllerProvider)
                    .selectedConversation;
                if (conv is! PrivateConversation) return;
                await ref
                    .read(chatControllerProvider.notifier)
                    .trustContact(conv.peerNodeId);
                if (!mounted) return;
                messenger.showSnackBar(
                  const SnackBar(content: Text('Added to invited friends')),
                );
              } else if (value == 'untrust_contact') {
                final messenger = ScaffoldMessenger.of(context);
                final conv = ref
                    .read(chatControllerProvider)
                    .selectedConversation;
                if (conv is! PrivateConversation) return;
                await ref
                    .read(chatControllerProvider.notifier)
                    .untrustContact(conv.peerNodeId);
                if (!mounted) return;
                messenger.showSnackBar(
                  const SnackBar(content: Text('Removed from invited friends')),
                );
              } else if (value == 'report_user') {
                final conv = ref
                    .read(chatControllerProvider)
                    .selectedConversation;
                if (conv is! PrivateConversation || !mounted) return;
                _showReportUserDialog(
                  context,
                  ref,
                  conv.peerNodeId,
                  conv.peerName,
                );
              } else if (value == 'block_user') {
                final conv = ref
                    .read(chatControllerProvider)
                    .selectedConversation;
                if (conv is! PrivateConversation) return;
                if (!mounted) return;
                final messenger = ScaffoldMessenger.of(context);
                final confirmed = await _showBlockConfirmDialog(
                  context,
                  conv.peerName,
                );
                if (!mounted || confirmed != true) return;
                await ref
                    .read(chatControllerProvider.notifier)
                    .blockUser(conv.peerNodeId);
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('User blocked'),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } else if (value == 'view_profile') {
                final chatState = ref.read(chatControllerProvider);
                final conv = chatState.selectedConversation;
                if (conv is! PrivateConversation || !mounted) return;

                final contact = chatState.knownContacts
                    .cast<KnownContact?>()
                    .firstWhere(
                      (c) => c?.nodeId == conv.peerNodeId,
                      orElse: () => null,
                    );
                final isOnline = chatState.peers.any(
                  (p) => p.nodeId == conv.peerNodeId,
                );
                await showPeerProfileSheet(
                  context,
                  PeerProfileSnapshot(
                    displayName: conv.peerName,
                    nodeId: conv.peerNodeId,
                    profileIconId: contact?.profileIconId,
                    profileStatus: contact?.profileStatus,
                    isOnline: isOnline,
                  ),
                );
              } else if (value == 'close_chat') {
                final conv = ref
                    .read(chatControllerProvider)
                    .selectedConversation;
                if (conv is! PrivateConversation) return;
                await ref
                    .read(chatControllerProvider.notifier)
                    .closePrivateChat(conv.peerNodeId);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Chat closed. History kept.'),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              } else if (value == 'reopen_chat') {
                final conv = ref
                    .read(chatControllerProvider)
                    .selectedConversation;
                if (conv is! PrivateConversation) return;
                await ref
                    .read(chatControllerProvider.notifier)
                    .reopenPrivateChat(conv.peerNodeId);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Chat reopened'),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            itemBuilder: (_) {
              final chatState = ref.read(chatControllerProvider);
              final conv = chatState.selectedConversation;
              final isTrusted =
                  conv is PrivateConversation &&
                  chatState.trustedNodeIds.contains(conv.peerNodeId);
              final isChatClosed =
                  conv is PrivateConversation &&
                  chatState.closedChatNodeIds.contains(conv.peerNodeId);
              return [
                const PopupMenuItem(
                  value: 'clear_all',
                  child: Text('Clear all chats'),
                ),
                if (conv is PrivateConversation) ...[
                  const PopupMenuItem(
                    value: 'view_profile',
                    child: Text('View profile'),
                  ),
                  PopupMenuItem(
                    value: isChatClosed ? 'reopen_chat' : 'close_chat',
                    child: Text(isChatClosed ? 'Reopen chat' : 'Close chat'),
                  ),
                  if (isTrusted)
                    const PopupMenuItem(
                      value: 'untrust_contact',
                      child: Text('Remove from invited friends'),
                    )
                  else
                    const PopupMenuItem(
                      value: 'trust_contact',
                      child: Text('Add to invited friends'),
                    ),
                  const PopupMenuItem(
                    value: 'report_user',
                    child: Text('Report user'),
                  ),
                  const PopupMenuItem(
                    value: 'block_user',
                    child: Text('Block user'),
                  ),
                ],
              ];
            },
          ),
          IconButton(
            icon: Icon(_showStatus ? Icons.info : Icons.info_outline),
            tooltip: 'Mesh status',
            onPressed: () => setState(() => _showStatus = !_showStatus),
          ),
          if (meshStarted)
            IconButton(
              icon: const Icon(Icons.wifi),
              tooltip: 'Stop mesh',
              onPressed: () =>
                  ref.read(chatControllerProvider.notifier).stopMesh(),
            )
          else
            IconButton(
              icon: const Icon(Icons.wifi_off),
              tooltip: 'Start mesh',
              onPressed: () =>
                  ref.read(chatControllerProvider.notifier).startMesh(),
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compactHeight = media.size.height < 540;
          final meshStatusMaxHeight = media.viewInsets.bottom > 0
              ? (constraints.maxHeight * 0.22).clamp(90.0, 160.0)
              : (constraints.maxHeight * 0.30).clamp(110.0, 220.0);

          return Column(
            children: [
              if ((_permissionsSnapshot?.hasMissingCriticalPermissions ??
                      false) &&
                  !_dismissPermissionBanner)
                MaterialBanner(
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  content: const Text(
                    'Bluetooth and Wi-Fi permissions are missing. Mesh may not work until you fix them in Settings.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () async {
                        await Navigator.of(
                          context,
                        ).pushNamed(AppRouter.settings);
                        if (!mounted) return;
                        await _refreshPermissionStatus();
                      },
                      child: const Text('Open Settings'),
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => _dismissPermissionBanner = true),
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              if (!playServicesAvailable)
                _PlayServicesError(message: playServicesMessage),
              if (isMeshStarting) const _ConnectingBanner(),
              if (_showStatus)
                compactHeight
                    ? SizedBox(
                        height: meshStatusMaxHeight,
                        child: SingleChildScrollView(
                          child: const MeshStatusPanel(),
                        ),
                      )
                    : const MeshStatusPanel(),
              Expanded(
                child: _MessageList(scrollController: _scrollController),
              ),
              if (!compactHeight)
                HelpTarget(
                  title: 'Conversation Selector',
                  description:
                      'Switch between Public Chat (broadcast to all nearby) '
                      'and Private Chats (direct, encrypted messages to specific peers). '
                      'Private chats are indicated by a lock icon.',
                  child: const _ConversationPicker(),
                ),
              HelpTarget(
                title: 'Chat Input',
                description:
                    'Type a message and tap Send. '
                    'Use the attachment button (📎) to share photos or files in private chats. '
                    'Tap the microphone to record and send a voice note.',
                child: _InputBar(
                  controller: _inputController,
                  focusNode: _inputFocusNode,
                  onSend: _send,
                  onOpenAttachmentMenu: _showAttachmentMenu,
                  onToggleVoiceRecording: _handleVoiceControlTap,
                  onCancelVoiceRecording: _cancelVoiceRecording,
                  isRecordingVoice: _isRecordingVoice,
                  isVoiceRecordingPaused: _isVoiceRecordingPaused,
                  onSendVoiceRecording: _stopAndSendVoiceNote,
                  voiceRecordingElapsed: _voiceRecordingElapsed,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showAttachmentMenu() async {
    if (_isRecordingVoice) return;

    final choice = await showModalBottomSheet<_AttachmentChoice>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        final media = MediaQuery.of(context);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            20 + media.viewPadding.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Attach something',
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _AttachmentMenuTile(
                    icon: Icons.mic_rounded,
                    color: cs.error,
                    onTap: () =>
                        Navigator.pop(context, _AttachmentChoice.voice),
                  ),
                  _AttachmentMenuTile(
                    icon: Icons.photo_library_outlined,
                    color: cs.primary,
                    onTap: () =>
                        Navigator.pop(context, _AttachmentChoice.photo),
                  ),
                  _AttachmentMenuTile(
                    icon: Icons.attach_file_rounded,
                    color: cs.tertiary,
                    onTap: () => Navigator.pop(context, _AttachmentChoice.file),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    if (!mounted || choice == null) {
      await _restoreFocus();
      return;
    }

    switch (choice) {
      case _AttachmentChoice.voice:
        await _handleVoiceControlTap();
        break;
      case _AttachmentChoice.photo:
        await _pickAndSendImage();
        break;
      case _AttachmentChoice.file:
        await _pickAndSendFile();
        break;
    }
    
    await _restoreFocus();
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

enum _AttachmentChoice { voice, photo, file }

class _AttachmentMenuTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _AttachmentMenuTile({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 56,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: color.withAlpha(24),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 28),
      ),
    );
  }
}

class _PeerBadge extends StatelessWidget {
  final int count;
  final bool meshOn;

  const _PeerBadge({required this.count, required this.meshOn});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const onlineIconColor = Color(0xFF16A34A);
    final color = meshOn ? onlineIconColor : cs.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        border: Border.all(color: color.withAlpha(100)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(meshOn ? Icons.hub : Icons.hub_outlined, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageList extends ConsumerWidget {
  final ScrollController scrollController;

  const _MessageList({required this.scrollController});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only subscribe to the filtered messages slice of state.
    final messages = ref.watch(
      chatControllerProvider.select((s) => s.filteredMessages),
    );

    if (messages.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  color: cs.primary.withAlpha(20),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.forum_outlined, size: 42, color: cs.primary),
              ),
              const SizedBox(height: 18),
              Text(
                'No messages yet',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Connect to peers nearby and start chatting securely without internet over an offline radio mesh!',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.outline,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      reverse: true,
      itemCount: messages.length,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemBuilder: (context, index) {
        return MessageBubble(
          key: ValueKey(messages[index].id),
          message: messages[index],
        );
      },
    );
  }
}

// ── Conversation picker ──────────────────────────────────────────────────────

class _ConversationPicker extends ConsumerWidget {
  const _ConversationPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(
      chatControllerProvider.select((s) => s.selectedConversation),
    );
    final peers = ref.watch(chatControllerProvider.select((s) => s.peers));
    final messages = ref.watch(
      chatControllerProvider.select((s) => s.messages),
    );
    final knownContacts = ref.watch(
      chatControllerProvider.select((s) => s.knownContacts),
    );
    final unreadPrivateCounts = ref.watch(
      chatControllerProvider.select((s) => s.unreadPrivateCounts),
    );
    final blockedNodeIds = ref.watch(
      chatControllerProvider.select((s) => s.blockedNodeIds),
    );
    final closedNodeIds = ref.watch(
      chatControllerProvider.select((s) => s.closedChatNodeIds),
    );
    final showOnlineOnly = ref.watch(
      chatControllerProvider.select((s) => s.showOnlineOnly),
    );
    final showClosedChats = ref.watch(
      chatControllerProvider.select((s) => s.showClosedChats),
    );
    final showFriendsOnly = ref.watch(
      chatControllerProvider.select((s) => s.showFriendsOnly),
    );
    final trustedNodeIds = ref.watch(
      chatControllerProvider.select((s) => s.trustedNodeIds),
    );
    final cs = Theme.of(context).colorScheme;
    final privateThreads = _privateThreadsFrom(
      peers,
      messages,
      knownContacts,
      blockedNodeIds,
      closedNodeIds,
      trustedNodeIds,
      showOnlineOnly,
      showClosedChats,
      showFriendsOnly,
    );
    final activeFilterCount =
        (showOnlineOnly ? 1 : 0) +
        (showClosedChats ? 1 : 0) +
        (showFriendsOnly ? 1 : 0);

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: cs.outlineVariant.withAlpha(80)),
          bottom: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          PopupMenuButton<String>(
            tooltip: 'Filter chats',
            onSelected: (value) {
              final controller = ref.read(chatControllerProvider.notifier);
              if (value == 'online') {
                controller.setShowOnlineOnly(!showOnlineOnly);
              } else if (value == 'friends') {
                controller.setShowFriendsOnly(!showFriendsOnly);
              } else if (value == 'closed') {
                controller.setShowClosedChats(!showClosedChats);
              } else if (value == 'clear') {
                controller
                  ..setShowOnlineOnly(false)
                  ..setShowFriendsOnly(false)
                  ..setShowClosedChats(false);
              }
            },
            itemBuilder: (context) => [
              _filterMenuItem(
                value: 'online',
                label: 'Online',
                icon: Icons.radio_button_checked_rounded,
                selected: showOnlineOnly,
              ),
              _filterMenuItem(
                value: 'friends',
                label: 'Friends',
                icon: Icons.verified_user_outlined,
                selected: showFriendsOnly,
              ),
              _filterMenuItem(
                value: 'closed',
                label: 'Closed chats',
                icon: Icons.archive_outlined,
                selected: showClosedChats,
              ),
              if (activeFilterCount > 0) const PopupMenuDivider(),
              if (activeFilterCount > 0)
                const PopupMenuItem(
                  value: 'clear',
                  child: Row(
                    children: [
                      Icon(Icons.filter_alt_off_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('Clear filters'),
                    ],
                  ),
                ),
            ],
            child: _FilterMenuButton(activeCount: activeFilterCount),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    avatar: Icon(
                      Icons.public_rounded,
                      size: 16,
                      color: selected is PublicConversation
                          ? cs.onPrimary
                          : cs.primary,
                    ),
                    label: const Text('Public Space'),
                    selected: selected is PublicConversation,
                    showCheckmark: false,
                    onSelected: (_) => ref
                        .read(chatControllerProvider.notifier)
                        .selectConversation(const PublicConversation()),
                  ),
                  const SizedBox(width: 8),
                  ...privateThreads.map((thread) {
                    final isReady = thread.peerNodeId != null;
                    final peerNodeId = thread.peerNodeId;
                    final label = thread.displayName;
                    final conv = selected;
                    final isSelected =
                        conv is PrivateConversation &&
                        conv.peerNodeId == peerNodeId;
                    final unreadCount = peerNodeId == null
                        ? 0
                        : unreadPrivateCounts[peerNodeId] ?? 0;

                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onLongPress: isReady
                            ? () {
                                showPeerProfileSheet(
                                  context,
                                  PeerProfileSnapshot(
                                    displayName: thread.displayName,
                                    nodeId: peerNodeId!,
                                    profileIconId: thread.profileIconId,
                                    profileStatus: thread.profileStatus,
                                    isOnline: thread.isConnected,
                                  ),
                                );
                              }
                            : null,
                        child: ChoiceChip(
                          avatar: isReady
                              ? Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: thread.isConnected
                                        ? Colors.green
                                        : cs.outline.withAlpha(150),
                                    shape: BoxShape.circle,
                                    boxShadow: thread.isConnected
                                        ? [
                                            BoxShadow(
                                              color: Colors.green.withAlpha(
                                                120,
                                              ),
                                              blurRadius: 4,
                                              spreadRadius: 1,
                                            ),
                                          ]
                                        : null,
                                  ),
                                )
                              : const SizedBox(
                                  width: 10,
                                  height: 10,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    valueColor: AlwaysStoppedAnimation(
                                      Colors.orange,
                                    ),
                                  ),
                                ),
                          label: _ConversationChipLabel(
                            label: isReady ? label : '$label (setting up)',
                            unreadCount: isSelected ? 0 : unreadCount,
                            isClosed: thread.isClosed,
                          ),
                          selected: isSelected,
                          showCheckmark: false,
                          onSelected: isReady
                              ? (_) => ref
                                    .read(chatControllerProvider.notifier)
                                    .selectConversation(
                                      PrivateConversation(
                                        peerNodeId: peerNodeId!,
                                        peerName: thread.displayName,
                                      ),
                                    )
                              : null,
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Input bar ────────────────────────────────────────────────────────────────

class _FilterMenuButton extends StatelessWidget {
  final int activeCount;

  const _FilterMenuButton({required this.activeCount});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isActive = activeCount > 0;

    return SizedBox(
      width: 42,
      height: 42,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: isActive
                  ? cs.primaryContainer
                  : cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.tune_rounded,
              color: isActive ? cs.onPrimaryContainer : cs.onSurfaceVariant,
            ),
          ),
          if (isActive)
            Positioned(
              top: 2,
              right: 2,
              child: Container(
                constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: cs.error,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '$activeCount',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cs.onError,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

PopupMenuItem<String> _filterMenuItem({
  required String value,
  required String label,
  required IconData icon,
  required bool selected,
}) {
  return PopupMenuItem(
    value: value,
    child: Row(
      children: [
        Icon(selected ? Icons.check_circle_rounded : icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    ),
  );
}

List<_PrivateThreadTarget> _privateThreadsFrom(
  List<MeshPeer> peers,
  List<AirGridMessage> messages,
  List<KnownContact> knownContacts,
  Set<String> blockedNodeIds,
  Set<String> closedNodeIds,
  Set<String> trustedNodeIds,
  bool showOnlineOnly,
  bool showClosedChats,
  bool showFriendsOnly,
) {
  final threads = <String, _PrivateThreadTarget>{};
  final pendingPeers = <_PrivateThreadTarget>[];

  // Known contacts are the canonical source. Mark them connected if they have
  // a live direct endpoint.
  final connectedNodeIds = peers
      .map((p) => p.nodeId)
      .whereType<String>()
      .toSet();

  for (final contact in knownContacts) {
    if (contact.isBlocked) continue;
    threads[contact.nodeId] = _PrivateThreadTarget(
      peerNodeId: contact.nodeId,
      displayName: contact.displayName,
      isConnected: connectedNodeIds.contains(contact.nodeId),
      isClosed: contact.isChatClosed,
      isTrusted: contact.isTrusted,
      profileIconId: contact.profileIconId,
      profileStatus: contact.profileStatus,
    );
  }

  // Add live peers not yet in knownContacts (identity not yet announced).
  for (final peer in peers) {
    final nodeId = peer.nodeId;
    if (nodeId != null && blockedNodeIds.contains(nodeId)) continue;
    if (nodeId == null) {
      pendingPeers.add(
        _PrivateThreadTarget(
          peerNodeId: null,
          displayName: peer.displayName,
          isConnected: true,
          isClosed: false,
          isTrusted: false,
        ),
      );
    } else if (!threads.containsKey(nodeId)) {
      threads[nodeId] = _PrivateThreadTarget(
        peerNodeId: nodeId,
        displayName: peer.displayName,
        isConnected: true,
        isClosed: closedNodeIds.contains(nodeId),
        isTrusted: trustedNodeIds.contains(nodeId),
      );
    }
  }

  // Add historical threads from messages not already covered above.
  for (final msg in messages) {
    if (msg.conversationType != 'private') continue;
    if (msg.content == '[walkie]') continue;
    final peerNodeId = msg.peerNodeId;
    if (peerNodeId == null || peerNodeId.isEmpty) continue;
    if (blockedNodeIds.contains(peerNodeId)) continue;
    if (threads.containsKey(peerNodeId)) continue;
    final displayName = msg.peerName ?? msg.senderName;
    threads[peerNodeId] = _PrivateThreadTarget(
      peerNodeId: peerNodeId,
      displayName: displayName,
      isConnected: false,
      isClosed: closedNodeIds.contains(peerNodeId),
      isTrusted: trustedNodeIds.contains(peerNodeId),
    );
  }

  final hasActiveFilter = showOnlineOnly || showClosedChats || showFriendsOnly;

  final visibleThreads = threads.values.where((t) {
    // Default view: hide closed chats unless a filter is active.
    if (!hasActiveFilter) {
      return !t.isClosed;
    }

    final matchesOnline = showOnlineOnly && t.isConnected && t.isTrusted;
    final matchesClosed = showClosedChats && t.isClosed;
    final matchesFriends = showFriendsOnly && t.isTrusted && !t.isClosed;
    return matchesOnline || matchesClosed || matchesFriends;
  }).toList();

  // Pending peers are shown only in the default open-chat view.
  final visiblePendingPeers = hasActiveFilter
      ? const <_PrivateThreadTarget>[]
      : pendingPeers;
  return [...visibleThreads, ...visiblePendingPeers];
}

class _PrivateThreadTarget {
  final String? peerNodeId;
  final String displayName;
  final bool isConnected;
  final bool isClosed;
  final bool isTrusted;
  final String? profileIconId;
  final String? profileStatus;

  const _PrivateThreadTarget({
    required this.peerNodeId,
    required this.displayName,
    required this.isConnected,
    required this.isClosed,
    required this.isTrusted,
    this.profileIconId,
    this.profileStatus,
  });
}

class _ConversationChipLabel extends StatelessWidget {
  final String label;
  final int unreadCount;
  final bool isClosed;

  const _ConversationChipLabel({
    required this.label,
    required this.unreadCount,
    required this.isClosed,
  });

  @override
  Widget build(BuildContext context) {
    if (unreadCount <= 0 && !isClosed) {
      return Text(label);
    }

    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (isClosed) ...[
          const SizedBox(width: 6),
          Text(
            'Closed',
            style: TextStyle(
              color: cs.outline,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (unreadCount > 0) ...[
          const SizedBox(width: 6),
          Container(
            constraints: const BoxConstraints(minWidth: 18),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
            decoration: BoxDecoration(
              color: cs.error,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              unreadCount > 99 ? '99+' : '$unreadCount',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onError,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onOpenAttachmentMenu;
  final VoidCallback onToggleVoiceRecording;
  final VoidCallback onCancelVoiceRecording;
  final bool isRecordingVoice;
  final bool isVoiceRecordingPaused;
  final VoidCallback onSendVoiceRecording;
  final Duration voiceRecordingElapsed;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onOpenAttachmentMenu,
    required this.onToggleVoiceRecording,
    required this.onCancelVoiceRecording,
    required this.isRecordingVoice,
    required this.isVoiceRecordingPaused,
    required this.onSendVoiceRecording,
    required this.voiceRecordingElapsed,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      color: cs.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: !isRecordingVoice
                  ? const SizedBox.shrink()
                  : Container(
                      key: const ValueKey('recording-chip'),
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.fiber_manual_record_rounded,
                            color: cs.error,
                            size: 14,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${isVoiceRecordingPaused ? "Paused" : "Recording"} ${_formatVoiceDuration(voiceRecordingElapsed)}',
                              style: TextStyle(
                                color: cs.onErrorContainer,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Text(
                            isVoiceRecordingPaused
                                ? 'Tap mic to continue'
                                : 'Tap mic to pause',
                            style: TextStyle(
                              color: cs.onErrorContainer.withAlpha(200),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            Row(
              children: [
                if (isRecordingVoice)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: onCancelVoiceRecording,
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Discard recording',
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        onPressed: onToggleVoiceRecording,
                        icon: Icon(
                          isVoiceRecordingPaused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                        ),
                        tooltip: isVoiceRecordingPaused
                            ? 'Resume recording'
                            : 'Pause recording',
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  )
                else
                  const SizedBox(width: 2),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Icon(
                          isRecordingVoice
                              ? Icons.mic_rounded
                              : Icons.chat_bubble_outline_rounded,
                          size: 20,
                          color: isRecordingVoice
                              ? cs.error
                              : cs.onSurfaceVariant.withAlpha(150),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: controller,
                            focusNode: focusNode,
                            readOnly: isRecordingVoice,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) {
                              if (isRecordingVoice) {
                                return;
                              }
                              if (controller.text.trim().isNotEmpty) {
                                onSend();
                              } else {
                                onOpenAttachmentMenu();
                              }
                            },
                            decoration: InputDecoration(
                              hintText: isRecordingVoice
                                  ? isVoiceRecordingPaused
                                        ? 'Recording paused… tap play to continue'
                                        : 'Recording in progress…'
                                  : 'Type a message…',
                              border: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final hasText =
                        !isRecordingVoice && value.text.trim().isNotEmpty;
                    final hasVoiceDraft = isRecordingVoice;
                    final active =
                        hasText || hasVoiceDraft || !isRecordingVoice;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      decoration: BoxDecoration(
                        color: active ? cs.primary : cs.surfaceContainerHigh,
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        onPressed: hasVoiceDraft
                            ? onSendVoiceRecording
                            : hasText
                            ? onSend
                            : onOpenAttachmentMenu,
                        icon: Icon(
                          hasVoiceDraft || hasText
                              ? Icons.send_rounded
                              : Icons.attach_file_rounded,
                          color: active
                              ? cs.onPrimary
                              : cs.onSurfaceVariant.withAlpha(100),
                        ),
                        tooltip: hasVoiceDraft
                            ? 'Send voice note'
                            : hasText
                            ? 'Send'
                            : 'Attach',
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatVoiceDuration(Duration duration) {
  final minutes = duration.inMinutes.toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String _formatBytes(int byteLength) {
  const kb = 1024;
  const mb = kb * 1024;
  if (byteLength >= mb) {
    return '${(byteLength / mb).toStringAsFixed(1)} MB';
  }
  if (byteLength >= kb) {
    return '${(byteLength / kb).toStringAsFixed(1)} KB';
  }
  return '$byteLength B';
}

String _formatDuration(Duration duration) {
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
  }
  return '${duration.inSeconds}s';
}

class _ConnectingBanner extends StatelessWidget {
  const _ConnectingBanner();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.tertiaryContainer.withAlpha(130),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.tertiary.withAlpha(100)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(cs.tertiary),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Reconnecting to mesh. You can keep chatting.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayServicesError extends StatelessWidget {
  final String message;

  const _PlayServicesError({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: cs.errorContainer,
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
      ),
    );
  }
}
