import 'package:airgrid/data/billing/unavailable_billing_service.dart';
import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/services/billing_service.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:airgrid/features/paywall/paywall_screen.dart';
import 'package:airgrid/features/paywall/plus_change_notice.dart';
import 'package:flutter/material.dart';
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
    formattedPrice: 'AED 1.99',
    isPrepaid: true,
  ),
  SubscriptionOffer(
    basePlanId: 'yearly',
    period: BillingPeriod.yearly,
    formattedPrice: 'AED 11.99',
    isPrepaid: true,
  ),
];

Future<void> _pumpPaywall(
  WidgetTester tester, {
  required BillingService billing,
  EntitlementStore? store,
}) async {
  // Tall viewport so the whole scrollable paywall is built and findable — the
  // default 800x600 leaves the yearly plan and the retry action off-screen,
  // where a lazy ListView never builds them.
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        billingServiceProvider.overrideWithValue(billing),
        entitlementStoreProvider.overrideWithValue(
          store ??
              InMemoryEntitlementStore(
                clock: () => _now,
                // Default to the change notice already retired, so only the
                // tests that opt in have to reason about the banner.
                changeNoticeShownForVersion: kPlusNoticeVersion,
              ),
        ),
      ],
      child: const MaterialApp(home: PaywallScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('offline paywall', () {
    testWidgets('renders every plan with no prices and no crash', (
      tester,
    ) async {
      // The load-bearing case. AirGrid's paywall appears when someone tries to
      // start a walkie session, which happens off-grid — so this is the common
      // view, not an edge case, and it must never be blank.
      await _pumpPaywall(tester, billing: const UnavailableBillingService());

      expect(find.text('Weekly'), findsOneWidget);
      expect(find.text('Monthly'), findsOneWidget);
      expect(find.text('Yearly'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('explains itself instead of showing a fake price', (
      tester,
    ) async {
      await _pumpPaywall(tester, billing: const UnavailableBillingService());

      expect(find.text('Connect to subscribe'), findsOneWidget);
      expect(find.textContaining('Prices need a connection'), findsOneWidget);
      expect(find.text('Check prices again'), findsOneWidget);
      // No currency invented anywhere on screen.
      expect(find.textContaining('AED'), findsNothing);
      expect(find.textContaining(r'$'), findsNothing);
    });

    testWidgets('still says what stays free', (tester) async {
      // Existing users are gated on update with no grandfathering, so the
      // paywall has to show how much still works without paying.
      await _pumpPaywall(tester, billing: const UnavailableBillingService());

      // Nothing to manage until something has been bought — the row would send
      // a free user to an empty Play subscription list.
      expect(find.text('Manage'), findsNothing);

      expect(find.text('Always free'), findsOneWidget);
      expect(find.text('Public and private chat'), findsOneWidget);
      expect(
        find.textContaining('join a session someone'),
        findsOneWidget,
        reason: 'the accept-side rule has to be visible to the user',
      );
    });
  });

  group('priced paywall', () {
    testWidgets('prices the default selection, and promises no trial', (
      tester,
    ) async {
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(tester, billing: billing);

      expect(find.text('Subscribe — AED 1.99'), findsOneWidget);
      expect(find.text('AED 1.99'), findsOneWidget);
      expect(find.text('Connect to subscribe'), findsNothing);
      expect(find.textContaining('free trial'), findsNothing);
    });

    testWidgets('selecting yearly changes the buy button', (tester) async {
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(tester, billing: billing);
      await tester.tap(find.text('Yearly'));
      await tester.pumpAndSettle();

      expect(find.text('Subscribe — AED 11.99'), findsOneWidget);
    });

    testWidgets('marks every plan as expiring, with its own span', (
      tester,
    ) async {
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(tester, billing: billing);

      // Every plan is prepaid, so each must name the span it actually buys —
      // a single shared string would tell a yearly buyer they get one week.
      expect(find.textContaining('One week, expires'), findsOneWidget);
      expect(find.textContaining('One month, expires'), findsOneWidget);
      expect(find.textContaining('One year, expires'), findsOneWidget);
    });
  });

  group('lapsed subscriber', () {
    testWidgets('is told their subscription ended', (tester) async {
      final lapsed = Entitlement(
        tier: EntitlementTier.plus,
        period: BillingPeriod.monthly,
        purchaseToken: 'token-abc',
        expiresAt: _now.subtract(const Duration(days: 60)),
        lastVerifiedAt: _now.subtract(const Duration(days: 60)),
      );
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(
        tester,
        billing: billing,
        store: InMemoryEntitlementStore(initial: lapsed, clock: () => _now),
      );

      expect(find.text('Your Plus subscription has ended'), findsOneWidget);
    });
  });

  group('active subscriber', () {
    Entitlement activePlus() => Entitlement(
      tier: EntitlementTier.plus,
      period: BillingPeriod.monthly,
      productId: 'airgrid_plus',
      purchaseToken: 'token-abc',
      lastVerifiedAt: _now,
      maxClockSeen: _now,
    );

    testWidgets('is told the subscription is active, not asked to buy', (
      tester,
    ) async {
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(
        tester,
        billing: billing,
        store: InMemoryEntitlementStore(
          initial: activePlus(),
          clock: () => _now,
          changeNoticeShownForVersion: kPlusNoticeVersion,
        ),
      );

      expect(find.text('AirGrid Plus is active'), findsOneWidget);
      expect(find.textContaining('Monthly plan'), findsOneWidget);
    });

    testWidgets('is shown no prices and no way to buy again', (tester) async {
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(
        tester,
        billing: billing,
        store: InMemoryEntitlementStore(
          initial: activePlus(),
          clock: () => _now,
          changeNoticeShownForVersion: kPlusNoticeVersion,
        ),
      );

      // Selling to someone who has already paid is how they conclude the
      // payment failed — which is exactly what happened on device.
      expect(find.text('AED 1.99'), findsNothing);
      expect(find.textContaining('Subscribe'), findsNothing);
      expect(find.text('Weekly'), findsNothing);
      expect(find.text('Yearly'), findsNothing);
    });

    testWidgets('is offered a way to manage the subscription', (tester) async {
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(
        tester,
        billing: billing,
        store: InMemoryEntitlementStore(
          initial: activePlus(),
          clock: () => _now,
          changeNoticeShownForVersion: kPlusNoticeVersion,
        ),
      );

      // Every plan is prepaid and the plan list is hidden while one is running,
      // so this is the only route to topping up before it expires.
      expect(find.text('Manage'), findsOneWidget);
    });

    testWidgets('still sees what Plus unlocks', (tester) async {
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(
        tester,
        billing: billing,
        store: InMemoryEntitlementStore(
          initial: activePlus(),
          clock: () => _now,
          changeNoticeShownForVersion: kPlusNoticeVersion,
        ),
      );

      expect(find.text('Start private walkie sessions'), findsOneWidget);
    });
  });

  group('plus change notice', () {
    /// A device that has run an earlier build: nothing has retired the notice.
    InMemoryEntitlementStore upgraderStore() =>
        InMemoryEntitlementStore(clock: () => _now);

    testWidgets('rides on the paywall, not on the first screen', (
      tester,
    ) async {
      final store = upgraderStore();
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(tester, billing: billing, store: store);

      expect(find.text('Live voice is now AirGrid Plus'), findsOneWidget);
      expect(store.changeNoticeShownForVersion, kPlusNoticeVersion);
    });

    testWidgets('shows once, then never again', (tester) async {
      final store = upgraderStore();
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(tester, billing: billing, store: store);
      expect(find.text('Live voice is now AirGrid Plus'), findsOneWidget);

      // Tear the paywall down before rebuilding it. Pumping PaywallScreen
      // straight over itself reuses the same State, so initState — where the
      // decision is made — would never run a second time and the test would
      // pass on a stale field rather than on the store.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();

      // Second visit to the paywall, same device.
      await _pumpPaywall(tester, billing: billing, store: store);
      expect(find.text('Live voice is now AirGrid Plus'), findsNothing);
    });

    testWidgets('never reaches a device that has already retired it', (
      tester,
    ) async {
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      // What main.dart writes for a fresh install: no earlier build ever ran
      // here, so there is no change to explain.
      await _pumpPaywall(
        tester,
        billing: billing,
        store: InMemoryEntitlementStore(
          clock: () => _now,
          changeNoticeShownForVersion: kPlusNoticeVersion,
        ),
      );

      expect(find.text('Live voice is now AirGrid Plus'), findsNothing);
    });

    testWidgets('names what is still free and promises no trial', (
      tester,
    ) async {
      final billing = FakeBillingService()..offers = _pricedOffers();
      addTearDown(billing.dispose);

      await _pumpPaywall(tester, billing: billing, store: upgraderStore());

      expect(find.textContaining('Chat, voice notes, images'), findsOneWidget);
      expect(
        find.textContaining('join a walkie session someone'),
        findsOneWidget,
      );
      // No plan carries a trial. Claiming one in the copy would be a false
      // billing promise, which is exactly what Play polices hardest.
      expect(find.textContaining('free trial'), findsNothing);
    });
  });
}
