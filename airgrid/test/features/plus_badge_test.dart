import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:airgrid/features/entitlement/plus_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 8, 9, 12);

Entitlement _plus() => Entitlement(
  tier: EntitlementTier.plus,
  period: BillingPeriod.monthly,
  productId: 'airgrid_plus',
  purchaseToken: 'token-abc',
  lastVerifiedAt: _now,
  maxClockSeen: _now,
);

Future<InMemoryEntitlementStore> _pumpBadge(
  WidgetTester tester, {
  required Entitlement entitlement,
}) async {
  final store = InMemoryEntitlementStore(
    initial: entitlement,
    clock: () => _now,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [entitlementStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: Scaffold(body: PlusBadge())),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('is invisible on the free tier', (tester) async {
    await _pumpBadge(tester, entitlement: Entitlement.free);

    expect(find.text('PLUS'), findsNothing);
  });

  testWidgets('marks a running subscription', (tester) async {
    await _pumpBadge(tester, entitlement: _plus());

    expect(find.text('PLUS'), findsOneWidget);
  });

  testWidgets('appears the moment a purchase settles', (tester) async {
    // No restart, nothing to refresh — the badge is the standing answer to
    // "did my payment go through?", so it has to react on its own.
    final store = await _pumpBadge(tester, entitlement: Entitlement.free);
    expect(find.text('PLUS'), findsNothing);

    await store.save(_plus());
    await tester.pumpAndSettle();

    expect(find.text('PLUS'), findsOneWidget);
  });

  testWidgets('disappears when the subscription lapses', (tester) async {
    final store = await _pumpBadge(tester, entitlement: _plus());
    expect(find.text('PLUS'), findsOneWidget);

    await store.save(Entitlement.free);
    await tester.pumpAndSettle();

    expect(find.text('PLUS'), findsNothing);
  });
}
