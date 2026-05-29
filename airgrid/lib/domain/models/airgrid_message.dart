import 'airgrid_packet.dart';
import 'delivery_status.dart';

/// Immutable display model shown in the chat UI.
///
/// Derived from an [AirGridPacket]; [isLocal] is true when the message was
/// sent by this device.  [isEncrypted] is true when the packet carried an
/// [AirGridPacket.encryptionVersion] — regardless of whether decryption
/// succeeded.
class AirGridMessage {
  final String id;
  final String senderNodeId;
  final String senderName;
  final DateTime timestamp;
  final String content;
  final bool isLocal;

  /// True if this message was transmitted with opportunistic encryption.
  final bool isEncrypted;

  /// 'public' for mesh broadcast or 'private' for direct peer messages.
  final String conversationType;

  /// Stable node id of the other participant. Null for public messages.
  final String? peerNodeId;

  /// Display name of the other participant. Null for public messages.
  final String? peerName;

  /// True once this device has opened the containing private thread.
  ///
  /// Public messages and local outgoing messages are always considered read.
  final bool isRead;

  /// Delivery status for outgoing private messages.
  ///
  /// Defaults to [DeliveryStatus.sent] for backward compatibility (loaded
  /// history and received messages) and for public messages (which do not
  /// participate in the receipt system).
  final DeliveryStatus deliveryStatus;

  /// Message kind: 'text' (default), 'image', 'audio', or 'file'.
  final String messageKind;

  /// MIME type for image messages.
  final String? mediaMimeType;

  /// Original transferred image byte size.
  final int? mediaByteLength;

  /// Optional image dimensions if known.
  final int? mediaWidth;
  final int? mediaHeight;

  /// Stable transfer id used for temp-file caching.
  final String? mediaTransferId;

  /// Optional media duration in milliseconds (used by audio messages).
  final int? mediaDurationMs;

  /// Ephemeral temp path to image bytes. May be null after restart.
  final String? mediaTempPath;

  /// Optional base64 preview bytes used as a fallback when temp files are unavailable.
  ///
  /// This is intended for in-memory UI rendering only and is not persisted.
  final String? mediaPreviewBase64;

  /// Optional upload progress for outgoing file attachments, from 0.0 to 1.0.
  final double? mediaTransferProgress;

  const AirGridMessage({
    required this.id,
    required this.senderNodeId,
    required this.senderName,
    required this.timestamp,
    required this.content,
    required this.isLocal,
    this.isEncrypted = false,
    this.conversationType = 'public',
    this.peerNodeId,
    this.peerName,
    this.isRead = true,
    this.deliveryStatus = DeliveryStatus.sent,
    this.messageKind = 'text',
    this.mediaMimeType,
    this.mediaByteLength,
    this.mediaWidth,
    this.mediaHeight,
    this.mediaTransferId,
    this.mediaDurationMs,
    this.mediaTempPath,
    this.mediaPreviewBase64,
    this.mediaTransferProgress,
  });

  factory AirGridMessage.fromPacket(
    AirGridPacket packet,
    String localNodeId, {
    String? conversationType,
    String? peerNodeId,
    String? peerName,
    bool? isRead,
    DeliveryStatus? deliveryStatus,
    String? messageKind,
    String? mediaMimeType,
    int? mediaByteLength,
    int? mediaWidth,
    int? mediaHeight,
    String? mediaTransferId,
    int? mediaDurationMs,
    String? mediaTempPath,
    String? mediaPreviewBase64,
    double? mediaTransferProgress,
  }) {
    return AirGridMessage(
      id: packet.messageId,
      senderNodeId: packet.senderNodeId,
      senderName: packet.senderName,
      timestamp: DateTime.fromMillisecondsSinceEpoch(packet.timestamp),
      content: packet.content,
      isLocal: packet.senderNodeId == localNodeId,
      isEncrypted: packet.encryptionVersion != null,
      conversationType: conversationType ?? packet.conversationType,
      peerNodeId: peerNodeId,
      peerName: peerName,
      isRead: isRead ?? true,
      deliveryStatus: deliveryStatus ?? DeliveryStatus.sent,
      messageKind: messageKind ?? 'text',
      mediaMimeType: mediaMimeType,
      mediaByteLength: mediaByteLength,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
      mediaTransferId: mediaTransferId,
      mediaDurationMs: mediaDurationMs,
      mediaTempPath: mediaTempPath,
      mediaPreviewBase64: mediaPreviewBase64,
      mediaTransferProgress: mediaTransferProgress,
    );
  }

  AirGridMessage copyWith({
    bool? isRead,
    DeliveryStatus? deliveryStatus,
    String? mediaTempPath,
    String? mediaPreviewBase64,
    double? mediaTransferProgress,
  }) {
    return AirGridMessage(
      id: id,
      senderNodeId: senderNodeId,
      senderName: senderName,
      timestamp: timestamp,
      content: content,
      isLocal: isLocal,
      isEncrypted: isEncrypted,
      conversationType: conversationType,
      peerNodeId: peerNodeId,
      peerName: peerName,
      isRead: isRead ?? this.isRead,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
      messageKind: messageKind,
      mediaMimeType: mediaMimeType,
      mediaByteLength: mediaByteLength,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight,
      mediaTransferId: mediaTransferId,
      mediaDurationMs: mediaDurationMs,
      mediaTempPath: mediaTempPath ?? this.mediaTempPath,
      mediaPreviewBase64: mediaPreviewBase64 ?? this.mediaPreviewBase64,
      mediaTransferProgress:
          mediaTransferProgress ?? this.mediaTransferProgress,
    );
  }

  @override
  String toString() =>
      'AirGridMessage(id=$id, from=$senderName, local=$isLocal, encrypted=$isEncrypted, conv=$conversationType, status=$deliveryStatus)';
}
