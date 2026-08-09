/// What the local user is entitled to.
///
/// Deliberately independent of [BillingPeriod]: feature gates ask whether the
/// tier is [plus] and never switch on how the subscription is billed. Only
/// [Entitlement.offlineTrustWindow] reads the period.
enum EntitlementTier { free, plus }

/// Billing period of the purchased base plan.
///
/// Persisted only so the offline trust window stays computable with no
/// network. Weekly is a prepaid plan — it expires rather than renewing.
enum BillingPeriod {
  weekly,
  monthly,
  yearly;

  /// Defensive parse for persisted values. Returns null for anything
  /// unrecognised so a future plan name cannot crash an older build.
  static BillingPeriod? fromName(String? name) {
    for (final period in BillingPeriod.values) {
      if (period.name == name) return period;
    }
    return null;
  }
}

/// Where a cached entitlement stands relative to the clock.
enum EntitlementStatus {
  /// Never purchased. The paywall should invite a first purchase.
  free,

  /// Inside the paid period according to the cached receipt.
  active,

  /// Past the paid period, but the last successful verification is recent
  /// enough that paid access continues. See [Entitlement.offlineTrustWindow].
  ///
  /// This is the normal state for a device that went off-grid across a renewal
  /// date, which is exactly the case this whole design exists to serve.
  offlineTrusted,

  /// Past the paid period and past the trust window. Downgraded to free.
  lapsed,
}

/// A cached, offline-evaluable subscription entitlement.
///
/// AirGrid is offline-first, so entitlement is never decided by a live network
/// call. It is decided by this value object plus a clock.
class Entitlement {
  final EntitlementTier tier;

  /// Null on the free tier.
  final BillingPeriod? period;

  /// Play product identifier, kept for diagnostics and restore.
  final String? productId;

  /// Play purchase token. Never leaves the device alongside the node ID —
  /// linking a payment identity to a mesh node ID would deanonymise the user.
  final String? purchaseToken;

  /// End of the paid period per the cached receipt.
  final DateTime? expiresAt;

  /// When Play last successfully confirmed this entitlement.
  final DateTime? lastVerifiedAt;

  /// Highest wall-clock time ever observed by this install.
  ///
  /// Guards against a clock rolled backwards to resurrect a dead
  /// subscription. See [effectiveNow].
  final DateTime? maxClockSeen;

  /// Timestamps are normalised to UTC.
  ///
  /// Two reasons. Dart's `DateTime ==` compares the UTC flag as well as the
  /// instant, so a value that survived a JSON round trip would otherwise
  /// compare unequal to the one that produced it. And entitlement outlives
  /// timezone changes — a user crossing a border must not gain or lose access.
  Entitlement({
    required this.tier,
    this.period,
    this.productId,
    this.purchaseToken,
    DateTime? expiresAt,
    DateTime? lastVerifiedAt,
    DateTime? maxClockSeen,
  }) : expiresAt = expiresAt?.toUtc(),
       lastVerifiedAt = lastVerifiedAt?.toUtc(),
       maxClockSeen = maxClockSeen?.toUtc();

  /// Const path for [free], which has no timestamps to normalise.
  const Entitlement._free()
    : tier = EntitlementTier.free,
      period = null,
      productId = null,
      purchaseToken = null,
      expiresAt = null,
      lastVerifiedAt = null,
      maxClockSeen = null;

  /// The free tier.
  ///
  /// This is **not** the right value for a Play query that failed — see
  /// `BillingService.queryEntitlement`, which returns null for "unknown" so an
  /// offline device never downgrades itself.
  static const Entitlement free = Entitlement._free();

  /// Floor for the trust window, and the value used for weekly plans. Enough
  /// to cover a festival, a hike or a blackout.
  static const Duration weeklyTrustWindow = Duration(days: 7);

  /// Trust window for monthly and yearly plans.
  static const Duration standardTrustWindow = Duration(days: 30);

  /// How recent a Play confirmation counts as [EntitlementStatus.active] when
  /// Play supplied no [expiresAt].
  ///
  /// The Android client is never told when a subscription ends — only the Play
  /// Developer API knows. But Play only reports *currently active*
  /// subscriptions, so a fresh confirmation is as good as knowing.
  static const Duration freshVerificationWindow = Duration(days: 1);

  /// How long paid access survives with no successful Play verification.
  ///
  /// Scaled to the billing period: a one-week purchase must not buy a month of
  /// unverified access. The paywall says plainly that longer off-grid trips
  /// want the monthly plan.
  ///
  /// An unknown period falls back to the seven-day floor rather than to zero.
  /// A restore after reinstall cannot recover the base plan from Play, and a
  /// paying user must not lapse the instant they go offline just because the
  /// client could not name their plan. Under-granting beats over-granting, and
  /// zero would be neither.
  Duration get offlineTrustWindow => switch (period) {
    BillingPeriod.weekly => weeklyTrustWindow,
    BillingPeriod.monthly => standardTrustWindow,
    BillingPeriod.yearly => standardTrustWindow,
    null => tier == EntitlementTier.plus ? weeklyTrustWindow : Duration.zero,
  };

