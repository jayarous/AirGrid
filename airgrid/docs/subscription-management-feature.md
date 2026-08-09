# Subscription Management Feature

## Overview

A "Manage" action on the AirGrid Plus paywall that deep-links to the Google Play
subscription centre, so a subscriber can top up or change payment method without
hunting through the Play Store app.

## Problem

Every AirGrid Plus base plan is **prepaid** — it expires on its own date and
never auto-renews (see `subscription-design.md`). Two consequences shaped this
feature:

- There is no renewal to manage, so the thing a subscriber actually needs is a
  way to **extend before expiry**.
- The paywall deliberately hides the plan list while a subscription is running,
  so that a paid-up account cannot buy a second one by mistake. That closed the
  in-app repurchase route.

Together those left an active subscriber with no extend path inside the app.

## Solution

A "Manage" button in the paywall AppBar, shown only when the entitlement is
`active` or `offlineTrusted`, opening the Play subscription centre.

### What the Play subscription centre actually offers for prepaid plans

Prepaid is not auto-renewing, and the two behave differently. For AirGrid's
plans a user can:

- **Top up** — extend the current plan before it expires
- **View purchase history**
- **Update the payment method** on the Google account

What is **not** available, because prepaid plans do not work that way:

- *Cancelling a subscription* — there is no recurring charge to stop. A prepaid
  plan ends by expiring.
- *Upgrade / downgrade with proration* — switching period means buying the other
  plan when the current one lapses. There is nothing to prorate.

Do not describe this feature to users in auto-renewal language. Getting that
wrong in UI copy is the same defect class as the "7-day free trial" line that
shipped and had to be pulled: a billing promise the product cannot keep.

## Implementation

### Deep link

Built by `SubscriptionCatalog.manageSubscriptionUri()` rather than assembled at
the call site, because two parameters are easy to get wrong:

```
https://play.google.com/store/account/subscriptions?sku=airgrid_plus&package=<packageName>
```

- **`sku` is the subscription product ID (`airgrid_plus`), not a base plan ID.**
  Play resolves this against *products*. Passing `weekly` / `monthly` / `yearly`
  — the base plan the user actually bought — matches nothing and drops them on
  the generic subscription list. `subscription_catalog_test.dart` pins this.
- **`packageName` comes from `PackageInfo.fromPlatform()`**, not a literal. A
  hardcoded id silently rots against a build flavour or an application-id
  rename.

### Android manifest — required, not optional

`canLaunchUrl` returns **false** for `https` on Android 11+ unless the scheme is
declared in `<queries>`. `targetSdk` is 36, so package-visibility filtering
applies, and without this the button reports failure on essentially every modern
device:

```xml
<queries>
    <intent>
        <action android:name="android.intent.action.VIEW"/>
        <data android:scheme="https"/>
    </intent>
</queries>
```

This is the failure mode to check first if Manage ever stops working. It is
invisible to `flutter analyze` and to every widget test — nothing in Dart can
see it.

### Files

| File | Change |
|---|---|
| `lib/core/subscription_catalog.dart` | `manageSubscriptionUri()` |
| `lib/features/paywall/paywall_screen.dart` | `_manageSubscription()` and the AppBar action |
| `android/app/src/main/AndroidManifest.xml` | `https` VIEW entry in `<queries>` |
| `pubspec.yaml` | `url_launcher` |

## Tests

- `test/core/subscription_catalog_test.dart` — the deep link carries the product
  ID and never a base plan ID, honours the package name it is given, and uses
  https (which must match the manifest entry).
- `test/features/paywall_screen_test.dart` — Manage appears for a subscriber and
  is absent on the free tier.

The launch itself is not covered: `canLaunchUrl` and `launchUrl` are top-level
functions with no injection point. Verify by hand on a device.

## Manual checklist

- [ ] Manage appears only for an active subscriber
- [ ] Tapping it opens the Play subscription centre on the AirGrid entry, not
      the generic list
- [ ] Works on an Android 11+ device — this is what the `<queries>` entry buys
- [ ] With Play unavailable, the snackbar appears instead of a silent no-op

## Possible follow-ups

- **Show the expiry date** on `_ActivePlanCard`. Currently impossible on the
  client: `PurchaseDetails` carries no expiry, only the Play Developer API does.
  This needs the server verification described in `subscription-design.md` §6.
- **In-app top-up**, keeping the user inside the app rather than sending them to
  Play. Worth revisiting only if the deep link proves to be a drop-off point.

## References

- [Google Play Billing — Prepaid plans](https://developer.android.com/google/play/billing/subscriptions#prepaid)
- [url_launcher configuration](https://pub.dev/packages/url_launcher#configuration)
- [AirGrid subscription design](./subscription-design.md)
