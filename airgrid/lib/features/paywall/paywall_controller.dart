import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/services/billing_service.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the paywall is showing.
class PaywallState {
  /// The plans to render. **Never empty**, so the paywall can never be blank.
  ///
  /// Seeded from local configuration before Play is even asked, then replaced
  /// with priced plans if Play answers. See [SubscriptionOffer.formattedPrice] —
  /// null there means "describable but not buyable right now".
  final List<SubscriptionOffer> offers;

  /// Base plan the user has selected.
  final String selectedBasePlanId;

  /// True while prices are being fetched. Never blocks rendering.
  final bool isLoadingPrices;

  /// Base plan currently being bought, if any.
  final String? purchasingBasePlanId;

  /// User-facing message — a failure explanation or a pending-purchase note.
  final String? message;

  const PaywallState({
    required this.offers,
    required this.selectedBasePlanId,
    this.isLoadingPrices = false,
    this.purchasingBasePlanId,
    this.message,
  });

  /// The starting state: plans described from local knowledge, no prices yet.
  ///
  /// Deliberately not an "empty" or "loading" state. The paywall has something
  /// honest to show from the first frame, and never has a moment where it could
  /// render as nothing.
  factory PaywallState.initial() => PaywallState(
    offers: SubscriptionCatalog.plansWithoutPrices(),
    selectedBasePlanId: SubscriptionCatalog.monthlyBasePlanId,
    isLoadingPrices: true,
  );

  bool get isPurchasing => purchasingBasePlanId != null;

  SubscriptionOffer get selectedOffer => offers.firstWhere(
    (offer) => offer.basePlanId == selectedBasePlanId,
    orElse: () => offers.first,
  );

  /// Whether anything at all can be bought right now.
  ///
  /// False offline. The paywall stays fully readable in that state; only the buy
  /// button goes quiet.
  bool get canPurchase => offers.any((offer) => offer.isPurchasable);

  PaywallState copyWith({
    List<SubscriptionOffer>? offers,
    String? selectedBasePlanId,
    bool? isLoadingPrices,
    String? purchasingBasePlanId,
    bool clearPurchasing = false,
    String? message,
    bool clearMessage = false,
  }) {
    return PaywallState(
      offers: offers ?? this.offers,
      selectedBasePlanId: selectedBasePlanId ?? this.selectedBasePlanId,
      isLoadingPrices: isLoadingPrices ?? this.isLoadingPrices,
      purchasingBasePlanId: clearPurchasing
          ? null
          : purchasingBasePlanId ?? this.purchasingBasePlanId,
      message: clearMessage ? null : message ?? this.message,
    );
  }
}

final paywallControllerProvider =
    NotifierProvider<PaywallController, PaywallState>(PaywallController.new);

class PaywallController extends Notifier<PaywallState> {
  @override
  PaywallState build() => PaywallState.initial();

  BillingService get _billing => ref.read(billingServiceProvider);
  EntitlementStore get _store => ref.read(entitlementStoreProvider);

  /// Fetches prices. Safe to call again as a retry.
  ///
  /// Never gates rendering: the plans are already on screen, and this only fills
  /// in prices. A failure leaves the descriptions in place.
  Future<void> loadPrices() async {
    state = state.copyWith(isLoadingPrices: true, clearMessage: true);

    final loaded = await _billing.loadOffers();
    // loadOffers is contractually non-empty, but belt and braces: never let a
    // future implementation empty the paywall.
    final offers = loaded.isEmpty ? state.offers : loaded;
    final anyPurchasable = offers.any((offer) => offer.isPurchasable);

    state = state.copyWith(
      offers: offers,
      isLoadingPrices: false,
      clearMessage: anyPurchasable,
      message: anyPurchasable
          ? null
          : 'Prices need a connection. You can still read what Plus includes.',
    );
  }

  void select(String basePlanId) {
    state = state.copyWith(selectedBasePlanId: basePlanId, clearMessage: true);
  }

  /// Buys the selected plan. Returns true when Plus is active afterwards.
  Future<bool> purchaseSelected() async {
    final offer = state.selectedOffer;
    if (!offer.isPurchasable || state.isPurchasing) return false;

    state = state.copyWith(
      purchasingBasePlanId: offer.basePlanId,
      clearMessage: true,
    );

    final result = await _billing.purchase(offer.basePlanId);

    switch (result.outcome) {
      case PurchaseOutcome.purchased:
        final granted = result.entitlement;
        if (granted != null) {
          // Route through the store so the cached entitlement, the rollback
          // ceiling and every gate update from one place.
          await _store.reconcile(granted);
        }
        state = state.copyWith(clearPurchasing: true, clearMessage: true);
        return true;

      case PurchaseOutcome.userCancelled:
        // Not an error. Say nothing.
        state = state.copyWith(clearPurchasing: true, clearMessage: true);
        return false;

      case PurchaseOutcome.pending:
        state = state.copyWith(
          clearPurchasing: true,
          message:
              'Google Play is still confirming your payment. Plus unlocks as '
              'soon as it clears.',
        );
        return false;

      case PurchaseOutcome.unavailable:
        state = state.copyWith(
          clearPurchasing: true,
          message:
              'Google Play is not available on this device, so Plus cannot be '
              'purchased here.',
        );
        return false;

      case PurchaseOutcome.error:
        state = state.copyWith(
          clearPurchasing: true,
          message: 'That did not go through. Nothing was charged.',
        );
        return false;
    }
  }

  /// Re-checks an existing subscription, for the "already subscribed" path.
  Future<bool> restore() async {
    state = state.copyWith(isLoadingPrices: true, clearMessage: true);
    final fromPlay = await _billing.queryEntitlement();
    final result = await _store.reconcile(fromPlay);
    final restored = result.tier == EntitlementTier.plus;

    final String? message;
    if (restored) {
      message = null;
    } else if (fromPlay == null) {
      // Unknown, not "no subscription" — say so, and leave the cache alone.
      message =
          'Could not reach Google Play. Your existing access is unchanged.';
    } else {
      message = 'No subscription found on this Google account.';
    }

    state = state.copyWith(
      isLoadingPrices: false,
      clearMessage: restored,
      message: message,
    );
    return restored;
  }
}
