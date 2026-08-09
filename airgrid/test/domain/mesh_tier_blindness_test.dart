import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the one rule that protects the mesh from the paywall.
///
/// `AirGridMeshService` routes, relays and spools for *every* nearby device,
/// most of which will be on the free tier. Free devices are infrastructure: if
/// relaying, spooling or receiving ever became tier-dependent, the mesh would
/// thin out and the paid experience would get worse, not better.
///
/// Today that is guaranteed structurally — the mesh service is never handed an
/// entitlement, so it cannot consult one. This test exists to notice if someone
/// later hands it one. It reads source text, which is unusual for this suite,
/// because a behavioural test cannot express "this dependency must not exist":
/// the absence is the invariant.
///
/// If this fails, the fix is almost never to relax the test. Gate in
/// `ChatController` or `RiderModeController` instead — see `FeatureGates`.
void main() {
  const meshServicePath = 'lib/domain/services/mesh_service.dart';

  /// Identifiers that would mean the mesh layer had learned about tiers.
  const forbidden = <String>[
    'FeatureGates',
    'featureGatesProvider',
    'Entitlement',
    'entitlementStoreProvider',
    'EntitlementTier',
    'isPlus',
    'BillingService',
    'SubscriptionCatalog',
  ];

  test('mesh_service.dart knows nothing about entitlements', () {
    final file = File(meshServicePath);
    expect(
      file.existsSync(),
      isTrue,
      reason:
          'If mesh_service.dart moved, update this path — do not delete the '
          'test. The invariant outlives the file layout.',
    );

    final source = file.readAsStringSync();
    for (final identifier in forbidden) {
      expect(
        source.contains(identifier),
        isFalse,
        reason:
            'mesh_service.dart references "$identifier". Routing and relay must '
            'stay tier-blind: gate in ChatController or RiderModeController '
            'instead, never in the mesh layer.',
      );
    }
  });

  test('the mesh layer imports nothing from the billing or paywall layers', () {
    final source = File(meshServicePath).readAsStringSync();
    final imports = source
        .split('\n')
        .where((line) => line.trimLeft().startsWith('import '))
        .toList();

    for (final import in imports) {
      expect(
        import.contains('/billing/') ||
            import.contains('paywall') ||
            import.contains('entitlement') ||
            import.contains('feature_gates'),
        isFalse,
        reason: 'mesh_service.dart must not import: $import',
      );
    }
  });
}
