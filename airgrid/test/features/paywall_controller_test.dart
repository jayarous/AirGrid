import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/data/billing/unavailable_billing_service.dart';
import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/services/billing_service.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:airgrid/features/paywall/paywall_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_services.dart';

final _now = DateTime.utc(2026, 8, 9, 12);

List<SubscriptionOffer> _pricedOffers() => const [
  SubscriptionOffer(
    basePlanId: 'weekly',
    period: BillingPeriod.weekly,
    formattedPrice: 'AED 3.99',
    isPrepaid: true,
  ),
  SubscriptionOffer(
    basePlanId: 'monthly',
    period: BillingPeriod.monthly,
    formattedPrice: 'AED 10.99',
    hasFreeTrial: true,
  ),
  SubscriptionOffer(
    basePlanId: 'yearly',
    period: BillingPeriod.yearly,
    formattedPrice: 'AED 74.99',
  ),
];

({
  ProviderContainer container,
  FakeBillingService billing,
  EntitlementStore store,
})
_harness({Entitlement initial = Entitlement.free}) {
  final billing = FakeBillingService();
  final store = InMemoryEntitlementStore(initial: initial, clock: () => _now);
  final container = ProviderContainer(
    overrides: [
      billingServiceProvider.overrideWithValue(billing),
      entitlementStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(billing.dispose);
  return (container: container, billing: billing, store: store);
}

void main() {
  group('initial state', () {
    test('describes every plan before Play is even asked', () {
      // The paywall has content from the first frame. There is no empty or
      // loading-only state it could render as nothing.
      final state = PaywallState.initial();

      expect(state.offers, hasLength(3));
      expect(state.canPurchase, isFalse);
      expect(state.isLoadingPrices, isTrue);
      expect(state.selectedBasePlanId, SubscriptionCatalog.monthlyBasePlanId);
    });

    test('defaults the selection to monthly', () {
      final state = PaywallState.initial();
      expect(state.selectedOffer.period, BillingPeriod.monthly);
      expect(state.selectedOffer.isPrepaid, isTrue);
    });
  });

  group('offline', () {
    test('still lists all three plans, with no prices', () async {
      final h = _harness();
      h.billing.offers = SubscriptionCatalog.plansWithoutPrices();

      await h.container.read(paywallControllerProvider.notifier).loadPrices();
      final state = h.container.read(paywallControllerProvider);

      expect(state.offers, hasLength(3));
      expect(state.canPurchase, isFalse);
      expect(state.message, isNotNull, reason: 'must explain, not just fail');
      for (final offer in state.offers) {
        expect(offer.formattedPrice, isNull);
      }
    });

    test(
      'never empties the paywall, even if the service returns nothing',
      () async {
        // Guards against a future BillingService breaking the non-empty contract.
        final h = _harness();
        h.billing.offers = const [];

        await h.container.read(paywallControllerProvider.notifier).loadPrices();

        expect(h.container.read(paywallControllerProvider).offers, isNotEmpty);
      },
    );

    test('refuses to purchase without a price rather than guessing', () async {
      final h = _harness();
      h.billing.offers = SubscriptionCatalog.plansWithoutPrices();
      await h.container.read(paywallControllerProvider.notifier).loadPrices();

      final ok = await h.container
          .read(paywallControllerProvider.notifier)
          .purchaseSelected();

      expect(ok, isFalse);
      expect(h.billing.purchaseCount, 0, reason: 'no price, no purchase call');
    });

    test('UnavailableBillingService still yields a readable paywall', () async {
      final store = InMemoryEntitlementStore(clock: () => _now);
      final container = ProviderContainer(
        overrides: [
          billingServiceProvider.overrideWithValue(
            const UnavailableBillingService(),
          ),
          entitlementStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);

      await container.read(paywallControllerProvider.notifier).loadPrices();
      final state = container.read(paywallControllerProvider);

      expect(state.offers, hasLength(3));
      expect(state.canPurchase, isFalse);
    });

    test('a retry after coming online fills in prices', () async {
      final h = _harness();
      h.billing.offers = SubscriptionCatalog.plansWithoutPrices();
      final controller = h.container.read(paywallControllerProvider.notifier);

      await controller.loadPrices();
      expect(h.container.read(paywallControllerProvider).canPurchase, isFalse);

      h.billing.offers = _pricedOffers();
      await controller.loadPrices();

      final state = h.container.read(paywallControllerProvider);
      expect(state.canPurchase, isTrue);
      expect(state.message, isNull);
      expect(state.selectedOffer.formattedPrice, 'AED 10.99');
    });
  });

  group('purchase', () {
    test('grants plus through the store on success', () async {
      final h = _harness();
      h.billing.offers = _pricedOffers();
      final granted = SubscriptionCatalog.entitlementFor(
        purchaseToken: 'token-abc',
        verifiedAt: _now,
        period: BillingPeriod.monthly,
      );
      h.billing.purchaseResult = PurchaseResult(
        PurchaseOutcome.purchased,
        entitlement: granted,
      );

      final controller = h.container.read(paywallControllerProvider.notifier);
      await controller.loadPrices();
      final ok = await controller.purchaseSelected();

      expect(ok, isTrue);
      expect(h.billing.purchasedPlanIds, ['monthly']);
      expect(h.store.current.tier, EntitlementTier.plus);
      expect(h.store.current.period, BillingPeriod.monthly);
      expect(h.container.read(paywallControllerProvider).isPurchasing, isFalse);
    });

    test('buys the plan the user selected, not the default', () async {
      final h = _harness();
      h.billing.offers = _pricedOffers();
      h.billing.purchaseResult = const PurchaseResult(
        PurchaseOutcome.userCancelled,
      );

      final controller = h.container.read(paywallControllerProvider.notifier);
      await controller.loadPrices();
      controller.select('yearly');
      await controller.purchaseSelected();

      expect(h.billing.purchasedPlanIds, ['yearly']);
    });

    test('a cancellation says nothing — it is not an error', () async {
      final h = _harness();
      h.billing.offers = _pricedOffers();
      h.billing.purchaseResult = const PurchaseResult(
        PurchaseOutcome.userCancelled,
      );

      final controller = h.container.read(paywallControllerProvider.notifier);
      await controller.loadPrices();
      final ok = await controller.purchaseSelected();

      expect(ok, isFalse);
      expect(h.container.read(paywallControllerProvider).message, isNull);
    });

    test('a pending payment explains itself and grants nothing yet', () async {
      final h = _harness();
      h.billing.offers = _pricedOffers();
      h.billing.purchaseResult = const PurchaseResult(PurchaseOutcome.pending);

      final controller = h.container.read(paywallControllerProvider.notifier);
      await controller.loadPrices();
      final ok = await controller.purchaseSelected();

      expect(ok, isFalse);
      expect(
        h.container.read(paywallControllerProvider).message,
        contains('still confirming'),
      );
      expect(h.store.current.tier, EntitlementTier.free);
    });

    test('an error reassures that nothing was charged', () async {
      final h = _harness();
      h.billing.offers = _pricedOffers();
      h.billing.purchaseResult = const PurchaseResult(PurchaseOutcome.error);

      final controller = h.container.read(paywallControllerProvider.notifier);
      await controller.loadPrices();
      await controller.purchaseSelected();

      expect(
        h.container.read(paywallControllerProvider).message,
        contains('Nothing was charged'),
      );
      expect(h.store.current.tier, EntitlementTier.free);
    });
  });

  group('restore', () {
    test('recovers an existing subscription', () async {
      final h = _harness();
      h.billing.reportedEntitlement = SubscriptionCatalog.entitlementFor(
        purchaseToken: 'token-abc',
        verifiedAt: _now,
      );

      final restored = await h.container
          .read(paywallControllerProvider.notifier)
          .restore();

      expect(restored, isTrue);
      expect(h.store.current.tier, EntitlementTier.plus);
    });

    test('an unreachable Play leaves existing access untouched', () async {
      // Null means unknown. A paying user offline must not be downgraded by
      // tapping Restore.
      final paid = SubscriptionCatalog.entitlementFor(
        purchaseToken: 'token-abc',
        verifiedAt: _now,
        period: BillingPeriod.monthly,
      );
      final h = _harness(initial: paid);
      h.billing.reportedEntitlement = null;

      final restored = await h.container
          .read(paywallControllerProvider.notifier)
          .restore();

      expect(restored, isTrue, reason: 'cached plus survives');
      expect(h.store.current.tier, EntitlementTier.plus);
    });

    test('reports honestly when no subscription exists', () async {
      final h = _harness();
      h.billing.reportedEntitlement = Entitlement.free;

      final restored = await h.container
          .read(paywallControllerProvider.notifier)
          .restore();

      expect(restored, isFalse);
      expect(
        h.container.read(paywallControllerProvider).message,
        contains('No subscription found'),
      );
    });
  });
}
