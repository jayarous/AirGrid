import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/constants.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';

// -- Binary v2 constants -------------------------------------------------------

/// Magic byte that identifies the binary v2 wire format.
const int _kMagicV2 = 0x02;

/// Packet type -> compact integer for binary encoding.
const _kPacketTypeToInt = <String, int>{
  'chat': 0,
  'key_announce': 1,
  'location_update': 2,
  'delivery_receipt': 3,
  'read_receipt': 4,
  'fragment': 5,
  'image': 6,
  'audio': 7,
  'file': 8,
};

/// Compact integer -> packet type string for binary decoding.
const _kIntToPacketType = [
  'chat',
  'key_announce',
  'location_update',
  'delivery_receipt',
  'read_receipt',
  'fragment',
  'image',
  'audio',
  'file',
];

// -- Flags byte bit positions --------------------------------------------------
const int _kFlagIsPrivate = 0x01;
const int _kFlagHasRecipient = 0x02;
const int _kFlagHasEncVersion = 0x04;
const int _kFlagHasPubKey = 0x08;
const int _kFlagHasReceiptId = 0x10;
const int _kFlagIsFragment = 0x20;

// -- Codec ---------------------------------------------------------------------

/// Serialises and deserialises [AirGridPacket] <-> [Uint8List].
///
/// **Encoding**: binary v2 - length-prefixed TLV with magic byte [_kMagicV2].
/// No UUID-format assumption is made for any ID field; all strings are
/// length-prefixed UTF-8.
///
/// **Decoding**: if the first byte equals [_kMagicV2] the binary v2 path is
/// used; otherwise the legacy UTF-8 JSON path is tried for backward
/// compatibility with older nodes.
///
/// Max frame size: [AirGridConstants.kMaxPacketBytes], checked on
/// both encode and decode.
///
/// Binary v2 wire layout:
/// ```
/// [0x02]              version       (1 byte)
/// [packetType]        uint8         (1 byte, see _kPacketTypeToInt)
/// [hopLimit]          uint8         (1 byte)
/// [timestamp]         int64 BE      (8 bytes)
/// [uint16][messageId]               length-prefixed UTF-8
/// [uint16][senderNodeId]            length-prefixed UTF-8
/// [uint16][senderName]              length-prefixed UTF-8
/// [uint32][content]                 length-prefixed bytes
/// [uint8 count]       seenByNodes   count, then each as [uint16][nodeId]
/// [flags]             uint8         (bit0=private, bit1=hasRecipient,
///                                    bit2=hasEncVersion, bit3=hasPubKey,
///                                    bit4=hasReceiptId, bit5=isFragment)
/// -- conditional fields, in bit order --
/// if bit1: [uint16][recipientNodeId]
/// if bit2: [uint8  encryptionVersion]
/// if bit3: [uint16][senderPublicKey bytes]
/// if bit4: [uint16][receiptMessageId]
/// if bit5: [uint16][fragmentOf] [uint16 fragmentIndex] [uint16 fragmentCount]
/// ```
class TransportCodec {
  TransportCodec._();

  // -- Public API ---------------------------------------------------------------

