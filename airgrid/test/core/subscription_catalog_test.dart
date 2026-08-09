import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/services/billing_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 8, 9, 12);

void main() {
  group('base plan identity', () {
    test('maps each base plan to its period', () {
      expect(
        SubscriptionCatalog.periodFor(SubscriptionCatalog.weeklyBasePlanId),
        BillingPeriod.weekly,
      );
      expect(
        SubscriptionCatalog.periodFor(SubscriptionCatalog.monthlyBasePlanId),
        BillingPeriod.monthly,
      );
      expect(
        SubscriptionCatalog.periodFor(SubscriptionCatalog.yearlyBasePlanId),
        BillingPeriod.yearly,
      );
    });

    test('an unrecognised base plan maps to null, not a guess', () {
      expect(SubscriptionCatalog.periodFor('fortnightly'), isNull);
      expect(SubscriptionCatalog.periodFor(''), isNull);
    });

    group('manage-subscription deep link', () {
      test('carries the product ID, never a base plan ID', () {
        // Play resolves `sku` against products. Passing the base plan the user
        // actually bought finds nothing and drops them on the generic list.
        final uri = SubscriptionCatalog.manageSubscriptionUri(
          packageName: 'com.airgrid.app',
        );

        expect(uri.queryParameters['sku'], SubscriptionCatalog.productId);
        for (final basePlanId in SubscriptionCatalog.displayOrder) {
          expect(
            uri.queryParameters['sku'],
            isNot(basePlanId),
            reason: '$basePlanId is a base plan, not a product',
          );
        }
      });

      test('uses the package name it is given, not a hardcoded one', () {
        final uri = SubscriptionCatalog.manageSubscriptionUri(
          packageName: 'com.example.flavour',
        );

        expect(uri.queryParameters['package'], 'com.example.flavour');
      });

      test('points at the Play subscription centre over https', () {
        final uri = SubscriptionCatalog.manageSubscriptionUri(
          packageName: 'com.airgrid.app',
        );

        // https matters beyond correctness: the scheme has to match the
        // <queries> entry in AndroidManifest.xml or canLaunchUrl says false.
        expect(uri.scheme, 'https');
        expect(uri.host, 'play.google.com');
        expect(uri.path, '/store/account/subscriptions');
      });
    });

    test('every period has exactly one base plan', () {
      final covered = SubscriptionCatalog.displayOrder
          .map(SubscriptionCatalog.periodFor)
          .toSet();
      expect(covered, BillingPeriod.values.toSet());
    });

    test('base plan IDs are Play-legal', () {
      // Play is stricter about base plan IDs than product IDs: lowercase
      // letters, digits and hyphens only — no underscores.
      final legal = RegExp(r'^[a-z0-9-]+$');
      for (final id in SubscriptionCatalog.displayOrder) {
        expect(legal.hasMatch(id), isTrue, reason: '"$id" is not Play-legal');
      }
    });
  });

  group('plan shape', () {
    test('every plan is prepaid', () {
      for (final basePlanId in SubscriptionCatalog.displayOrder) {
        expect(
          SubscriptionCatalog.isPrepaid(basePlanId),
          isTrue,
          reason:
              '$basePlanId must expire rather than auto-renew — someone on a '
              'hike or in a blackout cannot cancel a renewal they forgot',
        );
      }
    });

    test('no plan carries a free trial', () {
      for (final basePlanId in SubscriptionCatalog.displayOrder) {
        expect(SubscriptionCatalog.hasFreeTrial(basePlanId), isFalse);
      }
    });

    test('display order runs shortest to longest', () {
      expect(SubscriptionCatalog.displayOrder, [
        SubscriptionCatalog.weeklyBasePlanId,
        SubscriptionCatalog.monthlyBasePlanId,
        SubscriptionCatalog.yearlyBasePlanId,
      ]);
    });

    test('an unknown plan sorts last rather than first', () {
      expect(
        SubscriptionCatalog.displayIndexOf('mystery'),
        greaterThan(
          SubscriptionCatalog.displayIndexOf(
            SubscriptionCatalog.yearlyBasePlanId,
          ),
        ),
      );
    });
  });

  group('plansWithoutPrices', () {
    // The paywall appears when someone tries to start a walkie session, which
    // happens off-grid — so "Play unreachable" is the common paywall state, not
    // an edge case. It must never render as a blank screen.

    test('describes every plan even with no prices', () {
      final plans = SubscriptionCatalog.plansWithoutPrices();

      expect(plans, hasLength(BillingPeriod.values.length));
      expect(plans.map((p) => p.period).toSet(), BillingPeriod.values.toSet());
      for (final plan in plans) {
        expect(plan.formattedPrice, isNull);
        expect(plan.isPurchasable, isFalse);
      }
    });

    test('keeps display order and plan shape', () {
      final plans = SubscriptionCatalog.plansWithoutPrices();

      expect(
        plans.map((p) => p.basePlanId).toList(),
        SubscriptionCatalog.displayOrder,
      );
      for (final plan in plans) {
        expect(
          plan.isPrepaid,
          isTrue,
          reason:
              'the paywall must still say ${plan.basePlanId} expires when it '
              'cannot show a price',
        );
        expect(plan.hasFreeTrial, isFalse);
      }
    });

    test('is never empty', () {
      expect(SubscriptionCatalog.plansWithoutPrices(), isNotEmpty);
    });
  });

  group('SubscriptionOffer.isPurchasable', () {
    test('is true only when Play supplied a price', () {
      const priced = SubscriptionOffer(
        basePlanId: 'monthly',
        period: BillingPeriod.monthly,
        formattedPrice: 'AED 10.99',
      );
      const unpriced = SubscriptionOffer(
        basePlanId: 'monthly',
        period: BillingPeriod.monthly,
      );

      expect(priced.isPurchasable, isTrue);
      expect(unpriced.isPurchasable, isFalse);
    });
  });

  group('entitlementFor', () {
    test('grants plus and stamps the verification', () {
      final entitlement = SubscriptionCatalog.entitlementFor(
        purchaseToken: 'token-abc',
        verifiedAt: _now,
        period: BillingPeriod.monthly,
      );

      expect(entitlement.tier, EntitlementTier.plus);
      expect(entitlement.period, BillingPeriod.monthly);
      expect(entitlement.productId, SubscriptionCatalog.productId);
      expect(entitlement.purchaseToken, 'token-abc');
      expect(entitlement.lastVerifiedAt, _now);
      expect(entitlement.maxClockSeen, _now);
      expect(entitlement.isPlusAt(_now), isTrue);
    });

    test('leaves expiry null because Play never supplies it', () {
      final entitlement = SubscriptionCatalog.entitlementFor(
        purchaseToken: 'token-abc',
        verifiedAt: _now,
        period: BillingPeriod.monthly,
      );
      expect(entitlement.expiresAt, isNull);
      // Freshly confirmed, so still active despite having no expiry date.
      expect(entitlement.statusAt(_now), EntitlementStatus.active);
    });

    test('an unknown period still yields a usable entitlement', () {
      // The restore-after-reinstall case: Play confirms a purchase but cannot
      // say which base plan it was.
      final entitlement = SubscriptionCatalog.entitlementFor(
        purchaseToken: 'token-abc',
        verifiedAt: _now,
      );

      expect(entitlement.period, isNull);
      expect(entitlement.isPlusAt(_now), isTrue);
      expect(entitlement.offlineTrustWindow, Entitlement.weeklyTrustWindow);
    });
  });
}
