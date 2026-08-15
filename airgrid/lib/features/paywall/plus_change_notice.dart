import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/data/storage/entitlement_store.dart';
import 'package:flutter/material.dart';

/// Marker for the release that introduced AirGrid Plus.
///
/// Change it only to deliberately re-show the notice. Defined in
/// [SubscriptionCatalog] so the entitlement providers can reference it without
/// importing this file.
const String kPlusNoticeVersion = SubscriptionCatalog.plusNoticeVersion;

/// Whether this device still owes the user an explanation of the change.
///
/// There is no grandfathering, so someone updating from an older build finds
/// private walkie and Rider Mode locked. An explanation is the difference
/// between "the app changed and told me" and "the app took something away" —
/// the second is where one-star reviews come from.
///
/// **Deliberately not shown at launch.** It used to open a bottom sheet over
/// the first screen, which meant every fresh install — people who never had
/// live voice and have not yet sent a message — was told that a feature they
/// never used "is now" paid. That is friction for the many to explain a change
/// to the few. Instead the explanation rides on [PlusChangeBanner] at the top
/// of the paywall, which is reached exactly when the change starts to matter:
/// the moment the user reaches for a gated feature.
///
/// Fresh installs are suppressed at startup in `main.dart`, which marks the
/// notice seen when the device has never accepted the terms — the signal that
/// no previous build ever ran here.
bool shouldShowPlusChangeNotice(EntitlementStore store) =>
    store.changeNoticeShownForVersion != kPlusNoticeVersion;

/// Records that the explanation has been delivered.
///
/// Called as the banner is built rather than after the user acknowledges it.
/// A paywall closed by a back-swipe or a crash must not bring the banner back
/// every time; being seen once is the point, and nagging would undo the
/// goodwill it exists to buy.
Future<void> markPlusChangeNoticeSeen(EntitlementStore store) =>
    store.markChangeNoticeShown(kPlusNoticeVersion);

/// The "what changed" header, shown once at the top of the paywall.
///
/// Says what was lost and — at greater length — what was not. The second half
/// is the more important one: someone who just hit a wall needs to know the
/// app they rely on off-grid still carries their messages for free.
class PlusChangeBanner extends StatelessWidget {
  const PlusChangeBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // Colour on the Material rather than a wrapping DecoratedBox, matching the
    // plan tiles below it.
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: cs.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 20, color: cs.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Live voice is now AirGrid Plus',
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Starting a private walkie session and Rider Mode now '
                      'need a subscription.',
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Public walkie, chat, voice notes, images, location '
                      'sharing and relaying stay free — and you can still join '
                      'a walkie session someone else starts, and talk back for '
                      'as long as it lasts.',
                      style: text.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
