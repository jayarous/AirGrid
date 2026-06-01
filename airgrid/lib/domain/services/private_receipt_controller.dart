import 'package:airgrid/core/constants.dart';
import 'package:airgrid/core/crypto_service.dart';
import 'package:airgrid/core/logger.dart';
import 'package:airgrid/data/storage/local_identity_store.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:airgrid/domain/models/delivery_status.dart';
import 'package:uuid/uuid.dart';

typedef LookupDirectEndpoint = String? Function(String recipientNodeId);
typedef ConnectedEndpointsProvider = List<String> Function();
typedef SpoolControlPacket = void Function(AirGridPacket packet);
typedef SendEncryptedControlPacket =
    Future<void> Function(AirGridPacket packet, List<String> targets);
typedef SendPlainControlPacket =
    Future<void> Function(AirGridPacket packet, String targetEndpointId);
typedef ResolveReceiptAlias = String Function(String receiptMessageId);
typedef EmitStatusUpdate =
    void Function(String messageId, DeliveryStatus status);
typedef AllowReadReceiptBatch = bool Function(String peerNodeId);
typedef ReadReceiptRetryAfter = Duration Function(String peerNodeId);

class PrivateReceiptController {
  PrivateReceiptController({
    required LocalIdentityStore identity,
    required CryptoService cryptoService,
    required LookupDirectEndpoint lookupDirectEndpoint,
    required ConnectedEndpointsProvider connectedEndpoints,
    required SpoolControlPacket spoolControl,
    required SendEncryptedControlPacket sendEncryptedControl,
    required SendPlainControlPacket sendPlainControl,
    required ResolveReceiptAlias resolveReceiptAlias,
    required EmitStatusUpdate emitStatusUpdate,
    required AllowReadReceiptBatch allowReadReceiptBatch,
    required ReadReceiptRetryAfter readReceiptRetryAfter,
  }) : _identity = identity,
       _cryptoService = cryptoService,
       _lookupDirectEndpoint = lookupDirectEndpoint,
       _connectedEndpoints = connectedEndpoints,
       _spoolControl = spoolControl,
       _sendEncryptedControl = sendEncryptedControl,
       _sendPlainControl = sendPlainControl,
       _resolveReceiptAlias = resolveReceiptAlias,
       _emitStatusUpdate = emitStatusUpdate,
       _allowReadReceiptBatch = allowReadReceiptBatch,
       _readReceiptRetryAfter = readReceiptRetryAfter;

  final LocalIdentityStore _identity;
  final CryptoService _cryptoService;
  final LookupDirectEndpoint _lookupDirectEndpoint;
  final ConnectedEndpointsProvider _connectedEndpoints;
  final SpoolControlPacket _spoolControl;
  final SendEncryptedControlPacket _sendEncryptedControl;
  final SendPlainControlPacket _sendPlainControl;
  final ResolveReceiptAlias _resolveReceiptAlias;
  final EmitStatusUpdate _emitStatusUpdate;
  final AllowReadReceiptBatch _allowReadReceiptBatch;
  final ReadReceiptRetryAfter _readReceiptRetryAfter;

  Future<void> sendReadReceipts(
    String peerNodeId,
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;

    if (!_allowReadReceiptBatch(peerNodeId)) {
      final retryAfter = _readReceiptRetryAfter(peerNodeId);
      AirGridLogger.log(
        LogCategory.routing,
        'Read receipt batch to $peerNodeId rate limited '
        '(retry after ${retryAfter.inMilliseconds}ms)',
      );
      return;
    }

    final directEndpointId = _lookupDirectEndpoint(peerNodeId);

    for (final msgId in messageIds) {
      final receipt = await _buildReceiptPacket(
        packetType: 'read_receipt',
        recipientNodeId: peerNodeId,
        receiptMessageId: msgId,
      );
      try {
        await _sendPrivateControlPacket(
          receipt,
          preferredEndpointId: directEndpointId,
        );
      } catch (_) {
        // best effort
      }
    }

    AirGridLogger.log(
      LogCategory.routing,
      'Sent ${messageIds.length} read receipt(s) to $peerNodeId',
    );
  }

