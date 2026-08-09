import 'package:airgrid/core/feature_gates.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:airgrid/features/paywall/paywall_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Checks a Plus gate and, when it is closed, opens the paywall.
///
/// Returns true when the caller may proceed — either it was already entitled, or
/// the user subscribed there and then, in which case the action they originally
/// asked for continues rather than making them find it again.
///
/// **The only place in the app that navigates to the paywall.** Every gated
/// entry point routes through here, so the behaviour is identical everywhere and
/// there is exactly one path to audit.
///
/// [gate] names the specific capability rather than asking a blanket "is this
/// user paying", so each call site documents at a glance what it needs.
Future<bool> ensurePlus(
  BuildContext context,
  WidgetRef ref, {
  required bool Function(FeatureGates gates) gate,
}) async {
  if (gate(ref.read(featureGatesProvider))) return true;

  final purchased = await Navigator.of(
    context,
  ).push<bool>(MaterialPageRoute<bool>(builder: (_) => const PaywallScreen()));
  if (purchased != true) return false;

  // Re-read rather than trusting the paywall's answer: the entitlement has been
  // through the store, and the gate is the only authority on what it permits.
  return gate(ref.read(featureGatesProvider));
}
