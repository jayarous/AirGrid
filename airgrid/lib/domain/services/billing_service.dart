import 'package:airgrid/domain/models/entitlement.dart';

/// A purchasable base plan, as presented on the paywall.
class SubscriptionOffer {
  /// Play base plan identifier.
  final String basePlanId;

  final BillingPeriod period;

  /// Localised, currency-formatted price straight from Play, or **null when
  /// Play could not be reached**.
  ///
  /// Never format prices locally — Play has already formatted for the user's
  /// region, currency and locale, and a locally-invented price would be wrong.
  ///
  /// Null is expected, not exceptional. AirGrid's paywall appears precisely
  /// when someone tries to start a walkie session off-grid, which is exactly
  /// when prices cannot load. The paywall must render the plan without a price
  /// rather than hiding it.
  final String? formattedPrice;

  /// Whether this plan carries an introductory free trial.
  final bool hasFreeTrial;

  /// True for a prepaid plan, which expires instead of auto-renewing.
  ///
  /// Weekly is prepaid on purpose: weekly demand here is event-shaped (a
  /// festival, a hike, a blackout) and that buyer does not want a renewal they
  /// will forget about and then refund.
  final bool isPrepaid;

  const SubscriptionOffer({
    required this.basePlanId,
    required this.period,
    this.formattedPrice,
    this.hasFreeTrial = false,
    this.isPrepaid = false,
  });

  /// Whether Play supplied a real, purchasable price.
  ///
  /// False means the plan can be described but not bought right now.
  bool get isPurchasable => formattedPrice != null;
}

enum PurchaseOutcome {
  purchased,

  /// The user backed out of the Play sheet. Not an error; show nothing.
  userCancelled,

  /// Play accepted the purchase but has not settled it yet (e.g. a slow
  /// payment method). Entitlement arrives later on [BillingService.
  /// entitlementUpdates].
  pending,

  /// Billing is unavailable on this device — no Play Services, or Play is too
  /// old. Distinct from [error] because it is not transient and the paywall
  /// should explain rather than offer a retry.
  unavailable,

  error,
}

class PurchaseResult {
  final PurchaseOutcome outcome;

  /// Present only when [outcome] is [PurchaseOutcome.purchased].
  final Entitlement? entitlement;

  /// Diagnostic detail. Never surfaced verbatim to the user.
  final String? message;

  const PurchaseResult(this.outcome, {this.entitlement, this.message});
}

/// Abstraction over Google Play Billing.
///
/// The only production implementation is `PlayBillingService`, which is the one
/// file permitted to import `in_app_purchase` — mirroring the rule that
/// `NearbyConnectionsTransport` is the only file importing
/// `nearby_connections`. Everything above this interface stays testable with no
/// Play dependency and no device.
///
/// Nothing on this interface may be awaited on a UI-blocking path. AirGrid must
/// start and run with billing entirely unreachable.
abstract class BillingService {
  /// Whether Play Billing can be used on this device at all.
  Future<bool> isAvailable();

  /// The plans to show on the paywall, in display order.
  ///
  /// **Never returns an empty list.** When Play cannot be reached, the plans are
  /// still returned from local configuration with
  /// [SubscriptionOffer.formattedPrice] null, so the paywall always has honest
  /// content to render and can never become a blank screen or hide itself.
  ///
  /// Putting that guarantee here rather than in the UI is deliberate: "the
  /// paywall disappeared because billing was unreachable" is the exact failure
  /// mode an offline-first app must not ship, and a UI-layer convention would be
  /// one refactor away from breaking it.
  Future<List<SubscriptionOffer>> loadOffers();

  Future<PurchaseResult> purchase(String basePlanId);

  /// The entitlement Play currently reports, or **null when it could not be
  /// determined** — offline, Play Services missing, query failed.
  ///
  /// Null is emphatically not [Entitlement.free]. Collapsing the two would
  /// downgrade every offline user, which is the single failure this design
  /// exists to prevent. Callers must treat null as "keep what is cached".
  Future<Entitlement?> queryEntitlement();

  /// Entitlement changes observed after startup — renewals, cancellations, and
  /// purchases that settled late.
  Stream<Entitlement> get entitlementUpdates;

  Future<void> dispose();
}
