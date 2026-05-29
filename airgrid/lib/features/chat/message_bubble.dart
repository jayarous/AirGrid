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
              // Message content and timestamp packed beautifully
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: message.messageKind == 'image'
                        ? _ImageMessageContent(message: message, textColor: textColor)
                        : Text(
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