  /// The timestamp to reason with, guarded against a clock moved backwards.
  ///
  /// The highest timestamp ever seen wins, so rolling the clock back cannot
  /// resurrect an expired subscription. This cannot strand anyone permanently:
  /// [verifiedAt] rewrites [maxClockSeen] outright, so a device whose clock was
  /// wrongly in the future recovers the moment it reaches Play again.
  DateTime effectiveNow(DateTime now) {
    final ceiling = maxClockSeen;
    if (ceiling == null) return now;
    return now.isBefore(ceiling) ? ceiling : now;
  }

  /// Evaluates this entitlement against [now].
  EntitlementStatus statusAt(DateTime now) {
    if (tier == EntitlementTier.free) return EntitlementStatus.free;

    final effective = effectiveNow(now);
    final expiry = expiresAt;
    final verified = lastVerifiedAt;

    if (expiry != null) {
      if (effective.isBefore(expiry)) return EntitlementStatus.active;
    } else if (verified != null &&
        effective.difference(verified) < freshVerificationWindow) {
      // Play confirmed an active subscription but never says when it ends.
      // A confirmation this recent is as good as an expiry date.
      return EntitlementStatus.active;
    }

    // Past the paid period, or no expiry was ever recorded. Paid access
    // continues only while the last successful verification is recent enough.
    //
    // The window is measured from [lastVerifiedAt] rather than from
    // [expiresAt] because what it bounds is *ignorance*: how long this device
    // has been unable to learn whether the subscription renewed. A device that
    // has been offline for two months genuinely does not know.
    if (verified == null) return EntitlementStatus.lapsed;
    if (effective.difference(verified) < offlineTrustWindow) {
      return EntitlementStatus.offlineTrusted;
    }
    return EntitlementStatus.lapsed;
  }

  /// The single question every feature gate asks.
  bool isPlusAt(DateTime now) => switch (statusAt(now)) {
    EntitlementStatus.active || EntitlementStatus.offlineTrusted => true,
    EntitlementStatus.free || EntitlementStatus.lapsed => false,
  };

  /// Stamps a successful Play verification at [now].
  ///
  /// [maxClockSeen] is overwritten rather than advanced: a live confirmation
  /// from Play is more authoritative than any previously observed local clock,
  /// and this is the escape hatch that recovers a device whose clock had been
  /// wrongly set into the future.
  Entitlement verifiedAt(DateTime now) => Entitlement(
    tier: tier,
    period: period,
    productId: productId,
    purchaseToken: purchaseToken,
    expiresAt: expiresAt,
    lastVerifiedAt: now,
    maxClockSeen: now,
  );

  /// Records [now] as observed, without claiming a verification happened.
  ///
  /// Called on cold start so the rollback ceiling keeps rising even for a
  /// device that never reaches Play.
  Entitlement observedAt(DateTime now) {
    final ceiling = maxClockSeen;
    if (ceiling != null && !now.isAfter(ceiling)) return this;
    return copyWith(maxClockSeen: now);
  }

  Entitlement copyWith({
    EntitlementTier? tier,
    BillingPeriod? period,
    String? productId,
    String? purchaseToken,
    DateTime? expiresAt,
    DateTime? lastVerifiedAt,
    DateTime? maxClockSeen,
  }) {
    return Entitlement(
      tier: tier ?? this.tier,
      period: period ?? this.period,
      productId: productId ?? this.productId,
      purchaseToken: purchaseToken ?? this.purchaseToken,
      expiresAt: expiresAt ?? this.expiresAt,
      lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
      maxClockSeen: maxClockSeen ?? this.maxClockSeen,
    );
  }

  Map<String, dynamic> toJson() => {
    'tier': tier.name,
    if (period != null) 'period': period!.name,
    if (productId != null) 'productId': productId,
    if (purchaseToken != null) 'purchaseToken': purchaseToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.millisecondsSinceEpoch,
    if (lastVerifiedAt != null)
      'lastVerifiedAt': lastVerifiedAt!.millisecondsSinceEpoch,
    if (maxClockSeen != null)
      'maxClockSeen': maxClockSeen!.millisecondsSinceEpoch,
  };

  factory Entitlement.fromJson(Map<String, dynamic> json) {
    // Anything unrecognised reads as free rather than throwing: a corrupt or
    // future-format record must not brick startup.
    final tier = json['tier'] == EntitlementTier.plus.name
        ? EntitlementTier.plus
        : EntitlementTier.free;
    return Entitlement(
      tier: tier,
      period: BillingPeriod.fromName(json['period'] as String?),
      productId: json['productId'] as String?,
      purchaseToken: json['purchaseToken'] as String?,
      expiresAt: _readTime(json['expiresAt']),
      lastVerifiedAt: _readTime(json['lastVerifiedAt']),
      maxClockSeen: _readTime(json['maxClockSeen']),
    );
  }

  static DateTime? _readTime(Object? millis) {
    if (millis is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  @override
  bool operator ==(Object other) =>
      other is Entitlement &&
      other.tier == tier &&
      other.period == period &&
      other.productId == productId &&
      other.purchaseToken == purchaseToken &&
      other.expiresAt == expiresAt &&
      other.lastVerifiedAt == lastVerifiedAt &&
      other.maxClockSeen == maxClockSeen;

  @override
  int get hashCode => Object.hash(
    tier,
    period,
    productId,
    purchaseToken,
    expiresAt,
    lastVerifiedAt,
    maxClockSeen,
  );

  @override
  String toString() =>
      'Entitlement(tier=${tier.name}, period=${period?.name}, '
      'expiresAt=$expiresAt, lastVerifiedAt=$lastVerifiedAt)';
}
