import 'dart:async';

import 'package:airgrid/core/logger.dart';
import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/services/billing_service.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

/// Google Play implementation of [BillingService].
///
/// **This is the only file in the app permitted to import `in_app_purchase`**,
/// mirroring the rule that `NearbyConnectionsTransport` is the only file
/// importing `nearby_connections`. Everything above [BillingService] stays
/// testable with no Play dependency and no device.
///
/// Deliberately thin. All the logic worth testing lives in
/// [SubscriptionCatalog] and [Entitlement]; what remains here is glue that can
/// only really be exercised on a device against the Play internal testing
/// track.
class PlayBillingService implements BillingService {
  /// How long to wait for Play to replay purchases after a restore.
  ///
  /// On timeout the result is null — "unknown" — never [Entitlement.free], so a
  /// slow or unreachable Play leaves the cached entitlement alone.
  static const Duration restoreTimeout = Duration(seconds: 15);

  /// How long to wait for the Play purchase sheet to reach a terminal state.
  /// Generous: the user may be adding a payment method mid-flow.
  static const Duration purchaseTimeout = Duration(minutes: 5);

  final InAppPurchase _iap;
  final DateTime Function() _clock;
  final _updates = StreamController<Entitlement>.broadcast();

  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  Completer<Entitlement?>? _pendingRestore;
  Completer<PurchaseResult>? _pendingPurchase;

  /// Period of the plan bought in this session, when known.
  ///
  /// Play does not report the base plan back on a purchase, so this is the one
  /// moment the period is knowable without a server.
  BillingPeriod? _periodInFlight;

  PlayBillingService({InAppPurchase? iap, DateTime Function()? clock})
    : _iap = iap ?? InAppPurchase.instance,
      _clock = clock ?? DateTime.now;

