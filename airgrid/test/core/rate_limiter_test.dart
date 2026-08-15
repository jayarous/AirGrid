import 'package:airgrid/core/rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RateLimiter', () {
    test('allows burst capacity immediately', () {
      final limiter = RateLimiter(burstCapacity: 3, tokensPerSecond: 1.0);

      expect(limiter.allow(), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), false); // Exhausted
    });

    test('refills tokens over time', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final limiter = RateLimiter(
        burstCapacity: 5,
        tokensPerSecond: 2.0, // 2 tokens/sec = 1 token per 500ms
        clock: () => now,
      );

      // Consume all tokens
      for (var i = 0; i < 5; i++) {
        expect(limiter.allow(), true);
      }
      expect(limiter.allow(), false);

      // Advance 500ms → +1 token
      now = now.add(const Duration(milliseconds: 500));
      expect(limiter.allow(), true);
      expect(limiter.allow(), false);

      // Advance 1s → +2 tokens
      now = now.add(const Duration(seconds: 1));
      expect(limiter.allow(), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), false);
    });

    test('caps tokens at burst capacity', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final limiter = RateLimiter(
        burstCapacity: 3,
        tokensPerSecond: 10.0,
        clock: () => now,
      );

      // Consume 1 token
      expect(limiter.allow(), true);

      // Wait 10 seconds (would add 100 tokens if uncapped)
      now = now.add(const Duration(seconds: 10));

      // Should have 3 tokens (capped), not 102
      expect(limiter.allow(), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), false);
    });

    test('retryAfter returns zero when tokens available', () {
      final limiter = RateLimiter(burstCapacity: 5, tokensPerSecond: 1.0);

      expect(limiter.retryAfter(), Duration.zero);
    });

    test('retryAfter returns correct duration when rate limited', () {
      final now = DateTime(2026, 5, 27, 10, 0, 0);
      final limiter = RateLimiter(
        burstCapacity: 2,
        tokensPerSecond: 2.0, // 1 token per 500ms
        clock: () => now,
      );

      // Consume all tokens
      expect(limiter.allow(), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), false);

      // Should need ~500ms for next token
      final retry = limiter.retryAfter();
      expect(retry.inMilliseconds, greaterThanOrEqualTo(499));
      expect(retry.inMilliseconds, lessThanOrEqualTo(501));
    });

    test('reset restores full capacity', () {
      final limiter = RateLimiter(burstCapacity: 3, tokensPerSecond: 1.0);

      // Consume all tokens
      expect(limiter.allow(), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), false);

      limiter.reset();

      // Should have full capacity again
      expect(limiter.allow(), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), false);
    });

    test('handles fractional tokens correctly', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final limiter = RateLimiter(
        burstCapacity: 5,
        tokensPerSecond: 10.0,
        clock: () => now,
      );

      // Consume all tokens
      for (var i = 0; i < 5; i++) {
        expect(limiter.allow(), true);
      }
      expect(limiter.allow(), false);

      // Advance 50ms → +0.5 tokens (not enough for one full token)
      now = now.add(const Duration(milliseconds: 50));
      expect(limiter.allow(), false);

      // Advance another 50ms → +0.5 tokens (total 1.0 token)
      now = now.add(const Duration(milliseconds: 50));
      expect(limiter.allow(), true);
      expect(limiter.allow(), false);
    });
  });

  group('RateLimiter variable cost', () {
    test('an unpriced call still costs exactly one token', () {
      // The whole point of the default: every pre-existing caller keeps its
      // old behaviour without passing anything.
      final limiter = RateLimiter(burstCapacity: 3, tokensPerSecond: 1.0);

      expect(limiter.allow(), true);
      expect(limiter.allow(cost: 1.0), true);
      expect(limiter.allow(), true);
      expect(limiter.allow(), false);
    });

    test('a heavier call consumes proportionally more', () {
      final limiter = RateLimiter(burstCapacity: 20, tokensPerSecond: 1.0);

      expect(limiter.allow(cost: 15.0), true);
      // 5 left: enough for a small charge, not for another large one.
      expect(limiter.allow(cost: 15.0), false);
      expect(limiter.allow(cost: 5.0), true);
      expect(limiter.allow(cost: 0.5), false);
    });

    test('a refused call consumes nothing', () {
      // Otherwise a rejected request would still drain the bucket and a caller
      // retrying politely would push its own recovery further away.
      final limiter = RateLimiter(burstCapacity: 10, tokensPerSecond: 1.0);

      expect(limiter.allow(cost: 8.0), true);
      expect(limiter.allow(cost: 5.0), false);
      expect(limiter.allow(cost: 5.0), false);
      // The 2 remaining tokens survived both refusals.
      expect(limiter.allow(cost: 2.0), true);
    });

    test('fractional costs accumulate', () {
      // Frozen clock: this measures a nearly-empty bucket, and under a real
      // clock the microseconds between calls refill enough to blur it.
      //
      // Deliberately not asserted on an exact boundary. Token maths is
      // floating point, so a bucket charged 0.35 twice holds 1.2999999999999998
      // and would refuse a cost of exactly 1.3. That is invisible in practice —
      // the smallest real charge is a whole second of airtime — but it means
      // "spend the balance to precisely zero" is not a promise this class makes.
      final now = DateTime(2026, 5, 27, 10, 0, 0);
      final limiter = RateLimiter(
        burstCapacity: 2,
        tokensPerSecond: 1.0,
        clock: () => now,
      );

      expect(limiter.allow(cost: 0.35), true);
      expect(limiter.allow(cost: 0.35), true);
      expect(limiter.allow(cost: 1.25), true);
      // ~0.05 left: the three fractional charges really did add up.
      expect(limiter.allow(cost: 0.1), false);
    });

    test('refills enough for a heavy call, in proportion to the wait', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final limiter = RateLimiter(
        burstCapacity: 20,
        tokensPerSecond: 0.2, // the public-walkie airtime rate
        clock: () => now,
      );

      expect(limiter.allow(cost: 20.0), true);
      expect(limiter.allow(cost: 3.0), false);

      // 0.2/s for 10s = 2 tokens: still short of a 3s clip.
      now = now.add(const Duration(seconds: 10));
      expect(limiter.allow(cost: 3.0), false);

      // 5s more = 3 tokens total.
      now = now.add(const Duration(seconds: 5));
      expect(limiter.allow(cost: 3.0), true);
    });

    test('retryAfter answers for the cost being asked about', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final limiter = RateLimiter(
        burstCapacity: 20,
        tokensPerSecond: 1.0,
        clock: () => now,
      );

      expect(limiter.allow(cost: 20.0), true);

      // A cheap call waits 2s; an expensive one waits 10s. Asking without a
      // cost would understate both.
      expect(limiter.retryAfter(cost: 2.0), const Duration(seconds: 2));
      expect(limiter.retryAfter(cost: 10.0), const Duration(seconds: 10));

      now = now.add(const Duration(seconds: 2));
      expect(limiter.retryAfter(cost: 2.0), Duration.zero);
      expect(limiter.retryAfter(cost: 10.0), const Duration(seconds: 8));
    });

    test('a cost above burst capacity is clamped, never impossible', () {
      // Nothing charges more than the bucket holds today. If a caller's
      // maximum unit size is ever raised past it, that caller must slow down —
      // not wedge forever behind a retryAfter that never arrives.
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final limiter = RateLimiter(
        burstCapacity: 5,
        tokensPerSecond: 1.0,
        clock: () => now,
      );

      expect(limiter.allow(cost: 100.0), true, reason: 'clamped to 5');
      expect(limiter.allow(cost: 1.0), false);

      // And the wait it quotes is real: 5 tokens at 1/s.
      expect(limiter.retryAfter(cost: 100.0), const Duration(seconds: 5));
      now = now.add(const Duration(seconds: 5));
      expect(limiter.allow(cost: 100.0), true);
    });
  });

  group('PerPeerRateLimiterMap', () {
    test('creates limiter per peer on demand', () {
      final map = PerPeerRateLimiterMap(
        burstCapacity: 3,
        tokensPerSecond: 1.0,
        idleEviction: const Duration(minutes: 5),
      );

      expect(map.activeLimiters, 0);

      expect(map.allow('peer-1'), true);
      expect(map.activeLimiters, 1);

      expect(map.allow('peer-2'), true);
      expect(map.activeLimiters, 2);
    });

    test('enforces per-peer rate limits independently', () {
      final map = PerPeerRateLimiterMap(
        burstCapacity: 2,
        tokensPerSecond: 1.0,
        idleEviction: const Duration(minutes: 5),
      );

      // Peer 1 exhausts tokens
      expect(map.allow('peer-1'), true);
      expect(map.allow('peer-1'), true);
      expect(map.allow('peer-1'), false);

      // Peer 2 still has full capacity
      expect(map.allow('peer-2'), true);
      expect(map.allow('peer-2'), true);
      expect(map.allow('peer-2'), false);
    });

    test('prunes idle limiters', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final map = PerPeerRateLimiterMap(
        burstCapacity: 5,
        tokensPerSecond: 1.0,
        idleEviction: const Duration(minutes: 5),
        clock: () => now,
      );

      // Create limiters for 3 peers
      map.allow('peer-1');
      map.allow('peer-2');
      map.allow('peer-3');
      expect(map.activeLimiters, 3);

      // Advance time 6 minutes (past idle eviction)
      now = now.add(const Duration(minutes: 6));

      // Prune should remove all idle limiters
      map.pruneIdle();
      expect(map.activeLimiters, 0);
    });

    test('does not prune recently active limiters', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final map = PerPeerRateLimiterMap(
        burstCapacity: 5,
        tokensPerSecond: 1.0,
        idleEviction: const Duration(minutes: 5),
        clock: () => now,
      );

      // Create limiter for peer-1
      map.allow('peer-1');
      expect(map.activeLimiters, 1);

      // Advance 3 minutes
      now = now.add(const Duration(minutes: 3));

      // Use peer-1 again (refreshes activity)
      map.allow('peer-1');

      // Advance another 3 minutes (total 6 minutes, but only 3 since last activity)
      now = now.add(const Duration(minutes: 3));

      map.pruneIdle();
      expect(map.activeLimiters, 1); // Should NOT be pruned
    });

    test('retryAfter returns correct duration for rate limited peer', () {
      final now = DateTime(2026, 5, 27, 10, 0, 0);
      final map = PerPeerRateLimiterMap(
        burstCapacity: 1,
        tokensPerSecond: 2.0, // 1 token per 500ms
        idleEviction: const Duration(minutes: 5),
        clock: () => now,
      );

      // Exhaust peer-1
      expect(map.allow('peer-1'), true);
      expect(map.allow('peer-1'), false);

      final retry = map.retryAfter('peer-1');
      expect(retry.inMilliseconds, greaterThanOrEqualTo(499));
      expect(retry.inMilliseconds, lessThanOrEqualTo(501));
    });

    test('retryAfter returns zero for peer with no limiter', () {
      final map = PerPeerRateLimiterMap(
        burstCapacity: 5,
        tokensPerSecond: 1.0,
        idleEviction: const Duration(minutes: 5),
      );

      expect(map.retryAfter('unknown-peer'), Duration.zero);
    });
  });

  group('KeyAnnounceCooldownTracker', () {
    test('accepts first key announce from identity', () {
      final tracker = KeyAnnounceCooldownTracker(
        cooldown: const Duration(seconds: 5),
      );

      expect(tracker.shouldAccept('node-1', 'publicKey123'), true);
    });

    test('rejects key announce within cooldown period', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final tracker = KeyAnnounceCooldownTracker(
        cooldown: const Duration(seconds: 5),
        clock: () => now,
      );

      expect(tracker.shouldAccept('node-1', 'publicKey123'), true);

      // Advance 3 seconds (within cooldown)
      now = now.add(const Duration(seconds: 3));
      expect(tracker.shouldAccept('node-1', 'publicKey123'), false);
    });

    test('accepts key announce after cooldown period', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final tracker = KeyAnnounceCooldownTracker(
        cooldown: const Duration(seconds: 5),
        clock: () => now,
      );

      expect(tracker.shouldAccept('node-1', 'publicKey123'), true);

      // Advance 5 seconds (cooldown complete)
      now = now.add(const Duration(seconds: 5));
      expect(tracker.shouldAccept('node-1', 'publicKey123'), true);
    });

    test('tracks different identities independently', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final tracker = KeyAnnounceCooldownTracker(
        cooldown: const Duration(seconds: 5),
        clock: () => now,
      );

      // Accept from node-1
      expect(tracker.shouldAccept('node-1', 'publicKey123'), true);

      // Reject node-1 within cooldown
      now = now.add(const Duration(seconds: 2));
      expect(tracker.shouldAccept('node-1', 'publicKey123'), false);

      // But accept from different node
      expect(tracker.shouldAccept('node-2', 'publicKeyABC'), true);

      // And accept from same node with different key
      expect(tracker.shouldAccept('node-1', 'publicKeyDifferent'), true);
    });

    test('prunes old entries', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final tracker = KeyAnnounceCooldownTracker(
        cooldown: const Duration(seconds: 5),
        clock: () => now,
      );

      tracker.shouldAccept('node-1', 'publicKey123');
      tracker.shouldAccept('node-2', 'publicKeyABC');
      expect(tracker.trackedCount, 2);

      // Advance 6 seconds (past cooldown)
      now = now.add(const Duration(seconds: 6));

      tracker.pruneOld();
      expect(tracker.trackedCount, 0);
    });

    test('does not prune recent entries', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final tracker = KeyAnnounceCooldownTracker(
        cooldown: const Duration(seconds: 5),
        clock: () => now,
      );

      tracker.shouldAccept('node-1', 'publicKey123');
      expect(tracker.trackedCount, 1);

      // Advance 3 seconds (within cooldown)
      now = now.add(const Duration(seconds: 3));

      tracker.pruneOld();
      expect(tracker.trackedCount, 1); // Should NOT be pruned
    });

    test('updates timestamp on accepted announce', () {
      var now = DateTime(2026, 5, 27, 10, 0, 0);
      final tracker = KeyAnnounceCooldownTracker(
        cooldown: const Duration(seconds: 5),
        clock: () => now,
      );

      // First accept
      expect(tracker.shouldAccept('node-1', 'publicKey123'), true);

      // Advance past cooldown
      now = now.add(const Duration(seconds: 6));

      // Accept again (updates timestamp)
      expect(tracker.shouldAccept('node-1', 'publicKey123'), true);

      // Advance 3 seconds (would be past original cooldown, but within new cooldown)
      now = now.add(const Duration(seconds: 3));
      expect(tracker.shouldAccept('node-1', 'publicKey123'), false);
    });
  });
}
