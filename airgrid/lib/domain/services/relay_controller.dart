import 'dart:math';

/// The result of an adaptive relay policy decision.
class RelayDecision {
  final bool shouldRelay;

  /// The new hop limit to assign to the forwarded packet.
  final int newHopLimit;

  /// How many milliseconds to wait before forwarding (jitter).
  final int delayMs;

  const RelayDecision({
    required this.shouldRelay,
    required this.newHopLimit,
    required this.delayMs,
  });
}

/// Adaptive relay policy for AirGrid mesh packets.
///
/// Pure static helper - no mutable state, no side effects.
///
/// Determines for each packet:
/// - whether it should be relayed at all,
/// - what TTL (hop limit) to assign to the forward copy, and
/// - how long to wait (random jitter) before forwarding.
///
/// TTL caps prevent runaway flooding while still allowing multi-hop delivery:
/// - public chat          -> 6
/// - key_announce / location_update -> 7
/// - directed encrypted (private encrypted, receipts, fragments) -> 8
///
/// Jitter adapts to local peer density so dense meshes self-throttle:
/// - sparse  (<4 peers)  -> 0-20 ms
/// - medium  (4-7 peers) -> 20-80 ms
/// - dense   (8+ peers)  -> 80-250 ms
class RelayController {
  RelayController._();

  // -- TTL caps -------------------------------------------------------------

  static const int _ttlPublicChat = 6;
  static const int _ttlKeyLocation = 7;
  static const int _ttlDirectedEncrypted = 8;

  // -- Jitter bounds (ms) ---------------------------------------------------

  static const int _jitterSparseMax = 20;
  static const int _jitterMediumMin = 20;
  static const int _jitterMediumMax = 80;
  static const int _jitterDenseMin = 80;
  static const int _jitterDenseMax = 250;

  // -- Density thresholds ---------------------------------------------------

  static const int _sparseCutoff = 4;
  static const int _denseCutoff = 8;

  static final _rng = Random();

  // -------------------------------------------------------------------------

  /// Decide whether and how to relay a packet.
  ///
  /// [packetType] is the [AirGridPacket.packetType] string.
  /// [isDirectedEncrypted] should be true when [conversationType] is
  /// `'private'` **and** [encryptionVersion] is non-null.
  /// [peerCount] is the number of currently connected direct peers.
  /// [currentHopLimit] is the packet's existing hop limit before decrement.
  static RelayDecision decide({
    required String packetType,
    required bool isDirectedEncrypted,
    required int peerCount,
    required int currentHopLimit,
  }) {
    if (currentHopLimit <= 0) {
      return const RelayDecision(
        shouldRelay: false,
        newHopLimit: 0,
        delayMs: 0,
      );
    }

    final ttlCap = _ttlCapFor(packetType, isDirectedEncrypted);
    final newHopLimit = min(currentHopLimit - 1, ttlCap);

    // A forward copy with hopLimit=0 would be dropped at Gate 2 on every
    // recipient - don't waste bandwidth sending it.
    if (newHopLimit <= 0) {
      return const RelayDecision(
        shouldRelay: false,
        newHopLimit: 0,
        delayMs: 0,
      );
    }

    final delayMs = _jitterMs(peerCount);

    return RelayDecision(
      shouldRelay: true,
      newHopLimit: newHopLimit,
      delayMs: delayMs,
    );
  }

  // -- Helpers --------------------------------------------------------------

  static int _ttlCapFor(String packetType, bool isDirectedEncrypted) {
    if (isDirectedEncrypted ||
        packetType == 'delivery_receipt' ||
        packetType == 'read_receipt' ||
        packetType == 'fragment') {
      return _ttlDirectedEncrypted;
    }
    if (packetType == 'key_announce' || packetType == 'location_update') {
      return _ttlKeyLocation;
    }
    return _ttlPublicChat;
  }

  static int _jitterMs(int peerCount) {
    if (peerCount < _sparseCutoff) {
      return _rng.nextInt(_jitterSparseMax + 1); // 0-20 ms
    } else if (peerCount < _denseCutoff) {
      final range = _jitterMediumMax - _jitterMediumMin;
      return _jitterMediumMin + _rng.nextInt(range + 1); // 20-80 ms
    } else {
      final range = _jitterDenseMax - _jitterDenseMin;
      return _jitterDenseMin + _rng.nextInt(range + 1); // 80-250 ms
    }
  }
}
