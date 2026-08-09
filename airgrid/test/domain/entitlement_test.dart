import 'package:airgrid/domain/models/entitlement.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixed reference instant. Every case here uses an explicit clock value —
/// nothing reads `DateTime.now()`, so these tests cannot go flaky on a slow
/// machine or across a midnight boundary.
final _now = DateTime.utc(2026, 8, 9, 12);

Entitlement _plus({
  BillingPeriod period = BillingPeriod.monthly,
  DateTime? expiresAt,
  DateTime? lastVerifiedAt,
  DateTime? maxClockSeen,
}) {
  return Entitlement(
    tier: EntitlementTier.plus,
    period: period,
    productId: 'airgrid_plus',
    purchaseToken: 'token-abc',
    expiresAt: expiresAt,
    lastVerifiedAt: lastVerifiedAt,
    maxClockSeen: maxClockSeen,
  );
}

void main() {
  group('free tier', () {
    test('is free, not plus, and carries no trust window', () {
      expect(Entitlement.free.statusAt(_now), EntitlementStatus.free);
      expect(Entitlement.free.isPlusAt(_now), isFalse);
      expect(Entitlement.free.offlineTrustWindow, Duration.zero);
    });
  });

  group('offline trust window', () {
    test('scales with the billing period', () {
      expect(
        _plus(period: BillingPeriod.weekly).offlineTrustWindow,
        const Duration(days: 7),
      );
      expect(
        _plus(period: BillingPeriod.monthly).offlineTrustWindow,
        const Duration(days: 30),
      );
      expect(
        _plus(period: BillingPeriod.yearly).offlineTrustWindow,
        const Duration(days: 30),
      );
    });

    test('never drops below the seven-day floor', () {
      for (final period in BillingPeriod.values) {
        expect(
          _plus(period: period).offlineTrustWindow,
          greaterThanOrEqualTo(Entitlement.weeklyTrustWindow),
          reason: '$period must cover a festival or a blackout',
        );
      }
    });
  });

  group('statusAt', () {
    test('is active inside the paid period', () {
      final entitlement = _plus(
        expiresAt: _now.add(const Duration(days: 3)),
        lastVerifiedAt: _now.subtract(const Duration(days: 1)),
      );
      expect(entitlement.statusAt(_now), EntitlementStatus.active);
      expect(entitlement.isPlusAt(_now), isTrue);
    });

    test('is active inside the period even when verification is stale', () {
      // The cached receipt says paid until next week. Not having reached Play
      // for a fortnight does not change that.
      final entitlement = _plus(
        expiresAt: _now.add(const Duration(days: 7)),
        lastVerifiedAt: _now.subtract(const Duration(days: 14)),
      );
      expect(entitlement.statusAt(_now), EntitlementStatus.active);
    });

    test('is offlineTrusted past expiry but inside the window', () {
      // The renewal date passed while off-grid. This is the case the whole
      // design exists for: keep the user working.
      final entitlement = _plus(
        expiresAt: _now.subtract(const Duration(days: 2)),
        lastVerifiedAt: _now.subtract(const Duration(days: 5)),
      );
      expect(entitlement.statusAt(_now), EntitlementStatus.offlineTrusted);
      expect(entitlement.isPlusAt(_now), isTrue);
    });

    test('is lapsed past expiry and past the window', () {
      final entitlement = _plus(
        expiresAt: _now.subtract(const Duration(days: 40)),
        lastVerifiedAt: _now.subtract(const Duration(days: 31)),
      );
      expect(entitlement.statusAt(_now), EntitlementStatus.lapsed);
      expect(entitlement.isPlusAt(_now), isFalse);
    });

    test('is lapsed when the entitlement was never verified', () {
      final entitlement = _plus(
        expiresAt: _now.subtract(const Duration(days: 1)),
      );
      expect(entitlement.statusAt(_now), EntitlementStatus.lapsed);
    });

    test('weekly gets seven days of trust, not thirty', () {
      final entitlement = _plus(
        period: BillingPeriod.weekly,
        expiresAt: _now.subtract(const Duration(days: 9)),
        lastVerifiedAt: _now.subtract(const Duration(days: 9)),
      );
      // A monthly buyer would still be trusted here. A weekly one is not.
      expect(entitlement.statusAt(_now), EntitlementStatus.lapsed);
      expect(
        entitlement.copyWith(period: BillingPeriod.monthly).statusAt(_now),
        EntitlementStatus.offlineTrusted,
      );
    });

    test('the window boundary is exclusive', () {
      Entitlement atAge(Duration age) => _plus(
        period: BillingPeriod.weekly,
        expiresAt: _now.subtract(const Duration(days: 8)),
        lastVerifiedAt: _now.subtract(age),
      );

      expect(
        atAge(
          const Duration(days: 7) - const Duration(minutes: 1),
        ).statusAt(_now),
        EntitlementStatus.offlineTrusted,
      );
      expect(
        atAge(const Duration(days: 7)).statusAt(_now),
        EntitlementStatus.lapsed,
      );
    });
  });

  group('no expiry from Play', () {
    // The Android client is never told when a subscription ends. These cases
    // pin the behaviour that stands in for it.

    test('a fresh confirmation reads as active', () {
      final entitlement = _plus(lastVerifiedAt: _now);
      expect(entitlement.statusAt(_now), EntitlementStatus.active);
      expect(
        entitlement.statusAt(_now.add(const Duration(hours: 23))),
        EntitlementStatus.active,
      );
    });

    test('a stale confirmation falls back to the trust window', () {
      final entitlement = _plus(lastVerifiedAt: _now);
      // Past the freshness window, inside the monthly trust window.
      expect(
        entitlement.statusAt(_now.add(const Duration(days: 3))),
        EntitlementStatus.offlineTrusted,
      );
      // Past both.
      expect(
        entitlement.statusAt(_now.add(const Duration(days: 31))),
        EntitlementStatus.lapsed,
      );
    });

    test('an unknown period still gets the seven-day floor', () {
      final entitlement = Entitlement(
        tier: EntitlementTier.plus,
        purchaseToken: 'token-abc',
        lastVerifiedAt: _now,
      );
      expect(entitlement.period, isNull);
      expect(entitlement.offlineTrustWindow, Entitlement.weeklyTrustWindow);
      expect(
        entitlement.statusAt(_now.add(const Duration(days: 5))),
        EntitlementStatus.offlineTrusted,
      );
      expect(
        entitlement.statusAt(_now.add(const Duration(days: 8))),
        EntitlementStatus.lapsed,
      );
    });

    test('a free tier still gets no window at all', () {
      expect(Entitlement.free.offlineTrustWindow, Duration.zero);
    });
  });

  group('clock rollback', () {
    test('a rolled-back clock cannot resurrect a dead subscription', () {
      final expiry = DateTime.utc(2026, 7, 1);
      final verified = DateTime.utc(2026, 6, 25);
      final rolledBack = DateTime.utc(2026, 6, 26);

      final guarded = _plus(
        expiresAt: expiry,
        lastVerifiedAt: verified,
        maxClockSeen: _now,
      );
      expect(guarded.statusAt(rolledBack), EntitlementStatus.lapsed);

      // Without the ceiling the same rollback would read as inside the paid
      // period, which is precisely what the guard is for.
      final unguarded = _plus(expiresAt: expiry, lastVerifiedAt: verified);
      expect(unguarded.statusAt(rolledBack), EntitlementStatus.active);
    });

    test('effectiveNow takes the later of now and the ceiling', () {
      final entitlement = _plus(maxClockSeen: _now);
      final earlier = _now.subtract(const Duration(days: 30));
      final later = _now.add(const Duration(days: 30));

      expect(entitlement.effectiveNow(earlier), _now);
      expect(entitlement.effectiveNow(later), later);
    });

    test(
      'verifiedAt rescues a device whose clock was wrongly in the future',
      () {
        // A bogus future clock was recorded, then corrected. Left alone the user
        // is stranded; a successful Play check must clear it.
        final stranded = _plus(
          expiresAt: DateTime.utc(2026, 9, 1),
          lastVerifiedAt: _now,
          maxClockSeen: DateTime.utc(2027, 1, 1),
        );
        expect(stranded.statusAt(_now), EntitlementStatus.lapsed);

        final recovered = stranded.verifiedAt(_now);
        expect(recovered.maxClockSeen, _now);
        expect(recovered.lastVerifiedAt, _now);
        expect(recovered.statusAt(_now), EntitlementStatus.active);
      },
    );

    test('observedAt raises the ceiling but never lowers it', () {
      final seeded = Entitlement.free.observedAt(_now);
      expect(seeded.maxClockSeen, _now);

      final earlier = seeded.observedAt(_now.subtract(const Duration(days: 1)));
      expect(earlier.maxClockSeen, _now);

      final later = _now.add(const Duration(days: 1));
      expect(seeded.observedAt(later).maxClockSeen, later);
    });
  });

  group('serialisation', () {
    test('round-trips every field', () {
      final original = _plus(
        period: BillingPeriod.yearly,
        expiresAt: _now.add(const Duration(days: 300)),
        lastVerifiedAt: _now,
        maxClockSeen: _now,
      );
      expect(Entitlement.fromJson(original.toJson()), original);
    });

    test('round-trips the free tier', () {
      expect(Entitlement.fromJson(Entitlement.free.toJson()), Entitlement.free);
    });

    test('reads an empty record as free rather than throwing', () {
      final parsed = Entitlement.fromJson(const {});
      expect(parsed.tier, EntitlementTier.free);
      expect(parsed.period, isNull);
      expect(parsed.expiresAt, isNull);
    });

    test('an unknown tier reads as free', () {
      final parsed = Entitlement.fromJson(const {'tier': 'platinum'});
      expect(parsed.tier, EntitlementTier.free);
    });

    test('an unknown billing period reads as null, not a crash', () {
      // A build that predates a future plan name must still start.
      final parsed = Entitlement.fromJson(const {
        'tier': 'plus',
        'period': 'fortnightly',
      });
      expect(parsed.tier, EntitlementTier.plus);
      expect(parsed.period, isNull);
      // Falls back to the floor, not to zero: a paying user must not lapse the
      // instant they go offline just because the plan could not be named.
      expect(parsed.offlineTrustWindow, Entitlement.weeklyTrustWindow);
    });

    test('malformed timestamps read as null', () {
      final parsed = Entitlement.fromJson(const {
        'tier': 'plus',
        'expiresAt': 'not-a-number',
        'lastVerifiedAt': null,
      });
      expect(parsed.expiresAt, isNull);
      expect(parsed.lastVerifiedAt, isNull);
      expect(parsed.statusAt(_now), EntitlementStatus.lapsed);
    });
  });
}
