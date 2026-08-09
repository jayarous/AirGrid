import 'dart:async';

import 'package:airgrid/core/foreground_service_bridge.dart';
import 'package:airgrid/core/play_services_bridge.dart';
import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/services/billing_service.dart';

class FakePlayServices implements PlayServicesAvailability {
  PlayServicesStatus status;

  FakePlayServices(this.status);

  @override
  Future<PlayServicesStatus> checkAvailability() async => status;

  @override
  Future<bool> resolve(PlayServicesStatus status) async => status.canResolve;
}

class FakeForegroundService implements MeshForegroundService {
  final _exitController = StreamController<void>.broadcast();
  final _riderMuteController = StreamController<void>.broadcast();
  final _riderEndController = StreamController<void>.broadcast();
  int startCount = 0;
  int stopCount = 0;
  int riderStartCount = 0;
  int riderStopCount = 0;
  bool riderMuted = false;

  @override
  Stream<void> get exitRequests => _exitController.stream;

  @override
  Stream<void> get riderMuteRequests => _riderMuteController.stream;

  @override
  Stream<void> get riderEndRequests => _riderEndController.stream;

  @override
  Future<bool> consumePendingExitAction() async => false;

  @override
  Future<PrivateMessageNotificationTap?>
  consumePendingPrivateMessageTap() async => null;

  @override
  Stream<PrivateMessageNotificationTap> get privateMessageNotificationTaps =>
      const Stream.empty();

  @override
  Future<void> showPrivateMessageNotification({
    required String peerNodeId,
    required String senderName,
  }) async {}

  @override
  Future<void> startMeshService() async {
    startCount++;
  }

  @override
  Future<void> startRiderService({
    required String peerName,
    required bool muted,
  }) async {
    riderStartCount++;
    riderMuted = muted;
  }

  @override
  Future<void> updateRiderServiceMuted(bool muted) async {
    riderMuted = muted;
  }

  @override
  Future<void> stopMeshService() async {
    stopCount++;
  }

  @override
  Future<void> stopRiderService() async {
    riderStopCount++;
  }

  Future<void> dispose() async {
    await _exitController.close();
    await _riderMuteController.close();
    await _riderEndController.close();
  }
}

/// An active Plus entitlement for tests whose subject is not the paywall.
///
/// Far-future expiry so it cannot lapse mid-suite on a slow machine.
Entitlement plusTestEntitlement() => Entitlement(
  tier: EntitlementTier.plus,
  period: BillingPeriod.monthly,
  productId: SubscriptionCatalog.productId,
  purchaseToken: 'test-token',
  expiresAt: DateTime.utc(2999),
  lastVerifiedAt: DateTime.utc(2999),
);

/// In-memory [BillingService] so nothing above the billing boundary needs Play.
///
/// Defaults are deliberately hostile: billing available but reporting no
/// subscription, which is the state most likely to expose a gate that fails
/// open.
class FakeBillingService implements BillingService {
  final _updates = StreamController<Entitlement>.broadcast();

  bool available = true;

  /// Defaults to priced-less plans, matching the contract that a real
  /// [BillingService] never hands back an empty list. Set explicitly to
  /// simulate Play answering with real prices.
  List<SubscriptionOffer> offers = SubscriptionCatalog.plansWithoutPrices();

  /// What [queryEntitlement] returns. Null means "could not determine" — the
  /// offline case — and must never be read as free.
  Entitlement? reportedEntitlement = Entitlement.free;

  /// Result handed back by [purchase].
  PurchaseResult purchaseResult = const PurchaseResult(
    PurchaseOutcome.userCancelled,
  );

  int queryCount = 0;
  int purchaseCount = 0;
  final purchasedPlanIds = <String>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<SubscriptionOffer>> loadOffers() async => offers;

  @override
  Future<PurchaseResult> purchase(String basePlanId) async {
    purchaseCount++;
    purchasedPlanIds.add(basePlanId);
    final result = purchaseResult;
    final granted = result.entitlement;
    if (result.outcome == PurchaseOutcome.purchased && granted != null) {
      reportedEntitlement = granted;
      _updates.add(granted);
    }
    return result;
  }

  @override
  Future<Entitlement?> queryEntitlement() async {
    queryCount++;
    return reportedEntitlement;
  }

  @override
  Stream<Entitlement> get entitlementUpdates => _updates.stream;

  /// Pushes an out-of-band change, as a renewal or cancellation would.
  void emit(Entitlement entitlement) {
    reportedEntitlement = entitlement;
    _updates.add(entitlement);
  }

  @override
  Future<void> dispose() async {
    await _updates.close();
  }
}
