# Play Console — AirGrid Plus setup

**Phase 4 of `subscription-design.md`.** Everything here has to be entered in the
Play Console by hand; this file is the exact spec, and the identifiers below are
a **contract with the code**. A single character out of place produces zero
offers with no error message, which is the most common way a first Billing
integration fails.

App: `com.airgrid.app` · current version `1.0.11+14`

---

## 0. Order of operations

Do these in order. Steps 1–2 are the ones people skip, and skipping them makes
step 5 return nothing.

1. **Payments profile / merchant account** active on the Play Console. Without
   it the Monetise section is not available at all.
2. **Upload a build containing the billing permission to a track** — internal
   testing is enough. `com.android.vending.BILLING` is already merged into the
   manifest by the plugin (verified in the debug build), so any build from the
   current tree qualifies. Products are not queryable until a build declaring
   billing has been processed on a track.
3. Create the subscription and its base plans (§1–2).
4. **Activate** each base plan. A created-but-inactive base plan is silently
   absent from `queryProductDetails`.
5. Add license testers (§4) and verify (§6).

---

## 0.1 Click path

Console labels move between redesigns; the nesting has been stable. If a label
differs, look for the nearest equivalent rather than assuming the feature is
gone.

**Create the subscription**

1. Play Console → select **AirGrid** (`com.airgrid.app`).
2. Left sidebar → **Monetise with Play** → **Products** → **Subscriptions**.
3. **Create subscription**.
4. **Product ID**: `airgrid_plus` — type it carefully. It cannot be renamed, and
   cannot be reused even after deletion. It must equal
   `SubscriptionCatalog.productId`.
5. **Name**: `AirGrid Plus`. Save.

**Add the three base plans** — inside the subscription you just created, under
**Base plans and offers** → **Add base plan**, once per plan:

| Base plan ID | Type | Billing period | Price (AED) | Price (USD approx.) |
|---|---|---|---|---|
| `weekly` | **Prepaid** | 1 week | 0.99 AED | ~$0.27 USD |
| `monthly` | **Prepaid** | 1 month | 1.99 AED | ~$0.54 USD |
| `yearly` | **Prepaid** | 1 year | 11.99 AED | ~$3.26 USD |

These are the prices agreed in `subscription-design.md` §"Final pricing (AED)".
That file is the source of truth; this table exists only so the Console can be
filled in without cross-referencing.

Base plan IDs are also permanent and non-reusable, and must be lowercase
letters/digits/hyphens — no underscores.

**Activate each base plan.** A saved-but-inactive base plan is silently missing
from `queryProductDetails`, and this is the single most common reason a first
integration sees zero products.

**No free trials needed** — all plans are prepaid with clear expiry dates, which
matches AirGrid's offline-first ethos. Users won't get surprised by recurring
charges when they're on hikes or in blackouts without internet access.

**Then**: set regional pricing and review the auto-converted table (§2.4), set
the tax category to digital goods (§4), and add license testers (§4).

---

## 1. Subscription product

Monetise → Products → Subscriptions → Create subscription.

| Field | Value |
|---|---|
| **Product ID** | `airgrid_plus` |
| Name | AirGrid Plus |
| Description | Live voice on the mesh — start private walkie sessions, Rider Mode, and file sharing. Works with no internet. |

> **Public walkie is free and must not be listed here.** It was part of this
> description while it was a paid feature. Advertising a free feature as a
> subscription benefit is both misleading and a Play policy risk. Changing this
> file does not change the store: **edit the description in Play Console too.**

**The product ID is permanent.** It cannot be renamed, and cannot be reused even
after deletion. It must match `SubscriptionCatalog.productId` exactly.

---

## 2. Base plans

One product, three base plans — **not three products**. Play then handles moving
between periods itself: proration, upgrade, downgrade. Three separate products
would mean hand-writing all of that.

Base plan IDs are also permanent and non-reusable, and Play is stricter about
them than about product IDs: **lowercase letters, digits and hyphens only, no
underscores.** `test/core/subscription_catalog_test.dart` pins this.

### 2.1 `weekly`

| Field | Value |
|---|---|
| **Base plan ID** | `weekly` |
| Type | **Prepaid** |
| Billing period | 1 week |
| Price | 0.99 AED |
| Auto-renew | No — prepaid expires |

Prepaid on purpose. Weekly demand here is event-shaped — a festival, a hike, a
blackout — and that buyer does not want a renewal they forget about and then
refund. Auto-renewing weekly plans are also what Play's deceptive-billing
policies scrutinise hardest.

