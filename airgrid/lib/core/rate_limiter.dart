/// Token-bucket rate limiter with injectable clock for deterministic testing.
///
/// Supports burst capacity and sustained rate. Tokens refill continuously at
/// the specified rate. When tokens are exhausted, [allow] returns false and
/// [retryAfter] indicates when the next token will be available.
class RateLimiter {
  /// Current number of tokens in the bucket.
  double _tokens;

  /// Maximum tokens the bucket can hold (burst capacity).
  final int burstCapacity;

  /// Tokens added per second (sustained rate).
  final double tokensPerSecond;

  /// Last time tokens were refilled.
  DateTime _lastRefill;

  /// Clock provider for testing.
  final DateTime Function() _clock;

  /// Create a rate limiter with the specified [burstCapacity] and
  /// [tokensPerSecond] rate.
  ///
  /// Optional [clock] parameter allows injecting a custom time source for
  /// deterministic testing.
  RateLimiter({
    required this.burstCapacity,
    required this.tokensPerSecond,
    DateTime Function()? clock,
  }) : _tokens = burstCapacity.toDouble(),
       _lastRefill = (clock ?? DateTime.now)(),
       _clock = clock ?? DateTime.now;

  /// Returns the last time tokens were refilled or consumed.
  DateTime get lastActivity => _lastRefill;

  /// Attempt to consume one token.
  ///
  /// Returns true if a token was available and consumed; false if rate limited.
  bool allow() {
    _refill();
    if (_tokens >= 1.0) {
      _tokens -= 1.0;
      return true;
    }
    return false;
  }

  /// Returns the duration to wait before the next token becomes available.
  ///
  /// Returns [Duration.zero] if tokens are currently available.
  Duration retryAfter() {
    _refill();
    if (_tokens >= 1.0) {
      return Duration.zero;
    }
    final tokensNeeded = 1.0 - _tokens;
    final secondsNeeded = tokensNeeded / tokensPerSecond;
    return Duration(milliseconds: (secondsNeeded * 1000).ceil());
  }

  /// Refill tokens based on elapsed time since last refill.
  void _refill() {
    final now = _clock();
    final elapsed = now.difference(_lastRefill);
    final tokensToAdd = elapsed.inMicroseconds / 1000000.0 * tokensPerSecond;

    if (tokensToAdd > 0) {
      _tokens = (_tokens + tokensToAdd).clamp(0.0, burstCapacity.toDouble());
      _lastRefill = now;
    }
  }

  /// Reset the limiter to full capacity (used for testing or explicit resets).
  void reset() {
    _tokens = burstCapacity.toDouble();
    _lastRefill = _clock();
  }
}

/// Manages per-peer rate limiters with automatic idle eviction.
///
/// Keyed by a string identifier (endpoint ID or node ID). Limiters are
/// created on demand and evicted after [idleEviction] duration of inactivity.
class PerPeerRateLimiterMap {
  final Map<String, RateLimiter> _limiters = {};
  final int burstCapacity;
  final double tokensPerSecond;
  final Duration idleEviction;
  final DateTime Function() _clock;

  PerPeerRateLimiterMap({
    required this.burstCapacity,
    required this.tokensPerSecond,
    required this.idleEviction,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Attempt to consume one token for the specified [peerId].
  ///
  /// Creates a new limiter if one doesn't exist. Returns true if allowed.
  bool allow(String peerId) {
    final limiter = _limiters.putIfAbsent(
      peerId,
      () => RateLimiter(
        burstCapacity: burstCapacity,
        tokensPerSecond: tokensPerSecond,
        clock: _clock,
      ),
    );
    return limiter.allow();
  }

  /// Returns the retry-after duration for the specified [peerId].
  Duration retryAfter(String peerId) {
    final limiter = _limiters[peerId];
    if (limiter == null) {
      return Duration.zero;
    }
    return limiter.retryAfter();
  }

  /// Remove idle limiters that haven't been active for [idleEviction] duration.
  ///
  /// Call periodically to prevent unbounded memory growth.
  void pruneIdle() {
    final now = _clock();
    _limiters.removeWhere((_, limiter) {
      return now.difference(limiter.lastActivity) > idleEviction;
    });
  }

  /// Returns the number of active limiters (for testing/monitoring).
  int get activeLimiters => _limiters.length;

  /// Clear all limiters (for testing).
  void clear() {
    _limiters.clear();
  }
}

/// Cooldown tracker for key-announce packets, keyed by node ID + public key.
///
/// Prevents spam by enforcing a minimum interval between accepting
/// key_announce packets from the same identity.
class KeyAnnounceCooldownTracker {
  final Map<String, DateTime> _lastSeen = {};
  final Duration cooldown;
  final DateTime Function() _clock;

  KeyAnnounceCooldownTracker({
    required this.cooldown,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Returns true if enough time has passed since the last accept for this key.
  ///
  /// [nodeId] and [publicKeyBase64] uniquely identify the sender.
  bool shouldAccept(String nodeId, String publicKeyBase64) {
    final key = '$nodeId:$publicKeyBase64';
    final lastSeen = _lastSeen[key];
    final now = _clock();

    if (lastSeen == null) {
      _lastSeen[key] = now;
      return true;
    }

    if (now.difference(lastSeen) >= cooldown) {
      _lastSeen[key] = now;
      return true;
    }

    return false;
  }

  /// Prune entries older than [cooldown] duration (for memory management).
  void pruneOld() {
    final now = _clock();
    _lastSeen.removeWhere((_, lastSeen) {
      return now.difference(lastSeen) > cooldown;
    });
  }

  /// Returns the number of tracked identities (for testing/monitoring).
  int get trackedCount => _lastSeen.length;

  /// Clear all tracked identities (for testing).
  void clear() {
    _lastSeen.clear();
  }
}
