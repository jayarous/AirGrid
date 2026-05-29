import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:airgrid/core/constants.dart';
import 'package:airgrid/data/transport/transport_codec.dart';
import 'package:airgrid/domain/models/airgrid_packet.dart';
import 'package:uuid/uuid.dart';

// -- Internal reassembly state ------------------------------------------------

class _ReassemblyBucket {
  final List<AirGridPacket?> slots;
  final DateTime createdAt;
  int filled = 0;
  int byteCount = 0;

  _ReassemblyBucket(int count, DateTime now)
    : slots = List.filled(count, null),
      createdAt = now;
}

// -- Public API ---------------------------------------------------------------

/// Handles packet fragmentation (outgoing) and reassembly (incoming).
///
/// **Fragmentation** encodes [original] to binary, splits it into chunks of
/// at most [threshold] bytes, and wraps each chunk in a `'fragment'` packet.
/// Each fragment inherits the metadata needed for correct relay-eligibility
/// (`conversationType`, `encryptionVersion`, `recipientNodeId`, etc.).
///
/// **Reassembly** accumulates incoming fragment packets in per-`fragmentOf`
/// buckets.  When all [AirGridPacket.fragmentCount] slots are filled the
/// chunks are concatenated and decoded back into the original packet.
///
/// The [fragment] method is static (no instance needed).
/// [tryReassemble] is an instance method; create one [PacketFragmenter] per
/// service that needs reassembly so buckets are scoped appropriately.
class PacketFragmenter {
  final int _maxBuckets;
  final int _maxBytesInFlight;
  final Duration _ttl;
  final DateTime Function() _clock;
  final LinkedHashMap<String, _ReassemblyBucket> _buckets = LinkedHashMap();

  PacketFragmenter({
    int maxBuckets = AirGridConstants.kMaxReassemblyBuckets,
    int maxBytesInFlight = AirGridConstants.kReassemblyMaxBytesInFlight,
    Duration ttl = AirGridConstants.kReassemblyTtl,
    DateTime Function()? clock,
  }) : _maxBuckets = maxBuckets,
       _maxBytesInFlight = maxBytesInFlight,
       _ttl = ttl,
       _clock = clock ?? DateTime.now;

  // -- Fragmentation ----------------------------------------------------------

  /// Encodes [original] and splits it into fragment packets when its encoded
  /// size exceeds [threshold] bytes.
  ///
  /// Returns `[original]` unchanged when no fragmentation is needed.
  ///
  /// Each fragment packet has:
  /// - `packetType = 'fragment'`
  /// - `content = base64(encoded_chunk)`
  /// - `fragmentOf`, `fragmentIndex`, `fragmentCount` set appropriately
  /// - All relay-relevant metadata copied from [original]:
  ///   `senderNodeId`, `senderName`, `timestamp`, `seenByNodes`, `hopLimit`,
  ///   `conversationType`, `encryptionVersion`, `senderPublicKey`,
  ///   `recipientNodeId`.
  ///
  /// Fragment packets share the same [seenByNodes] list reference from
  /// [original] since packets are immutable and the list will not be modified.
  static List<AirGridPacket> fragment(
    AirGridPacket original, {
    int threshold = AirGridConstants.kFragmentThreshold,
  }) {
    final encoded = TransportCodec.encode(original);
    if (encoded.length <= threshold) return [original];

    final chunkCount = (encoded.length + threshold - 1) ~/ threshold;
    return List.generate(chunkCount, (i) {
      final start = i * threshold;
      final end = (start + threshold).clamp(0, encoded.length);
      return AirGridPacket(
        messageId: const Uuid().v4(),
        senderNodeId: original.senderNodeId,
        senderName: original.senderName,
        timestamp: original.timestamp,
        content: base64.encode(encoded.sublist(start, end)),
        seenByNodes: original.seenByNodes, // Shared reference (immutable)
        hopLimit: original.hopLimit,
        packetType: 'fragment',
        senderPublicKey: original.senderPublicKey,
        encryptionVersion: original.encryptionVersion,
        conversationType: original.conversationType,
        recipientNodeId: original.recipientNodeId,
        fragmentOf: original.messageId,
        fragmentIndex: i,
        fragmentCount: chunkCount,
      );
    });
  }

  // -- Reassembly -------------------------------------------------------------

  /// Accumulates [fragment] into the internal reassembly buffer.
  ///
  /// Returns the decoded original [AirGridPacket] once all fragments for
  /// `fragment.fragmentOf` have arrived.  Returns `null` when:
  /// - `fragmentOf`, `fragmentIndex`, or `fragmentCount` are missing/invalid,
  /// - this slot was already filled (duplicate fragment), or
  /// - reassembly is not yet complete.
  ///
  /// Completed buckets are removed immediately.  The oldest bucket is evicted
  /// when the buffer is at capacity ([maxBuckets]).
  AirGridPacket? tryReassemble(AirGridPacket fragment) {
    final origId = fragment.fragmentOf;
    final idx = fragment.fragmentIndex;
    final count = fragment.fragmentCount;

    if (origId == null || idx == null || count == null) return null;
    if (count < 1 || idx < 0 || idx >= count) return null;

    // Prune any buckets that have exceeded the TTL before touching the map.
    final now = _clock();
    _buckets.removeWhere((_, b) => now.difference(b.createdAt) > _ttl);

    final fragmentBytes = _estimateDecodedBytes(fragment.content);
    if (fragmentBytes <= 0) return null;

    while (_bytesInFlight() + fragmentBytes > _maxBytesInFlight &&
        _buckets.isNotEmpty) {
      _buckets.remove(_buckets.keys.first);
    }
    if (_bytesInFlight() + fragmentBytes > _maxBytesInFlight) {
      return null;
    }

    var bucket = _buckets[origId];
    if (bucket == null) {
      if (_buckets.length >= _maxBuckets) {
        _buckets.remove(_buckets.keys.first);
      }
      bucket = _ReassemblyBucket(count, now);
      _buckets[origId] = bucket;
    }

    if (bucket.slots[idx] != null) return null; // duplicate slot
    bucket.slots[idx] = fragment;
    bucket.filled++;
    bucket.byteCount += fragmentBytes;

    if (bucket.filled < count) return null;

    // All fragments present -- concatenate and decode.
    final bytes = BytesBuilder(copy: false);
    for (final frag in bucket.slots) {
      bytes.add(base64.decode(frag!.content));
    }
    _buckets.remove(origId);
    return TransportCodec.decode(bytes.toBytes());
  }

  int _bytesInFlight() {
    var total = 0;
    for (final bucket in _buckets.values) {
      total += bucket.byteCount;
    }
    return total;
  }

  int _estimateDecodedBytes(String base64Data) {
    final len = base64Data.length;
    if (len == 0) return 0;
    var padding = 0;
    if (base64Data.endsWith('==')) {
      padding = 2;
    } else if (base64Data.endsWith('=')) {
      padding = 1;
    }
    return (len * 3 ~/ 4) - padding;
  }
}