  /// Encodes [packet] to binary v2 bytes.
  ///
  /// Throws [ArgumentError] if the encoded size exceeds [AirGridConstants.kMaxPacketBytes].
  static Uint8List encode(AirGridPacket packet) {
    final buf = BytesBuilder(copy: false);

    // Header: version, type, hopLimit.
    final packetTypeInt = _kPacketTypeToInt[packet.packetType];
    if (packetTypeInt == null) {
      throw ArgumentError('Unknown packetType: "${packet.packetType}".');
    }
    if (packet.hopLimit < 0 || packet.hopLimit > 255) {
      throw ArgumentError(
        'hopLimit ${packet.hopLimit} is out of the valid range 0-255.',
      );
    }

    buf.addByte(_kMagicV2);
    buf.addByte(packetTypeInt);
    buf.addByte(packet.hopLimit);

    // Timestamp - 8-byte big-endian signed int64.
    _writeInt64(buf, packet.timestamp);

    // Required string fields.
    _writeLenStr(buf, packet.messageId);
    _writeLenStr(buf, packet.senderNodeId);
    _writeLenStr(buf, packet.senderName);

    // Content - 4-byte length prefix so large payloads are supported.
    final contentBytes = utf8.encode(packet.content);
    _writeUint32(buf, contentBytes.length);
    buf.add(contentBytes);

    // seenByNodes - 1-byte count + each as length-prefixed string.
    final seen = packet.seenByNodes;
    if (seen.length > 255) {
      throw ArgumentError(
        'seenByNodes has ${seen.length} entries; max is 255.',
      );
    }
    buf.addByte(seen.length);
    for (final nodeId in seen) {
      _writeLenStr(buf, nodeId);
    }

    // Flags byte - bitmask of which optional fields are present.
    int flags = 0;
    if (packet.conversationType == 'private') flags |= _kFlagIsPrivate;
    if (packet.recipientNodeId != null) flags |= _kFlagHasRecipient;
    if (packet.encryptionVersion != null) flags |= _kFlagHasEncVersion;
    if (packet.senderPublicKey != null) flags |= _kFlagHasPubKey;
    if (packet.receiptMessageId != null) flags |= _kFlagHasReceiptId;
    if (packet.fragmentOf != null) flags |= _kFlagIsFragment;
    buf.addByte(flags);

    // Conditional fields - only present when the corresponding flag is set.
    if (packet.recipientNodeId != null) {
      _writeLenStr(buf, packet.recipientNodeId!);
    }
    if (packet.encryptionVersion != null) {
      final ev = packet.encryptionVersion!;
      if (ev < 0 || ev > 255) {
        throw ArgumentError(
          'encryptionVersion $ev is out of the valid range 0-255.',
        );
      }
      buf.addByte(ev);
    }
    if (packet.senderPublicKey != null) {
      final pkBytes = utf8.encode(packet.senderPublicKey!);
      _writeUint16(buf, pkBytes.length);
      buf.add(pkBytes);
    }
    if (packet.receiptMessageId != null) {
      _writeLenStr(buf, packet.receiptMessageId!);
    }
    if (packet.fragmentOf != null) {
      _writeLenStr(buf, packet.fragmentOf!);
      _writeUint16(buf, packet.fragmentIndex ?? 0);
      _writeUint16(buf, packet.fragmentCount ?? 0);
    }

    final bytes = buf.toBytes();
    if (bytes.length > AirGridConstants.kMaxPacketBytes) {
      throw ArgumentError(
        'Encoded packet is ${bytes.length} bytes; '
        'max is ${AirGridConstants.kMaxPacketBytes}.',
      );
    }
    return bytes;
  }

