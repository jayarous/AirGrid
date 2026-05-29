import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:airgrid/domain/models/airgrid_message.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:airgrid/domain/models/local_report.dart';
import 'package:airgrid/domain/services/mesh_service.dart';
import 'package:airgrid/features/chat/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

class MessageBubble extends ConsumerWidget {
  final AirGridMessage message;

  const MessageBubble({super.key, required this.message});

  Color _getSenderColor(String name) {
    if (name.isEmpty) return Colors.grey;
    final hash = name.codeUnits.fold(0, (prev, elem) => prev + elem);
    const colors = [
      Color(0xFFE53935), // Red
      Color(0xFFD81B60), // Pink
      Color(0xFF8E24AA), // Purple
      Color(0xFF5E35B1), // Deep Purple
      Color(0xFF3949AB), // Indigo
      Color(0xFF1E88E5), // Blue
      Color(0xFF00ACC1), // Cyan
      Color(0xFF00897B), // Teal
      Color(0xFF43A047), // Green
      Color(0xFF7CB342), // Light Green
      Color(0xFFF4511E), // Orange
    ];
    return colors[hash % colors.length];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final isLocal = message.isLocal;
    final isMedia =
      message.messageKind == 'image' ||
      message.messageKind == 'audio' ||
      message.messageKind == 'file';

    final bubbleColor = isLocal
        ? cs.primaryContainer
        : cs.surfaceContainerHigh;
    final textColor = isLocal ? cs.onPrimaryContainer : cs.onSurface;
    final h = message.timestamp.hour.toString().padLeft(2, '0');
    final m = message.timestamp.minute.toString().padLeft(2, '0');
    final timeStr = '$h:$m';

    return GestureDetector(
      onLongPress: isLocal
          ? null
          : () => _showModerationSheet(context, ref),
      child: Align(
      alignment: isLocal ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 13),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isLocal ? 18 : 4),
              bottomRight: Radius.circular(isLocal ? 4 : 18),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(8),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isLocal)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    message.senderName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _getSenderColor(message.senderName),
                    ),
                  ),
                ),
              if (isMedia)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.messageKind == 'image')
                      _ImageMessageContent(
                        message: message,
                        textColor: textColor,
                      )
                    else if (message.messageKind == 'audio')
                      _AudioMessageContent(
                        message: message,
                        textColor: textColor,
                        isLocal: isLocal,
                      )
                    else
                      _FileMessageContent(
                        message: message,
                        textColor: textColor,
                        isLocal: isLocal,
                      ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (message.isEncrypted &&
                              message.conversationType == 'private')
                            Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Icon(
                                Icons.lock,
                                size: 11,
                                color: textColor.withAlpha(140),
                              ),
                            ),
                          Text(
                            timeStr,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: textColor.withAlpha(140),
                            ),
                          ),
                          if (message.isLocal &&
                              message.conversationType == 'private')
                            Padding(
                              padding: const EdgeInsets.only(left: 3),
                              child: _statusIcon(context, message.deliveryStatus),
                            ),
                        ],
                      ),
                    ),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        message.content,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 15,
                          height: 1.25,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (message.isEncrypted &&
                              message.conversationType == 'private')
                            Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Icon(
                                Icons.lock,
                                size: 11,
                                color: textColor.withAlpha(140),
                              ),
                            ),
                          Text(
                            timeStr,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: textColor.withAlpha(140),
                            ),
                          ),
                          if (message.isLocal &&
                              message.conversationType == 'private')
                            Padding(
                              padding: const EdgeInsets.only(left: 3),
                              child: _statusIcon(context, message.deliveryStatus),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              if (message.isLocal &&
                  message.conversationType == 'private' &&
                  message.messageKind == 'image' &&
                  message.deliveryStatus != DeliveryStatus.delivered &&
                  message.deliveryStatus != DeliveryStatus.read)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => _retryImage(context, ref),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: cs.error,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 14),
                      label: Text(
                        message.deliveryStatus == DeliveryStatus.failed
                            ? 'Retry'
                            : 'Resend',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Future<void> _retryImage(BuildContext context, WidgetRef ref) async {
    final result = await ref
        .read(chatControllerProvider.notifier)
      .retryImageMessage(message);

    if (!context.mounted) return;

    if (result == PrivateSendResult.failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not retry photo. Please try again.'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (result == PrivateSendResult.peerUnavailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recipient is still offline.'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (result == PrivateSendResult.needsPlaintextConfirmation) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Retry needs confirmation for plaintext send.'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showModerationSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report message'),
              onTap: () {
                Navigator.pop(context);
                _showReportDialog(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Hide message'),
              onTap: () {
                Navigator.pop(context);
                ref
                    .read(chatControllerProvider.notifier)
                    .hideMessage(message.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showReportDialog(BuildContext context, WidgetRef ref) {
    ReportReason selectedReason = ReportReason.spam;
    final notesController = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Report message'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<ReportReason>(
                isExpanded: true,
                value: selectedReason,
                items: ReportReason.values
                    .map(
                      (r) => DropdownMenuItem(
                        value: r,
                        child: Text(r.label),
                      ),
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
                ref.read(chatControllerProvider.notifier).reportMessage(
                      message: message,
                      reason: selectedReason,
                      notes: notesController.text.trim().isEmpty
                          ? null
                          : notesController.text.trim(),
                    );
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
  Widget _statusIcon(BuildContext context, DeliveryStatus status) {
    final cs = Theme.of(context).colorScheme;
    final dimColor = cs.onPrimaryContainer.withAlpha(140);
    switch (status) {
      case DeliveryStatus.pending:
        return Icon(Icons.access_time_rounded, size: 12, color: dimColor);
      case DeliveryStatus.sent:
        return Icon(Icons.done_rounded, size: 12, color: dimColor);
      case DeliveryStatus.delivered:
        return Icon(Icons.done_all_rounded, size: 12, color: dimColor);
      case DeliveryStatus.read:
        return Icon(Icons.done_all_rounded, size: 12, color: cs.primary);
      case DeliveryStatus.failed:
        return Icon(Icons.error_outline_rounded, size: 12, color: cs.error);
    }
  }
}

class _ImageMessageContent extends StatelessWidget {
  final AirGridMessage message;
  final Color textColor;

  const _ImageMessageContent({required this.message, required this.textColor});

  @override
  Widget build(BuildContext context) {
    final path = message.mediaTempPath;
    final hasFile = path != null && File(path).existsSync();
    final previewB64 = message.mediaPreviewBase64;

    if (!hasFile && (previewB64 == null || previewB64.isEmpty)) {
      return Container(
        width: 180,
        height: 120,
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(
          'Photo unavailable',
          style: TextStyle(color: textColor, fontSize: 12),
        ),
      );
    }

    if (!hasFile && previewB64 != null && previewB64.isNotEmpty) {
      final bytes = base64Decode(previewB64);
      return _ZoomableImageThumbnail.memory(
        bytes: bytes,
        heroTag: 'chat-image-${message.id}',
      );
    }

    return _ZoomableImageThumbnail.file(
      file: File(path!),
      heroTag: 'chat-image-${message.id}',
    );
  }
}

class _AudioMessageContent extends StatefulWidget {
  final AirGridMessage message;
  final Color textColor;
  final bool isLocal;

  const _AudioMessageContent({
    required this.message,
    required this.textColor,
    required this.isLocal,
  });

  @override
  State<_AudioMessageContent> createState() => _AudioMessageContentState();
}

class _AudioMessageContentState extends State<_AudioMessageContent> {
  final AudioPlayer _player = AudioPlayer();
  String? _loadedPath;
  bool _loading = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _ensureLoaded();
  }

  @override
  void didUpdateWidget(covariant _AudioMessageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message.mediaTempPath != oldWidget.message.mediaTempPath) {
      _ensureLoaded();
    }
  }

  Future<void> _ensureLoaded() async {
    final path = widget.message.mediaTempPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      if (!mounted) return;
      setState(() {
        _loadedPath = null;
        _loading = false;
        _loadFailed = true;
      });
      return;
    }

    if (_loadedPath == path && !_loadFailed) {
      return;
    }

    setState(() {
      _loading = true;
      _loadFailed = false;
    });

    try {
      await _player.setFilePath(path);
      if (!mounted) return;
      setState(() {
        _loadedPath = path;
        _loading = false;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadedPath = null;
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _togglePlayback() async {
    if (_loading || _loadFailed || _loadedPath == null) return;
    final state = _player.playerState;
    if (state.playing) {
      await _player.pause();
      return;
    }
    if (state.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    await _player.play();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loadFailed) {
      return Container(
        width: 190,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'Voice note unavailable',
          style: TextStyle(color: widget.textColor, fontSize: 12),
        ),
      );
    }

    return Container(
      width: 190,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: widget.isLocal
            ? Colors.white.withAlpha(140)
            : cs.surfaceContainerHighest.withAlpha(165),
        borderRadius: BorderRadius.circular(12),
      ),
      child: StreamBuilder<PlayerState>(
        stream: _player.playerStateStream,
        initialData: _player.playerState,
        builder: (context, stateSnapshot) {
          final playerState = stateSnapshot.data ?? _player.playerState;
          final isPlaying = playerState.playing;

          return StreamBuilder<Duration>(
            stream: _player.positionStream,
            initialData: Duration.zero,
            builder: (context, positionSnapshot) {
              final position = positionSnapshot.data ?? Duration.zero;
              final duration =
                  _player.duration ??
                  Duration(milliseconds: widget.message.mediaDurationMs ?? 0);
              final safeDuration = duration > Duration.zero
                  ? duration
                  : const Duration(seconds: 1);
              final progress =
                  (position.inMilliseconds / safeDuration.inMilliseconds)
                      .clamp(0.0, 1.0);

              return Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: _loading ? null : _togglePlayback,
                    icon: Icon(
                      _loading
                          ? Icons.hourglass_top_rounded
                          : isPlaying
                          ? Icons.pause_circle_filled_rounded
                          : Icons.play_circle_fill_rounded,
                      size: 28,
                      color: widget.textColor,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Voice note',
                          style: TextStyle(
                            color: widget.textColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 4,
                            backgroundColor: widget.textColor.withAlpha(50),
                            color: widget.textColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_formatAudioDuration(position)} / ${_formatAudioDuration(duration)}',
                          style: TextStyle(
                            color: widget.textColor.withAlpha(180),
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  String _formatAudioDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _FileMessageContent extends StatelessWidget {
  final AirGridMessage message;
  final Color textColor;
  final bool isLocal;

  const _FileMessageContent({
    required this.message,
    required this.textColor,
    required this.isLocal,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fileName = _displayFileName();
    final sizeLabel = _formatFileSize(message.mediaByteLength ?? 0);
    final progress = message.mediaTransferProgress;
    final isSending = isLocal &&
      progress != null &&
      progress > 0 &&
      progress < 1 &&
      message.deliveryStatus == DeliveryStatus.pending;

    return GestureDetector(
      onTap: () => _openFileAttachment(context),
      child: Container(
        width: 220,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isLocal
              ? Colors.white.withAlpha(140)
              : cs.surfaceContainerHighest.withAlpha(165),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              color: textColor,
              size: 28,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sizeLabel,
                    style: TextStyle(
                      color: textColor.withAlpha(180),
                      fontSize: 11,
                    ),
                  ),
                  if (message.mediaMimeType != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      message.mediaMimeType!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textColor.withAlpha(160),
                        fontSize: 10,
                      ),
                    ),
                  ],
                  if (isSending) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                        backgroundColor: textColor.withAlpha(50),
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Sending ${(progress * 100).round()}%',
                      style: TextStyle(
                        color: textColor.withAlpha(160),
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 6),
                    Text(
                      'Tap to open',
                      style: TextStyle(
                        color: textColor.withAlpha(180),
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFileAttachment(BuildContext context) async {
    final path = message.mediaTempPath;
    if (path == null || path.isEmpty) {
      _showFileSnackBar(context, 'File is unavailable on this device.');
      return;
    }

    final file = File(path);
    if (!file.existsSync()) {
      _showFileSnackBar(context, 'File is no longer available.');
      return;
    }

    try {
      final mimeType = message.mediaMimeType;
      final resolvedType =
          mimeType != null &&
              mimeType.isNotEmpty &&
              mimeType != 'application/octet-stream'
          ? mimeType
          : null;
      final result = await OpenFilex.open(path, type: resolvedType);
      if (!context.mounted) return;
      switch (result.type) {
        case ResultType.done:
          return;
        case ResultType.noAppToOpen:
          _showFileSnackBar(context, 'No app found to open this file.');
          return;
        case ResultType.fileNotFound:
          _showFileSnackBar(context, 'File is no longer available.');
          return;
        default:
          _showFileSnackBar(context, 'Could not open this file.');
      }
    } catch (_) {
      if (!context.mounted) return;
      _showFileSnackBar(context, 'Could not open this file.');
    }
  }

  void _showFileSnackBar(BuildContext context, String messageText) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(messageText),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _displayFileName() {
    final path = message.mediaTempPath;
    if (path == null || path.isEmpty) {
      return 'File';
    }

    final base = p.basename(path);
    final transferId = message.mediaTransferId;
    if (transferId != null && base.startsWith('${transferId}_')) {
      return base.substring(transferId.length + 1);
    }
    return base;
  }

  String _formatFileSize(int byteLength) {
    if (byteLength <= 0) return 'Unknown size';
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
}

class _ZoomableImageThumbnail extends StatelessWidget {
  final File? file;
  final Uint8List? bytes;
  final String heroTag;

  const _ZoomableImageThumbnail.file({
    required this.file,
    required this.heroTag,
  }) : bytes = null;

  const _ZoomableImageThumbnail.memory({
    required this.bytes,
    required this.heroTag,
  }) : file = null;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _openViewer(context),
      child: Hero(
        tag: heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: file != null
              ? Image.file(
                  file!,
                  width: 180,
                  height: 120,
                  fit: BoxFit.cover,
                )
              : Image.memory(
                  bytes!,
                  width: 180,
                  height: 120,
                  fit: BoxFit.cover,
                ),
        ),
      ),
    );
  }

  void _openViewer(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black.withAlpha(220),
        pageBuilder: (context, animation, secondaryAnimation) {
          return _ImageViewerPage(
            file: file,
            bytes: bytes,
            heroTag: heroTag,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }
}

class _ImageViewerPage extends StatelessWidget {
  final File? file;
  final Uint8List? bytes;
  final String heroTag;

  const _ImageViewerPage({
    required this.file,
    required this.bytes,
    required this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: ColoredBox(color: Colors.black.withAlpha(220)),
            ),
          ),
          SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Center(
                    child: Hero(
                      tag: heroTag,
                      child: InteractiveViewer(
                        maxScale: 4,
                        child: file != null
                            ? Image.file(file!, fit: BoxFit.contain)
                            : Image.memory(bytes!, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton.filledTonal(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
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