  /// Begins listening for purchase updates. Call once at startup.
  ///
  /// Never awaited on a UI path: AirGrid must start and run with Play entirely
  /// unreachable.
  void start() {
    _purchaseSub ??= _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object error) {
        AirGridLogger.log(
          LogCategory.billing,
          'Billing purchase stream error: $error',
        );
        // Resolve anything waiting rather than leaving the UI spinning.
        _completeRestore(null);
        _completePurchase(
          const PurchaseResult(PurchaseOutcome.error, message: 'stream error'),
        );
      },
    );
  }

  @override
  Future<bool> isAvailable() async {
    try {
      return await _iap.isAvailable();
    } on Exception catch (error) {
      AirGridLogger.log(
        LogCategory.billing,
        'Billing availability check failed: $error',
      );
      return false;
    }
  }

  @override
  Future<List<SubscriptionOffer>> loadOffers() async {
    try {
      final response = await _iap.queryProductDetails({
        SubscriptionCatalog.productId,
      });
      if (response.error != null) {
        AirGridLogger.log(
          LogCategory.billing,
          'Billing offer query failed: ${response.error!.message}',
        );
        return SubscriptionCatalog.plansWithoutPrices();
      }

      final offers = <SubscriptionOffer>[];
      for (final details in response.productDetails) {
        final basePlanId = _basePlanIdOf(details);
        if (basePlanId == null) continue;
        final period = SubscriptionCatalog.periodFor(basePlanId);
        // An unrecognised base plan is skipped rather than guessed at, so a
        // newer Play configuration cannot surface a plan this build cannot
        // reason about.
        if (period == null) continue;

        offers.add(
          SubscriptionOffer(
            basePlanId: basePlanId,
            period: period,
            formattedPrice: details.price,
            hasFreeTrial: SubscriptionCatalog.hasFreeTrial(basePlanId),
            isPrepaid: SubscriptionCatalog.isPrepaid(basePlanId),
          ),
        );
      }

      // Play returned nothing usable — a misconfigured Console, or a build not
      // yet on a track. Describe the plans anyway rather than show a dead end.
      if (offers.isEmpty) return SubscriptionCatalog.plansWithoutPrices();

      offers.sort(
        (a, b) => SubscriptionCatalog.displayIndexOf(
          a.basePlanId,
        ).compareTo(SubscriptionCatalog.displayIndexOf(b.basePlanId)),
      );
      return offers;
    } on Exception catch (error) {
      AirGridLogger.log(
        LogCategory.billing,
        'Billing offer query threw: $error',
      );
      return SubscriptionCatalog.plansWithoutPrices();
    }
  }

  @override
  Future<PurchaseResult> purchase(String basePlanId) async {
    final response = await _iap.queryProductDetails({
      SubscriptionCatalog.productId,
    });
    if (response.error != null) {
      return const PurchaseResult(PurchaseOutcome.unavailable);
    }

    ProductDetails? match;
    for (final details in response.productDetails) {
      if (_basePlanIdOf(details) == basePlanId) {
        match = details;
        break;
      }
    }
    if (match == null) {
      return const PurchaseResult(
        PurchaseOutcome.unavailable,
        message: 'base plan not offered',
      );
    }

    _periodInFlight = SubscriptionCatalog.periodFor(basePlanId);
    final pending = _pendingPurchase = Completer<PurchaseResult>();

    try {
      // Subscriptions go through buyNonConsumable. The offer token identifying
      // the base plan is read off the ProductDetails by the Android platform.
      final started = await _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: match),
      );
      if (!started) {
        _pendingPurchase = null;
        return const PurchaseResult(PurchaseOutcome.error);
      }
    } on Exception catch (error) {
      _pendingPurchase = null;
      return PurchaseResult(PurchaseOutcome.error, message: '$error');
    }

    return pending.future.timeout(
      purchaseTimeout,
      onTimeout: () => const PurchaseResult(PurchaseOutcome.pending),
    );
  }

  @override
  Future<Entitlement?> queryEntitlement() async {
    if (!await isAvailable()) return null;

    // Play offers no synchronous "what am I entitled to" call; restorePurchases
    // replays active purchases onto purchaseStream instead.
    final pending = _pendingRestore = Completer<Entitlement?>();
    try {
      await _iap.restorePurchases();
    } on Exception catch (error) {
      AirGridLogger.log(LogCategory.billing, 'Billing restore failed: $error');
      _pendingRestore = null;
      return null;
    }

    return pending.future.timeout(restoreTimeout, onTimeout: () => null);
  }

  @override
  Stream<Entitlement> get entitlementUpdates => _updates.stream;

  @override
  Future<void> dispose() async {
    await _purchaseSub?.cancel();
    _purchaseSub = null;
    await _updates.close();
  }

  /// Resolves the base plan a [ProductDetails] represents.
  ///
  /// A subscription with three base plans yields three [ProductDetails], one
  /// per offer, all sharing the same product ID — so the base plan is the only
  /// thing that distinguishes them, and it is reachable only through the
  /// Android-specific wrapper.
  static String? _basePlanIdOf(ProductDetails details) {
    if (details is! GooglePlayProductDetails) return null;
    final index = details.subscriptionIndex;
    final offers = details.productDetails.subscriptionOfferDetails;
    if (index == null || offers == null || index >= offers.length) return null;
    return offers[index].basePlanId;
  }

  void _onPurchases(List<PurchaseDetails> purchases) {
    Entitlement? entitlement;
    PurchaseResult? outcome;

    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          if (purchase.productID != SubscriptionCatalog.productId) continue;
          entitlement = SubscriptionCatalog.entitlementFor(
            purchaseToken: purchase.purchaseID ?? '',
            verifiedAt: _clock(),
            period: _periodInFlight,
          );
          outcome = PurchaseResult(
            PurchaseOutcome.purchased,
            entitlement: entitlement,
          );
          // Play requires acknowledgement, or it refunds after three days.
          if (purchase.pendingCompletePurchase) {
            unawaited(_iap.completePurchase(purchase));
          }
        case PurchaseStatus.canceled:
          outcome ??= const PurchaseResult(PurchaseOutcome.userCancelled);
        case PurchaseStatus.error:
          AirGridLogger.log(
            LogCategory.billing,
            'Billing purchase error: ${purchase.error}',
          );
          outcome ??= PurchaseResult(
            PurchaseOutcome.error,
            message: purchase.error?.message,
          );
        case PurchaseStatus.pending:
          outcome ??= const PurchaseResult(PurchaseOutcome.pending);
      }
    }

    if (entitlement != null) {
      _updates.add(entitlement);
      _completeRestore(entitlement);
    } else {
      // An empty replay is Play saying "no active subscription", which is real
      // information: the user is on the free tier.
      _completeRestore(Entitlement.free);
    }

    if (outcome != null) _completePurchase(outcome);
  }

  void _completeRestore(Entitlement? result) {
    final pending = _pendingRestore;
    if (pending == null || pending.isCompleted) return;
    _pendingRestore = null;
    pending.complete(result);
  }

  void _completePurchase(PurchaseResult result) {
    final pending = _pendingPurchase;
    if (pending == null || pending.isCompleted) return;
    _pendingPurchase = null;
    pending.complete(result);
  }
}
