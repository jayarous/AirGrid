import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:airgrid/features/home/home_app_bar_title.dart';
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

/// Pumps the title inside a box of exactly [width], the way a real app bar
/// hands it whatever the leading button and actions did not take.
Future<void> _pumpTitle(
  WidgetTester tester, {
  required double width,
  Entitlement entitlement = Entitlement.free,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        entitlementStoreProvider.overrideWithValue(
          InMemoryEntitlementStore(initial: entitlement, clock: () => _now),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: const HomeAppBarTitle()),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

String _assetOf(WidgetTester tester) {
  final image = tester.widget<Image>(find.byType(Image));
  return (image.image as AssetImage).assetName;
}

void main() {
  group('narrow screens', () {
    testWidgets('drop the wordmark for the square mark', (tester) async {
      // Roughly what a 360dp phone leaves after a leading button and four
      // actions — and far too little for a 130dp wordmark.
      await _pumpTitle(tester, width: 104);

      expect(_assetOf(tester), contains('airgrid_symbol'));
    });

    testWidgets('keep the mark at full height rather than shrinking it', (
      tester,
    ) async {
      // The original bug: BoxFit.contain answered a narrow box by scaling the
      // logo down instead of overflowing, so it went unnoticed until it was
      // about 11dp tall.
      await _pumpTitle(tester, width: 104);

      expect(
        tester.getSize(find.byType(Image)).height,
        HomeAppBarTitle.logoHeight,
      );
    });
  });

  group('wide screens', () {
    testWidgets('keep the wordmark', (tester) async {
      await _pumpTitle(tester, width: 300);

      expect(_assetOf(tester), contains('airgrid_horizontal'));
    });

    testWidgets('keep the wordmark at full height', (tester) async {
      await _pumpTitle(tester, width: 300);

      expect(
        tester.getSize(find.byType(Image)).height,
        HomeAppBarTitle.logoHeight,
      );
    });
  });

  group('the badge changes how much room the wordmark needs', () {
    /// Wide enough for the wordmark alone, not for the wordmark plus a badge.
    const tightWidth = 150.0;

    test('the two thresholds straddle the width these tests use', () {
      expect(
        tightWidth,
        greaterThan(HomeAppBarTitle.wordmarkThreshold(withBadge: false)),
      );
      expect(
        tightWidth,
        lessThan(HomeAppBarTitle.wordmarkThreshold(withBadge: true)),
      );
    });

    testWidgets('a free device keeps the wordmark at that width', (
      tester,
    ) async {
      await _pumpTitle(tester, width: tightWidth);

      expect(_assetOf(tester), contains('airgrid_horizontal'));
    });

    testWidgets('a subscriber drops to the square mark at that width', (
      tester,
    ) async {
      await _pumpTitle(tester, width: tightWidth, entitlement: _plus());

      expect(
        _assetOf(tester),
        contains('airgrid_symbol'),
        reason: 'the badge must not squeeze the wordmark, it must displace it',
      );
    });

    testWidgets('a subscriber on a wide screen gets both', (tester) async {
      await _pumpTitle(tester, width: 300, entitlement: _plus());

      expect(_assetOf(tester), contains('airgrid_horizontal'));
      expect(find.text('PLUS'), findsOneWidget);
    });
  });
}
