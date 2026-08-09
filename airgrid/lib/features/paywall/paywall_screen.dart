import 'dart:async';

import 'package:airgrid/core/logger.dart';
import 'package:airgrid/core/subscription_catalog.dart';
import 'package:airgrid/domain/models/entitlement.dart';
import 'package:airgrid/domain/services/billing_service.dart';
import 'package:airgrid/features/entitlement/entitlement_providers.dart';
import 'package:airgrid/features/paywall/paywall_controller.dart';
import 'package:airgrid/features/paywall/plus_change_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// What Plus unlocks, and what stays free.
///
/// Listing the free side is deliberate. Existing users are gated on update with
/// no grandfathering, so the paywall has to make clear how much still works
/// without paying — otherwise it reads as the app having been taken away.
const _plusFeatures = <(IconData, String)>[
  (Icons.record_voice_over, 'Start private walkie sessions'),
  (Icons.campaign_outlined, 'Public walkie — broadcast to everyone nearby'),
  (Icons.motorcycle_outlined, 'Rider Mode for continuous hands-free voice'),
  (Icons.attach_file, 'Send file attachments'),
  (Icons.download_outlined, 'Export your message history'),
];

const _freeFeatures = <String>[
  'Public and private chat',
  'Voice notes and images',
  'Location sharing and safety numbers',
  'Relaying for everyone nearby',
];