  /// Decodes [bytes] to an [AirGridPacket], or returns null on failure.
  ///
  /// Routes to binary v2 if the first byte is [_kMagicV2]; otherwise falls
  /// back to the legacy UTF-8 JSON path for backward compatibility.
  static AirGridPacket? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    if (bytes.length > AirGridConstants.kMaxPacketBytes) return null;
    if (bytes[0] == _kMagicV2) return _decodeBinaryV2(bytes);
    return _decodeLegacyJson(bytes);
  }

  // -- Binary v2 encode helpers -------------------------------------------------

  static void _writeLenStr(BytesBuilder buf, String s) {
    final encoded = utf8.encode(s);
    _writeUint16(buf, encoded.length);
    buf.add(encoded);
  }

  static void _writeUint16(BytesBuilder buf, int v) {
    buf.addByte((v >> 8) & 0xFF);
    buf.addByte(v & 0xFF);
  }

  static void _writeUint32(BytesBuilder buf, int v) {
    buf.addByte((v >> 24) & 0xFF);
    buf.addByte((v >> 16) & 0xFF);
    buf.addByte((v >> 8) & 0xFF);
    buf.addByte(v & 0xFF);
  }

  static void _writeInt64(BytesBuilder buf, int v) {
    // Split into two unsigned 32-bit halves.
    final hi = (v >> 32) & 0xFFFFFFFF;
    final lo = v & 0xFFFFFFFF;
    buf.addByte((hi >> 24) & 0xFF);
    buf.addByte((hi >> 16) & 0xFF);
    buf.addByte((hi >> 8) & 0xFF);
    buf.addByte(hi & 0xFF);
    buf.addByte((lo >> 24) & 0xFF);
    buf.addByte((lo >> 16) & 0xFF);
    buf.addByte((lo >> 8) & 0xFF);
    buf.addByte(lo & 0xFF);
  }

  // -- Binary v2 decode --------------------------------------------------------

  static AirGridPacket? _decodeBinaryV2(Uint8List bytes) {
    try {
      var offset = 0;

      int readByte() {
        if (offset >= bytes.length) throw RangeError('eof');
        return bytes[offset++];
      }

      int readUint16() {
        final hi = readByte();
        final lo = readByte();
        return (hi << 8) | lo;
      }

      int readUint32() {
        final b3 = readByte();
        final b2 = readByte();
        final b1 = readByte();
        final b0 = readByte();
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0;
      }

      int readInt64() {
        final hi = readUint32();
        final lo = readUint32();
        return (hi << 32) | lo;
      }

      String readLenStr() {
        final len = readUint16();
        final slice = bytes.sublist(offset, offset + len);
        offset += len;
        return utf8.decode(slice);
      }

      List<int> readRawBytes(int len) {
        final slice = bytes.sublist(offset, offset + len);
        offset += len;
        return slice;
      }

      // Version byte (already validated as _kMagicV2).
      readByte();

      // Packet type - reject any integer not in the known set.
      final typeInt = readByte();
      if (typeInt >= _kIntToPacketType.length) {
        // Unknown packet type: drop rather than misclassify as chat.
        return null;
      }
      final packetType = _kIntToPacketType[typeInt];

      final hopLimit = readByte();
      final timestamp = readInt64();

      final messageId = readLenStr();
      final senderNodeId = readLenStr();
      final senderName = readLenStr();

      // Content.
      final contentLen = readUint32();
      final contentBytes = readRawBytes(contentLen);
      final content = utf8.decode(contentBytes);

      // seenByNodes.
      final seenCount = readByte();
      final seenByNodes = <String>[];
      for (var i = 0; i < seenCount; i++) {
        seenByNodes.add(readLenStr());
      }

      // Flags.
      final flags = readByte();
      final isPrivate = (flags & _kFlagIsPrivate) != 0;
      final hasRecipient = (flags & _kFlagHasRecipient) != 0;
      final hasEncVersion = (flags & _kFlagHasEncVersion) != 0;
      final hasPubKey = (flags & _kFlagHasPubKey) != 0;
      final hasReceiptId = (flags & _kFlagHasReceiptId) != 0;
      final isFragment = (flags & _kFlagIsFragment) != 0;

      // Conditional fields - must be read in the same order as written.
      String? recipientNodeId;
      if (hasRecipient) recipientNodeId = readLenStr();

      int? encryptionVersion;
      if (hasEncVersion) encryptionVersion = readByte();

      String? senderPublicKey;
      if (hasPubKey) {
        final pkLen = readUint16();
        senderPublicKey = utf8.decode(readRawBytes(pkLen));
      }

      String? receiptMessageId;
      if (hasReceiptId) receiptMessageId = readLenStr();

      String? fragmentOf;
      int? fragmentIndex;
      int? fragmentCount;
      if (isFragment) {
        fragmentOf = readLenStr();
        fragmentIndex = readUint16();
        fragmentCount = readUint16();
      }

      return AirGridPacket(
        messageId: messageId,
        senderNodeId: senderNodeId,
        senderName: senderName,
        timestamp: timestamp,
        content: content,
        seenByNodes: seenByNodes,
        hopLimit: hopLimit,
        packetType: packetType,
        senderPublicKey: senderPublicKey,
        encryptionVersion: encryptionVersion,
        conversationType: isPrivate ? 'private' : 'public',
        recipientNodeId: recipientNodeId,
        receiptMessageId: receiptMessageId,
        fragmentOf: fragmentOf,
        fragmentIndex: fragmentIndex,
        fragmentCount: fragmentCount,
      );
    } catch (_) {
      return null;
    }
  }

  // -- Legacy JSON fallback -----------------------------------------------------

  static AirGridPacket? _decodeLegacyJson(Uint8List bytes) {
    try {
      final json = utf8.decode(bytes);
      final map = jsonDecode(json) as Map<String, dynamic>;
      return AirGridPacket.fromJson(map);
    } catch (_) {
      return null;
    }
  }
}