### 2.2 `monthly`

| Field | Value |
|---|---|
| **Base plan ID** | `monthly` |
| Type | **Prepaid** |
| Billing period | 1 month |
| Price | 1.99 AED |
| Auto-renew | No — prepaid expires |

The default buy, and the plan the paywall preselects.

### 2.3 `yearly`

| Field | Value |
|---|---|
| **Base plan ID** | `yearly` |
| Type | **Prepaid** |
| Billing period | 1 year |
| Price | 11.99 AED |
| Auto-renew | No — prepaid expires |

~50% below twelve months of monthly. State the saving on the paywall.

### 2.4 Price anchoring

Weekly at ~50% of monthly keeps monthly the obvious buy (four weeks of weekly is
3.96 AED against 1.99 AED). Yearly at ~6× monthly is a clear discount without
being so cheap it cannibalises monthly outright.

Set the price once, let Play auto-convert to other currencies, then **review the
converted table** — auto-conversion produces odd-looking local prices that are
worth rounding by hand in your main markets.

---

## 3. Offers: none

**Do not add any offer.** All three base plans are prepaid, and Play documents
free trials for auto-renewing plans — a prepaid plan already has a clear expiry
date, which is the thing a trial exists to make safe.

`SubscriptionCatalog._trialBasePlanIds` is empty and
`test/core/subscription_catalog_test.dart` pins it, so an offer added in the
Console would show up in the app as a plan the paywall never mentions.

What softens the landing for existing users — who become gated on update — is
the one-time notice in `lib/features/paywall/plus_change_notice.dart`, not a
trial. Weekly at 0.99 AED is the low-commitment way in.

---

## 4. Tax and testing

**Tax:** declare the app as digital goods/services and set tax categories for
your markets. Confirm whether Play is merchant of record in each target region —
where it is, Play handles VAT collection; where it is not, you do. UAE VAT is
relevant here.

**License testers:** Play Console → Setup → License testing. Add the Gmail
accounts of the test devices.

- Test purchases are not charged.
- Test **durations are compressed** for license testers, so a monthly plan does
  not take a month to expire. Check the current durations in the Console docs
  rather than assuming — they have changed before. This is the practical way to
  exercise expiry and the offline trust window on a real device.
- Testers must also opt in to the internal testing track via its opt-in link,
  and install from that track.
- Avoid testing with the account that owns the developer profile; it behaves
  differently from a normal buyer.

---

## 5. Silent failure modes

Every one of these produces an empty offer list with no error:

| Cause | Check |
|---|---|
| Product ID mismatch | must equal `airgrid_plus` |
| Base plan ID mismatch | must equal `weekly` / `monthly` / `yearly` |
| Base plan created but not **activated** | activate each one |
| No build with billing on any track | upload to internal testing first |
| Build on track still processing | wait for it to finish |
| Test account not opted into the track | use the opt-in link |
| Testing on a device with no Play Store or an old one | billing needs current Play services |

Because this failure is silent, the app does **not** show a blank paywall when it
happens — `loadOffers()` falls back to describing the plans without prices (see
§6), which also means a misconfigured Console looks the same as being offline.
Check the `BILLING` log lines to tell them apart.

---

## 6. Verification

The app logs under the `BILLING` category (`LogCategory.billing`), visible via
the in-app reports screen, so setup can be verified on-device without a debugger.

1. Install from the internal testing track on a license-tester device.
2. Open the paywall. Expect **three plans, in order weekly → monthly → yearly**,
   each with a real localised price, the trial noted on monthly, and weekly shown
   as expiring rather than renewing.
3. If plans appear **without prices**, offers did not load — work through §5. The
   paywall showing plans with no prices is correct behaviour, not a bug: it is
   the same state a genuinely offline user sees.
4. Buy the monthly trial. Expect the entitlement to arrive and gated features to
   unlock.
5. **Turn off all networking and cold-start the app.** Entitlement must persist
   and features must stay unlocked — this is the property the whole design
   exists for.
6. Check that a cancelled subscription downgrades on the next online start.

---

## 7. Not part of this phase

- **Real-time developer notifications** (Pub/Sub) — needs a server; belongs with
  Phase 7 alongside the Netlify verification function.
- **Store listing and privacy policy updates** — required before rollout, but
  they are release work, not product configuration. The privacy policy needs a
  billing-data line, and it must say that the purchase token is the only thing
  sent for verification and is never linked to the mesh node ID.
