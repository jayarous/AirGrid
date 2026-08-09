import 'dart:convert';

import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 8, 9, 12);

Entitlement _plus({
  BillingPeriod period = BillingPeriod.monthly,
  DateTime? expiresAt,
  DateTime? lastVerifiedAt,
  DateTime? maxClockSeen,
}) => Entitlement(
  tier: EntitlementTier.plus,
  period: period,
  productId: 'airgrid_plus',
  purchaseToken: 'token-abc',
  expiresAt: expiresAt ?? _now.add(const Duration(days: 20)),
  lastVerifiedAt: lastVerifiedAt,
  maxClockSeen: maxClockSeen,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InMemoryEntitlementStore', () {
    test('starts free and emits on save', () async {
      final store = InMemoryEntitlementStore(clock: () => _now);
      expect(store.current, Entitlement.free);

      final seen = <Entitlement>[];
      store.entitlementStream.listen(seen.add);

      final granted = _plus(lastVerifiedAt: _now);
      await store.save(granted);

      expect(store.current, granted);
      await pumpEventQueue();
      expect(seen, [granted]);
    });

    test('tracks the change-notice marker', () async {
      final store = InMemoryEntitlementStore();
      expect(store.changeNoticeShownForVersion, isNull);
      await store.markChangeNoticeShown('1.1.0+15');
      expect(store.changeNoticeShownForVersion, '1.1.0+15');
    });
  });

  group('reconcile with a Play result', () {
    test('stamps the verification and persists', () async {
      final store = InMemoryEntitlementStore(clock: () => _now);
      final fromPlay = _plus();

      final result = await store.reconcile(fromPlay);

      expect(result.lastVerifiedAt, _now);
      expect(result.maxClockSeen, _now);
      expect(store.current, result);
    });

    test('a Play downgrade to free is applied', () async {
      // Cancelled or refunded, and the device is online to hear about it.
      final store = InMemoryEntitlementStore(
        initial: _plus(lastVerifiedAt: _now),
        clock: () => _now,
      );

      final result = await store.reconcile(Entitlement.free);

      expect(result.tier, EntitlementTier.free);
      expect(store.current.tier, EntitlementTier.free);
    });

    test('a verification clears a bogus future rollback ceiling', () async {
      final store = InMemoryEntitlementStore(
        initial: _plus(maxClockSeen: DateTime.utc(2027)),
        clock: () => _now,
      );

      final result = await store.reconcile(_plus());

      expect(result.maxClockSeen, _now);
      expect(result.isPlusAt(_now), isTrue);
    });
  });

  group('carryForwardPeriod', () {
    // Play never tells the Android client which base plan a purchase belongs
    // to, so a restored entitlement arrives with no period.
    Entitlement fromPlay({String token = 'token-abc'}) => Entitlement(
      tier: EntitlementTier.plus,
      productId: 'airgrid_plus',
      purchaseToken: token,
      lastVerifiedAt: _now,
    );

    test('keeps the cached period for the same purchase', () {
      final cached = _plus(period: BillingPeriod.yearly);
      final merged = EntitlementReconciler.carryForwardPeriod(
        fromPlay(),
        cached,
      );
      expect(merged.period, BillingPeriod.yearly);
      expect(merged.offlineTrustWindow, Entitlement.standardTrustWindow);
    });

    test('discards a stale period when the purchase token changed', () {
      // A plan change issues a new token; the old period must not stick.
      final cached = _plus(period: BillingPeriod.yearly);
      final merged = EntitlementReconciler.carryForwardPeriod(
        fromPlay(token: 'token-new'),
        cached,
      );
      expect(merged.period, isNull);
    });

    test('never overrides a period Play did supply', () {
      final cached = _plus(period: BillingPeriod.yearly);
      final authoritative = fromPlay().copyWith(period: BillingPeriod.weekly);
      final merged = EntitlementReconciler.carryForwardPeriod(
        authoritative,
        cached,
      );
      expect(merged.period, BillingPeriod.weekly);
    });

    test('does not resurrect a period onto a free result', () {
      final cached = _plus(period: BillingPeriod.yearly);
      final merged = EntitlementReconciler.carryForwardPeriod(
        Entitlement.free,
        cached,
      );
      expect(merged.tier, EntitlementTier.free);
      expect(merged.period, isNull);
    });

    test('reconcile applies the merge end to end', () async {
      final store = InMemoryEntitlementStore(
        initial: _plus(period: BillingPeriod.yearly),
        clock: () => _now,
      );

      final result = await store.reconcile(fromPlay());

      expect(result.period, BillingPeriod.yearly);
      expect(result.lastVerifiedAt, _now);
    });
  });

  group('reconcile with no Play result', () {
    test('never downgrades a paying user', () async {
      // The load-bearing case: offline, off-grid, mid-hike. Null means
      // "unknown", not "not subscribed".
      final paid = _plus(lastVerifiedAt: _now);
      final store = InMemoryEntitlementStore(
        initial: paid,
        clock: () => _now.add(const Duration(days: 2)),
      );

      final result = await store.reconcile(null);

      expect(result.tier, EntitlementTier.plus);
      expect(result.isPlusAt(_now.add(const Duration(days: 2))), isTrue);
      expect(store.current.tier, EntitlementTier.plus);
    });

    test('leaves a free user untouched and writes nothing', () async {
      final store = InMemoryEntitlementStore(clock: () => _now);
      final seen = <Entitlement>[];
      store.entitlementStream.listen(seen.add);

      final result = await store.reconcile(null);

      expect(result, Entitlement.free);
      await pumpEventQueue();
      expect(seen, isEmpty, reason: 'nothing to protect, so nothing to write');
    });

    test('seeds the rollback ceiling when there is none', () async {
      final store = InMemoryEntitlementStore(
        initial: _plus(lastVerifiedAt: _now),
        clock: () => _now,
      );

      final result = await store.reconcile(null);

      expect(result.maxClockSeen, _now);
    });

    test('skips the write when the ceiling barely moved', () async {
      final store = InMemoryEntitlementStore(
        initial: _plus(lastVerifiedAt: _now, maxClockSeen: _now),
        clock: () => _now.add(const Duration(minutes: 5)),
      );
      final seen = <Entitlement>[];
      store.entitlementStream.listen(seen.add);

      await store.reconcile(null);

      await pumpEventQueue();
      expect(seen, isEmpty);
      expect(store.current.maxClockSeen, _now);
    });

    test('writes once the ceiling has moved past the granularity', () async {
      final later = _now.add(const Duration(hours: 3));
      final store = InMemoryEntitlementStore(
        initial: _plus(lastVerifiedAt: _now, maxClockSeen: _now),
        clock: () => later,
      );
      final seen = <Entitlement>[];
      store.entitlementStream.listen(seen.add);

      final result = await store.reconcile(null);

      expect(result.maxClockSeen, later);
      await pumpEventQueue();
      expect(seen, hasLength(1));
    });

    test('a rolled-back clock cannot lower the ceiling', () async {
      final store = InMemoryEntitlementStore(
        initial: _plus(lastVerifiedAt: _now, maxClockSeen: _now),
        clock: () => _now.subtract(const Duration(days: 365)),
      );

      await store.reconcile(null);

      expect(store.current.maxClockSeen, _now);
    });
  });

  group('SecureEntitlementStore.decode', () {
    test('reads a missing or empty record as free', () {
      expect(SecureEntitlementStore.decode(null), Entitlement.free);
      expect(SecureEntitlementStore.decode(''), Entitlement.free);
    });

    test('reads a corrupt record as free instead of throwing', () {
      expect(SecureEntitlementStore.decode('{not json'), Entitlement.free);
      expect(SecureEntitlementStore.decode('[1,2,3]'), Entitlement.free);
    });

    test('round-trips a persisted entitlement', () {
      final original = _plus(lastVerifiedAt: _now, maxClockSeen: _now);
      final decoded = SecureEntitlementStore.decode(
        jsonEncode(original.toJson()),
      );
      expect(decoded, original);
    });
  });

  group('SecureEntitlementStore.create', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('starts free on a fresh install', () async {
      final store = await SecureEntitlementStore.create(clock: () => _now);
      expect(store.current, Entitlement.free);
    });

    test('restores a persisted entitlement', () async {
      final persisted = _plus(lastVerifiedAt: _now, maxClockSeen: _now);
      FlutterSecureStorage.setMockInitialValues({
        'airgrid_secure_entitlement': jsonEncode(persisted.toJson()),
      });

      final store = await SecureEntitlementStore.create(clock: () => _now);

      expect(store.current.tier, EntitlementTier.plus);
      expect(store.current.period, BillingPeriod.monthly);
      expect(store.current.isPlusAt(_now), isTrue);
    });

    test('survives a corrupt record without throwing', () async {
      FlutterSecureStorage.setMockInitialValues({
        'airgrid_secure_entitlement': 'garbage',
      });

      final store = await SecureEntitlementStore.create(clock: () => _now);

      expect(store.current, Entitlement.free);
    });

    test('a restored paying user stays paid while offline', () async {
      // Verified a fortnight ago, expired two days ago, still inside the
      // 30-day monthly window. Nothing here reaches Play.
      final persisted = _plus(
        expiresAt: _now.subtract(const Duration(days: 2)),
        lastVerifiedAt: _now.subtract(const Duration(days: 14)),
        maxClockSeen: _now.subtract(const Duration(days: 2)),
      );
      FlutterSecureStorage.setMockInitialValues({
        'airgrid_secure_entitlement': jsonEncode(persisted.toJson()),
      });

      final store = await SecureEntitlementStore.create(clock: () => _now);

      expect(store.current.statusAt(_now), EntitlementStatus.offlineTrusted);
      expect(store.current.isPlusAt(_now), isTrue);
    });
  });
}
