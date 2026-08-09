import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/services/billing_service.dart';

/// The AirGrid Plus product layout, and the pure logic for turning a Play
/// purchase into an [Entitlement].
///
/// **One subscription product with three base plans, not three products.** Play
/// then handles switching between periods itself — proration, upgrade,
/// downgrade. Three separate products would mean hand-writing all of that.
///
/// Whether a plan is prepaid or carries a trial is configured *here* rather
/// than read back from Play. Those are decisions made in the Play Console, so
/// reading them back would be a round trip to learn something already known,
/// and one more thing to break.
class SubscriptionCatalog {
  SubscriptionCatalog._();

  /// Play subscription product ID.
  static const String productId = 'airgrid_plus';

  /// Marker for the release that introduced AirGrid Plus.
  ///
  /// Not the running app version: this identifies the *notice*, so shipping a
  /// later version does not show it again. Lives here rather than beside the
  /// notice widget so the entitlement providers can reference it without
  /// importing the paywall UI.
  static const String plusNoticeVersion = 'plus-1';

  /// Base plan IDs.
  ///
  /// Kept to bare lowercase words: Play is stricter about base plan IDs than
  /// about product IDs (no underscores), so `airgrid_plus_weekly` would be
  /// rejected as a base plan ID even though it is fine as a product ID.
  static const String weeklyBasePlanId = 'weekly';
  static const String monthlyBasePlanId = 'monthly';
  static const String yearlyBasePlanId = 'yearly';

  static const Map<String, BillingPeriod> _periodByBasePlanId = {
    weeklyBasePlanId: BillingPeriod.weekly,
    monthlyBasePlanId: BillingPeriod.monthly,
    yearlyBasePlanId: BillingPeriod.yearly,
  };

  /// All plans are prepaid and expire instead of auto-renewing.
  ///
  /// This matches AirGrid's offline-first ethos: users on hikes, blackouts, or
  /// festivals won't get surprised by recurring charges they can't manage
  /// without internet. Prepaid is simpler to explain and reduces refund requests
  /// from forgotten renewals.
  static const Set<String> _prepaidBasePlanIds = {
    weeklyBasePlanId,
    monthlyBasePlanId,
    yearlyBasePlanId,
  };

  /// No plans carry free trials — all are prepaid with clear expiry dates.
  static const Set<String> _trialBasePlanIds = {};

  /// Display order on the paywall.
  static const List<String> displayOrder = [
    weeklyBasePlanId,
    monthlyBasePlanId,
    yearlyBasePlanId,
  ];

  /// Deep link to the Play subscription centre, where a prepaid plan is topped
  /// up and payment methods are managed.
  ///
  /// **`sku` is the subscription product ID, not a base plan ID.** Play resolves
  /// this parameter against products; passing `weekly` or `monthly` — the base
  /// plan the user actually bought — silently fails to find anything and drops
  /// them on the generic subscription list. That distinction is the reason this
  /// lives beside [productId] rather than being assembled at the call site.
  ///
  /// [packageName] is passed in rather than hardcoded so it can come from
  /// `PackageInfo.fromPlatform()`. A build flavour or an application ID rename
  /// would otherwise leave a link that points at an app that does not exist.
  static Uri manageSubscriptionUri({required String packageName}) {
    return Uri.parse(
      'https://play.google.com/store/account/subscriptions'
      '?sku=$productId&package=$packageName',
    );
  }

  /// Null for an unrecognised base plan — a newer Play configuration must not
  /// crash an older build.
  static BillingPeriod? periodFor(String basePlanId) =>
      _periodByBasePlanId[basePlanId];

  static bool isPrepaid(String basePlanId) =>
      _prepaidBasePlanIds.contains(basePlanId);

  static bool hasFreeTrial(String basePlanId) =>
      _trialBasePlanIds.contains(basePlanId);

  static int displayIndexOf(String basePlanId) {
    final index = displayOrder.indexOf(basePlanId);
    return index < 0 ? displayOrder.length : index;
  }

  /// The plans as this build knows them, with no prices.
  ///
  /// What the paywall shows when Play cannot be reached — which for AirGrid is
  /// the *common* case, not the edge case: the paywall appears when someone
  /// tries to start a walkie session, and that happens off-grid.
  ///
  /// Everything except the price is local knowledge, so the paywall can still
  /// explain what Plus is, which plans exist and which one carries the trial. It
  /// simply cannot say what they cost, and must say so rather than guessing or
  /// showing nothing.
  static List<SubscriptionOffer> plansWithoutPrices() {
    return [
      for (final basePlanId in displayOrder)
        SubscriptionOffer(
          basePlanId: basePlanId,
          period: periodFor(basePlanId)!,
          hasFreeTrial: hasFreeTrial(basePlanId),
          isPrepaid: isPrepaid(basePlanId),
        ),
    ];
  }

  /// Builds the entitlement that a Play-confirmed active purchase implies.
  ///
  /// Two things the Android client genuinely cannot know, both of which are
  /// what Phase 7's server verification exists to supply:
  ///
  /// **No expiry.** `PurchaseDetails` carries no expiry date; only the Play
  /// Developer API does. [Entitlement.expiresAt] is therefore left null, and
  /// the offline trust window does the work instead. Play only returns
  /// *currently active* subscriptions from a purchase query, so a purchase
  /// being present is itself the proof of "active right now".
  ///
  /// **No base plan.** `PurchaseDetails` does not say which base plan was
  /// bought, so a restore after reinstall cannot tell weekly from yearly. Pass
  /// [period] when it is known — at purchase time, or from the cached
  /// entitlement — and leave it null otherwise; [Entitlement.offlineTrustWindow]
  /// falls back to the seven-day floor, which under-grants rather than over-grants.
  static Entitlement entitlementFor({
    required String purchaseToken,
    required DateTime verifiedAt,
    BillingPeriod? period,
  }) {
    return Entitlement(
      tier: EntitlementTier.plus,
      period: period,
      productId: productId,
      purchaseToken: purchaseToken,
      lastVerifiedAt: verifiedAt,
      maxClockSeen: verifiedAt,
    );
  }
}