  Future<void> handleReceipt(AirGridPacket packet) async {
    var receiptMessageId = packet.receiptMessageId;
    if (packet.encryptionVersion != null) {
      if (packet.encryptionVersion != 1 || packet.senderPublicKey == null) {
        AirGridLogger.log(
          LogCategory.validation,
          'Encrypted receipt ${packet.messageId} missing supported metadata',
        );
        return;
      }
      receiptMessageId = await _cryptoService.decryptContent(
        packet.content,
        packet.senderPublicKey!,
      );
    }

    if (receiptMessageId == null) {
      AirGridLogger.log(
        LogCategory.validation,
        'Receipt packet missing receiptMessageId - dropped',
      );
      return;
    }

    final canonicalMessageId = _resolveReceiptAlias(receiptMessageId);
    final status = packet.packetType == 'read_receipt'
        ? DeliveryStatus.read
        : DeliveryStatus.delivered;
    _emitStatusUpdate(canonicalMessageId, status);
    AirGridLogger.log(
      LogCategory.routing,
      'Receipt ${packet.packetType} for $canonicalMessageId '
      'from ${packet.senderName}',
    );
  }

  Future<void> sendDeliveryReceipt(
    AirGridPacket originalPacket,
    String preferredEndpointId,
  ) async {
    final originalSenderPublicKey = originalPacket.senderPublicKey;
    if (originalSenderPublicKey != null) {
      _cryptoService.cacheKey(
        originalPacket.senderNodeId,
        originalSenderPublicKey,
      );
    }

    final receipt = await _buildReceiptPacket(
      packetType: 'delivery_receipt',
      recipientNodeId: originalPacket.senderNodeId,
      receiptMessageId: originalPacket.messageId,
    );

    try {
      await _sendPrivateControlPacket(
        receipt,
        preferredEndpointId: preferredEndpointId,
      );
      AirGridLogger.log(
        LogCategory.routing,
        'Sent delivery_receipt for ${originalPacket.messageId} '
        'to $preferredEndpointId',
      );
    } catch (_) {
      // best effort
    }
  }

  Future<AirGridPacket> _buildReceiptPacket({
    required String packetType,
    required String recipientNodeId,
    required String receiptMessageId,
  }) async {
    final localNodeId = _identity.nodeId;
    final senderPublicKey = _identity.publicKeyBase64;
    var content = '';
    int? encryptionVersion;
    String? wireReceiptMessageId = receiptMessageId;
    var hopLimit = 1;

    if (senderPublicKey != null && _cryptoService.hasKey(recipientNodeId)) {
      final cipher = await _cryptoService.encryptContent(
        receiptMessageId,
        recipientNodeId,
      );
      if (cipher != null) {
        content = cipher;
        encryptionVersion = 1;
        wireReceiptMessageId = null;
        hopLimit = AirGridConstants.kHopLimit;
      }
    }

    return AirGridPacket(
      messageId: const Uuid().v4(),
      senderNodeId: localNodeId,
      senderName: _identity.displayName ?? 'Unknown',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      content: content,
      seenByNodes: [localNodeId],
      hopLimit: hopLimit,
      packetType: packetType,
      senderPublicKey: encryptionVersion != null ? senderPublicKey : null,
      encryptionVersion: encryptionVersion,
      conversationType: 'private',
      recipientNodeId: recipientNodeId,
      receiptMessageId: wireReceiptMessageId,
    );
  }

  Future<void> _sendPrivateControlPacket(
    AirGridPacket packet, {
    String? preferredEndpointId,
  }) async {
    final rid = packet.recipientNodeId;
    if (rid == null) return;

    final directEndpoint = _lookupDirectEndpoint(rid);

    if (packet.encryptionVersion != null) {
      final targets = directEndpoint != null
          ? <String>[directEndpoint]
          : _connectedEndpoints();

      if (targets.isEmpty) {
        _spoolControl(packet);
        return;
      }

      await _sendEncryptedControl(packet, targets);
      return;
    }

    final plaintextTarget = directEndpoint ?? preferredEndpointId;
    if (plaintextTarget == null) return;
    await _sendPlainControl(packet, plaintextTarget);
  }
}
