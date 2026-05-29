import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:airgrid/app/app_router.dart';
import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/ephemeral_media_cache.dart';
import 'package:airgrid/core/mesh_permissions.dart';
import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/known_contact.dart';
import 'package:airgrid/domain/models/local_report.dart';
import 'package:airgrid/domain/models/media_attachment.dart';
import 'package:airgrid/domain/models/mesh_peer.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:airgrid/features/chat/conversation_target.dart';
import 'package:airgrid/features/chat/message_bubble.dart';
import 'package:airgrid/features/mesh_status/mesh_status_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
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
  final _imagePicker = ImagePicker();
  final _mediaCache = EphemeralMediaCache();
  bool _showStatus = false;
  bool _dismissPermissionBanner = false;
  MeshPermissionsSnapshot? _permissionsSnapshot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(chatControllerProvider.notifier).startMesh();
    });
    _refreshPermissionStatus();
    unawaited(_mediaCache.cleanup());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inputController.dispose();
    _scrollController.dispose();
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
      final peers = chatState.peers;
      final peer = peers.cast<MeshPeer?>().firstWhere(
        (p) => p?.nodeId == conv.peerNodeId,
        orElse: () => null,
      );

      if (peer != null) {
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
        const SnackBar(
          content: Text('Photo is too large. Try a smaller image.'),
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
      ref.read(chatControllerProvider).selectedConversation is PrivateConversation
          ? (ref.read(chatControllerProvider).selectedConversation
              as PrivateConversation)
              .peerNodeId
          : '',
    )) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recipient is still coming online. Please try again.'),
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

  Future<void> _sendImagePayload(ImageAttachmentPayload payload) async {
    final chatState = ref.read(chatControllerProvider);
    final conv = chatState.selectedConversation;
    if (conv is! PrivateConversation) return;

    final peers = chatState.peers;
    final peer = peers.cast<MeshPeer?>().firstWhere(
      (p) => p?.nodeId == conv.peerNodeId,
      orElse: () => null,
    );

    PrivateSendResult result;
    if (peer != null) {
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
            .sendPrivateImage(
              peer,
              payload,
              allowPlaintextFallback: true,
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
              }
            },
            itemBuilder: (_) {
              final chatState = ref.read(chatControllerProvider);
              final conv = chatState.selectedConversation;
              final isTrusted =
                  conv is PrivateConversation &&
                  chatState.trustedNodeIds.contains(conv.peerNodeId);
              return [
                const PopupMenuItem(
                  value: 'clear_all',
                  child: Text('Clear all chats'),
                ),
                if (conv is PrivateConversation) ...[
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
          final compactHeight = constraints.maxHeight < 540;
          final meshStatusMaxHeight = media.viewInsets.bottom > 0
              ? (constraints.maxHeight * 0.22).clamp(90.0, 160.0)
              : (constraints.maxHeight * 0.30).clamp(110.0, 220.0);

          return Column(
            children: [
              if ((_permissionsSnapshot?.hasMissingCriticalPermissions ?? false) &&
                  !_dismissPermissionBanner)
                MaterialBanner(
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  content: const Text(
                    'Bluetooth and Wi-Fi permissions are missing. Mesh may not work until you fix them in Settings.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () async {
                        await Navigator.of(context).pushNamed(AppRouter.settings);
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
              Expanded(child: _MessageList(scrollController: _scrollController)),
              if (!compactHeight) const _ConversationPicker(),
              _InputBar(
                controller: _inputController,
                onSend: _send,
                onPickImage: _pickAndSendImage,
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

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
    final cs = Theme.of(context).colorScheme;
    final privateThreads = _privateThreadsFrom(
      peers,
      messages,
      knownContacts,
      blockedNodeIds,
    );

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: cs.outlineVariant.withAlpha(80)),
          bottom: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  conv is PrivateConversation && conv.peerNodeId == peerNodeId;
              final unreadCount = peerNodeId == null
                  ? 0
                  : unreadPrivateCounts[peerNodeId] ?? 0;

              return Padding(
                padding: const EdgeInsets.only(right: 8),
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
                                      color: Colors.green.withAlpha(120),
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
                            valueColor: AlwaysStoppedAnimation(Colors.orange),
                          ),
                        ),
                  label: _ConversationChipLabel(
                    label: isReady ? label : '$label (setting up)',
                    unreadCount: isSelected ? 0 : unreadCount,
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
              );
            }),
          ],
        ),
      ),
    );
  }
}

// ── Input bar ────────────────────────────────────────────────────────────────

List<_PrivateThreadTarget> _privateThreadsFrom(
  List<MeshPeer> peers,
  List<AirGridMessage> messages,
  List<KnownContact> knownContacts,
  Set<String> blockedNodeIds,
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
        ),
      );
    } else if (!threads.containsKey(nodeId)) {
      threads[nodeId] = _PrivateThreadTarget(
        peerNodeId: nodeId,
        displayName: peer.displayName,
        isConnected: true,
      );
    }
  }

  // Add historical threads from messages not already covered above.
  for (final msg in messages) {
    if (msg.conversationType != 'private') continue;
    final peerNodeId = msg.peerNodeId;
    if (peerNodeId == null || peerNodeId.isEmpty) continue;
    if (blockedNodeIds.contains(peerNodeId)) continue;
    if (threads.containsKey(peerNodeId)) continue;
    final displayName = msg.peerName ?? msg.senderName;
    threads[peerNodeId] = _PrivateThreadTarget(
      peerNodeId: peerNodeId,
      displayName: displayName,
      isConnected: false,
    );
  }

  return [...threads.values, ...pendingPeers];
}

class _PrivateThreadTarget {
  final String? peerNodeId;
  final String displayName;
  final bool isConnected;

  const _PrivateThreadTarget({
    required this.peerNodeId,
    required this.displayName,
    required this.isConnected,
  });
}

class _ConversationChipLabel extends StatelessWidget {
  final String label;
  final int unreadCount;

  const _ConversationChipLabel({
    required this.label,
    required this.unreadCount,
  });

  @override
  Widget build(BuildContext context) {
    if (unreadCount <= 0) {
      return Text(label);
    }

    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
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
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onPickImage;

  const _InputBar({
    required this.controller,
    required this.onSend,
    required this.onPickImage,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      color: cs.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(
              onPressed: onPickImage,
              icon: const Icon(Icons.photo_library_outlined),
              tooltip: 'Send photo',
            ),
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
                      Icons.chat_bubble_outline_rounded,
                      size: 20,
                      color: cs.onSurfaceVariant.withAlpha(150),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => onSend(),
                        decoration: const InputDecoration(
                          hintText: 'Type a message…',
                          border: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 12),
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
                final hasText = value.text.trim().isNotEmpty;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    color: hasText ? cs.primary : cs.surfaceContainerHigh,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    onPressed: hasText ? onSend : null,
                    icon: Icon(
                      Icons.send_rounded,
                      color: hasText
                          ? cs.onPrimary
                          : cs.onSurfaceVariant.withAlpha(100),
                    ),
                    tooltip: 'Send',
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectingBanner extends StatelessWidget {
  const _ConnectingBanner();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.surface,
      child: Column(
        children: [
          LinearProgressIndicator(
            backgroundColor: Colors.amber.shade100,
            color: Colors.amber.shade600,
            minHeight: 2.5,
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
            color: Colors.amber.withAlpha(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.sync_rounded,
                  size: 14,
                  color: Colors.amber.shade800,
                ),
                const SizedBox(width: 6),
                Text(
                  'Connecting to mesh…',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.amber.shade900,
                  ),
                ),
              ],
            ),
          ),
        ],
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
