import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:airgrid/features/entitlement/plus_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The home app bar lockup: the wordmark where it fits, the square mark where
/// it does not.
///
/// The horizontal wordmark is 4.06:1, so at [logoHeight] it needs
/// [_wordmarkWidth] of room. A narrow phone does not have it: the home app bar
/// already spends 48dp on the leading button and 192dp on four actions, which
/// on a 360dp screen leaves barely 100dp for the title.
///
/// The failure that motivated this is specific. `BoxFit.contain` answers a
/// too-narrow box by scaling the *whole* wordmark down — height included — so
/// the logo does not overflow, it just quietly becomes unreadable. It had
/// already shrunk to roughly 26dp tall before [PlusBadge] existed; the badge
/// took another 60dp and drove it to about 11dp, which is where it was noticed.
///
/// Swapping to the square mark below the threshold keeps the brand legible
/// rather than merely present — 36dp of width at the same height instead of
/// 130dp. Above the threshold nothing changes, which is why wide screens always
/// looked right.
///
/// [BoxFit.fitHeight] rather than `contain` is the other half: it pins the
/// height, so a future layout change cannot silently shrink the mark again. The
/// image is deliberately not wrapped in [Flexible] — being squeezable is the
/// bug, and the threshold is what guarantees it never has to be.
class HomeAppBarTitle extends ConsumerWidget {
  const HomeAppBarTitle({super.key});

  /// Rendered height of both marks.
  static const double logoHeight = 32;

  /// Width the 4.06:1 wordmark occupies at [logoHeight].
  static const double _wordmarkWidth = 130;

  /// Room [PlusBadge] needs, including the gap before it.
  static const double _badgeAllowance = 60;

  /// Narrowest title box that still fits the wordmark, given the badge.
  ///
  /// A free-tier device is measured against the smaller figure, so it keeps the
  /// wordmark on screens where a subscriber's badge would not have left space.
  static double wordmarkThreshold({required bool withBadge}) =>
      _wordmarkWidth + (withBadge ? _badgeAllowance : 0);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showBadge = ref.watch(featureGatesProvider).isPlus;

    return LayoutBuilder(
      builder: (context, constraints) {
        final useWordmark =
            constraints.maxWidth >= wordmarkThreshold(withBadge: showBadge);

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              useWordmark
                  ? 'assets/images/airgrid_horizontal.png'
                  : 'assets/images/airgrid_symbol.png',
              height: logoHeight,
              fit: BoxFit.fitHeight,
              alignment: Alignment.centerLeft,
            ),
            if (showBadge) ...[const SizedBox(width: 8), const PlusBadge()],
          ],
        );
      },
    );
  }
}
