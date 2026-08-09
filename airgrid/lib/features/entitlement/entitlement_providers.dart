import 'package:airgrid/core/feature_gates.dart';
import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/data/billing/unavailable_billing_service.dart';
import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/services/billing_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Override in main.dart after [SecureEntitlementStore.create()] completes.
///
/// Defaults to an in-memory free-tier store rather than throwing. A forgotten
/// override must fail closed to free, never crash the app, and widget tests get
/// a working store without ceremony.
final entitlementStoreProvider = Provider<EntitlementStore>(
  (ref) => InMemoryEntitlementStore(
    // The one-time Plus notice is a migration message for real installs. The
    // default store is only reached in tests and when an override is missing, so
    // it starts already-seen rather than interrupting every widget test that
    // happens to pump the home screen. Tests that exercise the notice build
    // their own store.
    changeNoticeShownForVersion: SubscriptionCatalog.plusNoticeVersion,
  ),
);

/// Override in main.dart with `PlayBillingService`.
///
/// Defaults to [UnavailableBillingService], which still describes the plans, so
/// a device without Play — or a forgotten override — shows a readable paywall
/// that cannot be purchased from, rather than a crash or a blank screen.
final billingServiceProvider = Provider<BillingService>(
  (ref) => const UnavailableBillingService(),
);

/// The live entitlement, seeded from the store's cache and updated as Play
/// reports renewals, cancellations and late-settling purchases.
final entitlementProvider = NotifierProvider<EntitlementNotifier, Entitlement>(
  EntitlementNotifier.new,
);

class EntitlementNotifier extends Notifier<Entitlement> {
  @override
  Entitlement build() {
    final store = ref.read(entitlementStoreProvider);
    final sub = store.entitlementStream.listen((entitlement) {
      state = entitlement;
    });
    ref.onDispose(sub.cancel);
    return store.current;
  }
}

/// The single thing gate call sites watch.
///
/// Deliberately derived from [entitlementProvider] rather than reading the
/// store directly, so a renewal arriving mid-session rebuilds every gated
/// widget without anything having to remember to refresh.
final featureGatesProvider = Provider<FeatureGates>((ref) {
  return FeatureGates(ref.watch(entitlementProvider));
});
