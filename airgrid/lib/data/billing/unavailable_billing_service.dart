import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/services/billing_service.dart';

/// Billing that cannot be used on this device.
///
/// Not a test double — a real case. A device with no Play Services, or one where
/// Play is simply unreachable, still has to show a paywall that explains what
/// Plus is. It just cannot sell it.
///
/// Also the safe default for `billingServiceProvider`, so a missing override
/// degrades to "cannot buy right now" rather than crashing the app.
class UnavailableBillingService implements BillingService {
  const UnavailableBillingService();

  @override
  Future<bool> isAvailable() async => false;

  /// Still describes the plans — the paywall must never render blank.
  @override
  Future<List<SubscriptionOffer>> loadOffers() async =>
      SubscriptionCatalog.plansWithoutPrices();

  @override
  Future<PurchaseResult> purchase(String basePlanId) async =>
      const PurchaseResult(PurchaseOutcome.unavailable);

  /// Null, never [Entitlement.free]: "cannot tell" must not downgrade anyone.
  @override
  Future<Entitlement?> queryEntitlement() async => null;

  @override
  Stream<Entitlement> get entitlementUpdates => const Stream.empty();

  @override
  Future<void> dispose() async {}
}
