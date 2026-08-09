import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A small "PLUS" pill, shown beside the AirGrid wordmark while a subscription
/// is running.
///
/// Standing answer to "did my payment go through?". Entitlement was previously
/// only observable by reaching for a locked feature and seeing whether it
/// worked, which is a bad way to learn you have paid — and an even worse way to
/// learn you have not.
///
/// **Renders nothing on the free tier**, so call sites can include it
/// unconditionally rather than each one re-deriving the same condition and
/// eventually disagreeing about it.
///
/// Watches the entitlement, so it appears the moment a purchase settles and
/// disappears when the subscription lapses — no restart, nothing to refresh.
class PlusBadge extends ConsumerWidget {
  const PlusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(featureGatesProvider).isPlus) {
      return const SizedBox.shrink();
    }

    final cs = Theme.of(context).colorScheme;

    return Semantics(
      label: 'AirGrid Plus subscription active',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          'PLUS',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: cs.onPrimaryContainer,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}