class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  /// Whether to explain that live voice used to be free.
  ///
  /// Captured once in [initState] rather than watched, so marking it seen does
  /// not make the banner vanish out from under the user mid-read.
  late final bool _showChangeNotice;

  @override
  void initState() {
    super.initState();

    final store = ref.read(entitlementStoreProvider);
    _showChangeNotice = shouldShowPlusChangeNotice(store);
    if (_showChangeNotice) {
      unawaited(markPlusChangeNoticeSeen(store));
    }

    // Prices are fetched after the first frame, never awaited before it. The
    // plans are already on screen from local configuration.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(paywallControllerProvider.notifier).loadPrices();
      }
    });
  }

  Future<void> _buy() async {
    final purchased = await ref
        .read(paywallControllerProvider.notifier)
        .purchaseSelected();
    if (purchased && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _restore() async {
    final restored = await ref
        .read(paywallControllerProvider.notifier)
        .restore();
    if (restored && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  /// Opens the Play subscription centre.
  ///
  /// Every plan is prepaid, so there is no renewal to cancel and no proration
  /// to arrange — what this is for is topping a plan up before it expires, and
  /// managing the payment method behind it.
  ///
  /// It is also the *only* extend path in the app: the plan list is hidden
  /// while a subscription is running, so that a paid-up account cannot buy a
  /// second one by mistake.
  Future<void> _manageSubscription() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final uri = SubscriptionCatalog.manageSubscriptionUri(
        packageName: info.packageName,
      );

      // `canLaunchUrl` needs the https scheme declared in the manifest's
      // <queries> block, or it answers false on Android 11+ regardless of
      // whether a browser exists. That declaration is in AndroidManifest.xml;
      // if this ever starts reporting failure on every device, check there
      // first.
      if (!await canLaunchUrl(uri)) {
        throw StateError('No handler for $uri');
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error) {
      AirGridLogger.log(
        LogCategory.billing,
        'Could not open the Play subscription centre: $error',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open Google Play. Manage your subscription from the '
            'Play Store app.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final state = ref.watch(paywallControllerProvider);
    final entitlement = ref.watch(entitlementProvider);
    final status = entitlement.statusAt(DateTime.now());
    final isSubscribed =
        status == EntitlementStatus.active ||
        status == EntitlementStatus.offlineTrusted;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AirGrid Plus'),
        actions: [
          if (isSubscribed)
            TextButton.icon(
              onPressed: state.isPurchasing ? null : _manageSubscription,
              icon: const Icon(Icons.settings),
              label: const Text('Manage'),
            ),
          TextButton(
            onPressed: state.isPurchasing ? null : _restore,
            child: const Text('Restore'),
          ),
        ],
      ),
      // Nothing to buy while the subscription is running. Leaving a live
      // Subscribe button under a paid-up account is how someone ends up buying
      // twice, and it is the reason this screen read as "not subscribed".
      bottomNavigationBar: isSubscribed
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: _BuyButton(state: state, onPressed: _buy),
              ),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        children: [
          if (_showChangeNotice) const PlusChangeBanner(),
          if (isSubscribed) _ActivePlanCard(entitlement: entitlement),
          Text(switch (status) {
            EntitlementStatus.lapsed => 'Your Plus subscription has ended',
            EntitlementStatus.active || EntitlementStatus.offlineTrusted =>
              'What your subscription '
                  'unlocks',
            EntitlementStatus.free => 'Live voice, with no internet',
          }, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (!isSubscribed) ...[
            Text(
              'Walkie-talkie over the mesh — no signal, no router, no server. '
              'Chat stays free.',
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 20),

          for (final (icon, label) in _plusFeatures)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: cs.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(label, style: text.bodyMedium)),
                ],
              ),
            ),

          const SizedBox(height: 12),
          if (state.message != null) _MessageBanner(message: state.message!),

          // The whole purchase apparatus is for people who do not have this
          // yet. Showing a subscriber a price list is how they conclude their
          // payment did not register.
          if (!isSubscribed) ...[
            for (final offer in state.offers)
              _PlanTile(
                offer: offer,
                selected: offer.basePlanId == state.selectedBasePlanId,
                enabled: !state.isPurchasing,
                onTap: () => ref
                    .read(paywallControllerProvider.notifier)
                    .select(offer.basePlanId),
              ),

            if (!state.canPurchase && !state.isLoadingPrices)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Center(
                  child: TextButton.icon(
                    onPressed: () => ref
                        .read(paywallControllerProvider.notifier)
                        .loadPrices(),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Check prices again'),
                  ),
                ),
              ),

            const SizedBox(height: 16),
            Text(
              'Going off-grid for more than a week? Choose monthly — the '
              'weekly pass needs a connection sooner to stay verified.',
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 20),

          Text(
            'Always free',
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final label in _freeFeatures)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Icon(Icons.check, size: 16, color: cs.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: text.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'You can always receive walkie audio and join a session someone '
            'else starts, on any plan.',
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Confirms, unmistakably, that this account is paid up.
///
/// The paywall used to render identically whether or not you had bought
/// anything — same three prices, same Subscribe button — so the only way to
/// find out was to reach for a locked feature and see if it worked. Stating it
/// outright is the whole point of this card.
class _ActivePlanCard extends StatelessWidget {
  final Entitlement entitlement;

  const _ActivePlanCard({required this.entitlement});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final offline =
        entitlement.statusAt(DateTime.now()) ==
        EntitlementStatus.offlineTrusted;

    final plan = switch (entitlement.period) {
      BillingPeriod.weekly => 'Weekly plan',
      BillingPeriod.monthly => 'Monthly plan',
      BillingPeriod.yearly => 'Yearly plan',
      // Play never reports the base plan back on a restore, so after a
      // reinstall the period is genuinely unknown. Do not invent one.
      null => 'Subscription active',
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Material(
        color: cs.primaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.workspace_premium,
                size: 22,
                color: cs.onPrimaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AirGrid Plus is active',
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      offline
                          ? '$plan · running offline — AirGrid will re-check '
                                'with Google Play once you are back online'
                          : '$plan · confirmed with Google Play',
                      style: text.bodySmall?.copyWith(
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Prepaid — it expires on its own, and Google Play will '
                      'not charge you again.',
                      style: text.bodySmall?.copyWith(
                        color: cs.onPrimaryContainer.withAlpha(200),
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

class _BuyButton extends StatelessWidget {
  final PaywallState state;
  final VoidCallback onPressed;

  const _BuyButton({required this.state, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    if (state.isPurchasing) {
      return const FilledButton(
        onPressed: null,
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final offer = state.selectedOffer;
    // Only the button goes quiet when prices are unreachable. Everything else
    // on this screen stays readable.
    if (!offer.isPurchasable) {
      return const FilledButton(
        onPressed: null,
        child: Text('Connect to subscribe'),
      );
    }

    return FilledButton(
      onPressed: onPressed,
      child: Text(
        offer.hasFreeTrial
            ? 'Start 7-day free trial'
            : 'Subscribe — ${offer.formattedPrice}',
      ),
    );
  }
}

class _MessageBanner extends StatelessWidget {
  final String message;

  const _MessageBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanTile extends StatelessWidget {
  final SubscriptionOffer offer;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _PlanTile({
    required this.offer,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  String get _periodLabel => switch (offer.period) {
    BillingPeriod.weekly => 'Weekly',
    BillingPeriod.monthly => 'Monthly',
    BillingPeriod.yearly => 'Yearly',
  };

  /// The span a prepaid plan buys, phrased for the "expires" note.
  ///
  /// Every plan is prepaid, so this must track [offer.period] rather than
  /// naming a fixed span — a single hardcoded string would tell a yearly buyer
  /// their purchase lasts one week.
  String get _prepaidSpan => switch (offer.period) {
    BillingPeriod.weekly => 'One week',
    BillingPeriod.monthly => 'One month',
    BillingPeriod.yearly => 'One year',
  };

  String get _subtitle {
    final notes = <String>[
      if (offer.isPrepaid) '$_prepaidSpan, expires — no auto-renewal',
      if (offer.hasFreeTrial) '7 days free, then billed monthly',
      if (offer.period == BillingPeriod.yearly) 'Best value',
    ];
    if (!offer.isPurchasable) {
      notes.add('Price unavailable offline');
    }
    return notes.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // The colour lives on the Material rather than a wrapping DecoratedBox, so
    // the tile's ink splash stays visible.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected ? cs.primaryContainer : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 20,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _periodLabel,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_subtitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _subtitle,
                            style: text.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  // An em dash rather than a fake price: never invent a number
                  // Play did not give us.
                  offer.formattedPrice ?? '—',
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: offer.isPurchasable ? null : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
