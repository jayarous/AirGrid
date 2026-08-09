import 'package:airgrid/core/feature_gates.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 8, 9, 12);

FeatureGates _gatesFor(Entitlement entitlement, {DateTime? at}) =>
    FeatureGates(entitlement, clock: () => at ?? _now);

Entitlement _activePlus({BillingPeriod period = BillingPeriod.monthly}) =>
    Entitlement(
      tier: EntitlementTier.plus,
      period: period,
      expiresAt: _now.add(const Duration(days: 10)),
      lastVerifiedAt: _now,
    );

void main() {
  group('free tier', () {
    final gates = _gatesFor(Entitlement.free);

    test('cannot start what is paid', () {
      expect(gates.isPlus, isFalse);
      expect(gates.canStartWalkieSession, isFalse);
      expect(gates.canEnablePublicWalkie, isFalse);
      expect(gates.canStartRiderSession, isFalse);
      expect(gates.canSendFileAttachment, isFalse);
      expect(gates.canExportHistory, isFalse);
    });

    test('can still join a walkie session it did not start', () {
      // Load-bearing. If a free peer cannot accept, a paying user's headline
      // feature only works when the other person has also paid, and the payer
      // blames the app rather than the paywall.
      expect(gates.canAcceptWalkieSession, isTrue);
      expect(gates.canDeclineWalkieSession, isTrue);
      expect(gates.canEndWalkieSession, isTrue);
    });

    test('can still take part in Rider Mode it did not start', () {
      // Arming is mesh presence — it is how paying riders discover this peer,
      // and it travels inside a key_announce packet.
      expect(gates.canArmRiderPresence, isTrue);
      expect(gates.canAcceptRiderSession, isTrue);
    });

    test('keeps relaying audio for paying users', () {
      expect(gates.canRelayWalkieAudio, isTrue);
    });

    test('keeps every chat-shaped send', () {
      expect(gates.canSendImage, isTrue);
      expect(gates.canSendVoiceNote, isTrue);
    });
  });

  group('plus tier', () {
    test('unlocks every paid gate', () {
      final gates = _gatesFor(_activePlus());
      expect(gates.isPlus, isTrue);
      expect(gates.canStartWalkieSession, isTrue);
      expect(gates.canEnablePublicWalkie, isTrue);
      expect(gates.canStartRiderSession, isTrue);
      expect(gates.canSendFileAttachment, isTrue);
      expect(gates.canExportHistory, isTrue);
    });

    test('reports its status for the paywall to read', () {
      expect(_gatesFor(_activePlus()).status, EntitlementStatus.active);
      expect(_gatesFor(Entitlement.free).status, EntitlementStatus.free);
    });

    test('every gate holds regardless of billing period', () {
      // Gates ask isPlus and must never switch on how the plan is billed.
      for (final period in BillingPeriod.values) {
        final gates = _gatesFor(_activePlus(period: period));
        expect(gates.canStartWalkieSession, isTrue, reason: '$period');
        expect(gates.canStartRiderSession, isTrue, reason: '$period');
        expect(gates.canSendFileAttachment, isTrue, reason: '$period');
      }
    });
  });

  group('clock', () {
    test('gates follow the injected clock across a lapse', () {
      final entitlement = Entitlement(
        tier: EntitlementTier.plus,
        period: BillingPeriod.weekly,
        expiresAt: _now,
        lastVerifiedAt: _now,
      );

      // Two days after expiry: inside the seven-day weekly window.
      final soon = _now.add(const Duration(days: 2));
      expect(_gatesFor(entitlement, at: soon).canStartWalkieSession, isTrue);

      // Ten days after: past it.
      final later = _now.add(const Duration(days: 10));
      final lapsed = _gatesFor(entitlement, at: later);
      expect(lapsed.canStartWalkieSession, isFalse);

      // ...and a lapsed user still joins sessions and still relays.
      expect(lapsed.canAcceptWalkieSession, isTrue);
      expect(lapsed.canRelayWalkieAudio, isTrue);
      expect(lapsed.canArmRiderPresence, isTrue);
    });

    test('defaults to the real clock when none is injected', () {
      // A far-future expiry is plus under any plausible wall clock.
      final entitlement = Entitlement(
        tier: EntitlementTier.plus,
        period: BillingPeriod.yearly,
        expiresAt: DateTime.utc(2999),
        lastVerifiedAt: DateTime.utc(2020),
      );
      expect(FeatureGates(entitlement).isPlus, isTrue);
      expect(FeatureGates.free().isPlus, isFalse);
    });
  });
}
