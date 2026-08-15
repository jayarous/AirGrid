# AirGrid subscription — design

**Drafted 2026-08-09.** A recommendation, not yet a decision. `main` is at
`e1bbb24`, version `1.0.11+14`, already live on Play with existing users — which
constrains several choices below.

---

## 1. The central tension

A subscription is a *recurring entitlement*. Verifying it needs a network.
AirGrid's reason to exist is working when there is no network. A user on a
five-day hike, in a blackout, or at a festival must never see "we couldn't
verify your subscription" — that is precisely the moment they paid for.

Two consequences drive the whole design:

1. **Entitlement is cached locally and trusted for a long window.** The app
   never blocks on billing, ever.
2. **The trust window scales with the billing period** (§5). A weekly buyer and
   a yearly buyer cannot get the same 30 days of unverified access.

**Decided (2026-08-09): three periods — weekly, monthly, yearly. No lifetime
SKU.** All three resolve to the same internal `Entitlement.plus`, so the tier
plumbing stays period-agnostic and only the trust window reads the period.

**Updated (2026-08-09): all three plans are prepaid (non-renewing).** This matches
the event-driven usage pattern — users buying for festivals, hikes, or blackouts
don't want auto-renewal surprises. The purchase token is cached locally and used
for offline verification within the trust window.

---

## 2. Rules that must not be broken

These are mesh-integrity constraints, not product preferences. Violating any of
them damages the network for paying and free users alike.

| Never gate | Why |
|---|---|
| **Relaying and store-and-forward** | A mesh is only as good as its density. A free tier that doesn't relay makes the paid tier worse. Free devices are infrastructure. |
| **Encryption** | Paywalling `CryptoService` is indefensible and would be the story anyone writes about the app. |
| **Receiving anything** | If a paid sender's message is invisible to free peers, the free user experiences a broken app and blames AirGrid, not the paywall. |
| **Safety numbers / key-change alerts** | Security verification is not a premium feature. |
| **Basic public and private text chat** | Kills the network effect that makes the product work at all. |

The operative rule: **gate the sender, never the receiver, and never the wire.**
Every paid feature must be either purely local or expressible in packet types
free clients already accept. A paid feature that emits a packet type free
clients drop fragments the mesh — and this codebase already knows that pain
(see the staged `senderName` rollout in the README).

---

## 3. Packaging — chat free, live voice paid

**Free — "AirGrid"**
Public mesh chat, private encrypted chat, images, **voice notes**, **public
walkie**, location sharing, safety numbers, recent history, and relaying /
store-and-forward (always, including relaying `audio` packets for paying users).

**Paid — "AirGrid Plus"**

| Feature | Why it's a safe gate |
|---|---|
| **Starting a Private Walkie session** | The differentiated feature. Nothing else does offline PTT. |
| **Rider Mode** | Purely local behaviour (continuous background + battery cost). |
| Longer walkie clips | Sender-side bound. |
| Arbitrary **file** attachments + higher size cap | Sender-side only; receivers already handle `file` packets. |
| **Unlimited history + export** | Local retention only. |

**Public walkie was originally on this list and is not any more.** The gate was
justified partly on mesh health: an 8-hop flood of a 96 KiB clip is the heaviest
traffic the mesh carries, and the limiters count packets, not bytes. That
concern was real, but a paywall was the wrong instrument for it — it bounded
*who* could flood rather than *how much*, and throttled nothing at all for
anyone who paid.

The bound now lives in `AirGridMeshService.sendPublicAudio` as an airtime budget
charged in seconds of audio, applying to every device regardless of tier (see
`AirGridConstants.kPublicAudio*`). Commercially, public walkie is the one live
voice feature that works with strangers and needs no contact list, which makes
it the strongest thing the free tier can offer a user on day one. Re-gating it
would not make the mesh safer — tune the budget instead.

### 3.1 Walkie is a session, not a send — gate the initiator only

This is the part that will break if it's done naively. Private Walkie has
invite/accept session control, so it is inherently **two-sided**. If a free user
cannot *accept* a walkie invite, then a paying user's headline feature only works
when the person they're talking to has also paid. The payer experiences a broken
feature and blames the app, not the paywall.

**Rule: paid users can start a walkie session; free users can accept one and
talk back for its full duration.**

That's not a concession — it's the best conversion funnel available. The free
user experiences the whole feature, in their own hand, with a real person, and
*then* wants to start one themselves. A live demo built into the product beats
any paywall screen.

Corollary: free devices must keep relaying `audio` packets mesh-wide. If a gate
ever reaches relay eligibility, walkie audio breaks for everyone downstream of a
free device — which, on a mesh, is most people. The isolation test in §4 is what
should prevent this; **it has not been written yet**, so this currently rests on
review discipline alone.

### 3.2 Voice notes should stay free

Recommend splitting "voice" rather than gating all of it. A voice note **is a
chat message** — WhatsApp, Signal and Telegram all give them away, so charging
invites exactly that comparison and muddies the otherwise crisp "chat is free"
promise. Walkie is a distinct *mode* that no free app offers offline; that is
what people will actually pay for.

Gating voice notes adds little revenue and costs the clarity of the pitch. If
they're gated anyway, the accept-side rule in §3.1 still applies to walkie.

### 3.3 The install-with-no-peers problem

Independent of pricing: a user who installs AirGrid alone, with no peer in
range, sees nothing work at all. Paywalling walkie on top of that means zero
perceived value at first run. The 7-day trial (§8) partly covers it, but
onboarding needs to communicate value before a second device exists.

Deliberately *not* gated: trusted-contact count (trust is security), receiving
anything, message volume, encryption.

---

## 4. Architecture

Mirror the existing transport pattern exactly — one adapter file is the only
thing that knows Play exists.

```
lib/domain/models/entitlement.dart          Entitlement value object + tier enum
lib/domain/services/entitlement_service.dart Abstract BillingService + state machine
lib/data/billing/play_billing_service.dart   ONLY file importing in_app_purchase
lib/data/storage/entitlement_store.dart      Cached entitlement in secure storage
lib/features/paywall/                        Paywall screen + Riverpod controller
lib/core/feature_gates.dart                  Pure predicates: canSendFile(tier), ...
```

Wire it up in `main.dart` alongside `LocalIdentityStore`,
`SqliteMessageRepository`, `SharedPrefsKnownContactStore` and `CryptoService`.

**`AirGridMeshService` must stay entitlement-blind.** Gate checks live in
`ChatController` and the walkie controller. The mesh service keeps routing
neutral, its tests stay simple, and relay behaviour cannot accidentally become
tier-dependent. Pin this with an architecture test in the style of
`relay_eligibility_test.dart`:

```
test/architecture/entitlement_isolation_test.dart
  asserts mesh_service.dart contains zero references to entitlement/tier/billing
```

Use `in_app_purchase` (Flutter-team maintained, wraps Play Billing) rather than
RevenueCat. RevenueCat is a better DX but routes purchase state through a third
party's servers, which is hard to square with this app's privacy posture and
adds a network dependency to the one subsystem that most needs to degrade
gracefully.

**`minSdk` — checked 2026-08-09.** `android/app/build.gradle.kts:31` uses
`flutter.minSdkVersion`, which this Flutter SDK defines as **24**
(`FlutterExtension.kt:26`), with no override anywhere in the project. The
effective floor is already API 24; Play Billing's floor is below that, so the
dependency should not cost any device that current builds still reach.

Two consequences. The "silently drops devices" hazard for this work is largely
defused — but re-check the resolved value after adding the package rather than
trusting this note. And the README's "API 21 (Android 5.0)" requirement row is
**already wrong**: Android 5 and 6 users stopped getting updates whenever the
Flutter default moved. That is a documentation defect to fix on its own merits.

---

## 5. Entitlement state machine

Cache `{tier, productId, purchaseToken, expiryMillis, lastVerifiedAt,
maxClockSeen}` in `FlutterSecureStorage` (same store discipline as
`LocalIdentityStore`, including a migration path).

States:

- **`active`** — verified within the trust window, not expired.
- **`offlineTrusted`** — was active, cannot reach Play, still inside the offline
  trust window. **Full paid access.**
- **`lapsed`** — expired *and* the trust window has elapsed. Downgrade to free.

Rules:

- **Offline trust window scales with the billing period**, since three periods
  now exist and a one-week purchase must not buy a month of unverified access:

  | Period   | Window | Price    |
  |----------|--------|----------|
  | Weekly   | 7 days | 0.99 AED |
  | Monthly  | 30 days| 1.99 AED |
  | Yearly   | 30 days| 11.99 AED|

**Note:** All plans are prepaid (non-renewing). The trust window applies to the
cached purchase token for offline verification. Yearly provides ~84% savings vs.
buying weekly for the same period, and ~6× the monthly price for a 30-day window.

  Floor of 7 days in every case — enough to cover a festival, a hike or a
  blackout. Someone who expects to be off-grid for three weeks should be buying
  monthly, and the paywall copy can say so plainly. Store the period on the
  cached entitlement so this is computable offline.

  Generous on purpose: the cost of a false downgrade (a user losing paid
  features mid-emergency) vastly exceeds the unpaid access it prevents.
- **Never downgrade mid-session.** Re-evaluate at cold start only.
- **Never block the UI on billing.** Query Play asynchronously after startup;
  if it never answers, nothing changes.
- Don't rely on Play Store's own purchase cache as an offline guarantee — it is
  not documented as one. Keep your own.
- **Clock rollback:** store the highest timestamp ever observed. If the current
  clock is behind it, don't *extend* the trust window — but don't punish either.
  A wrong clock is far more often a wrong clock than a pirate.

Anti-piracy beyond this is not worth the engineering. The realistic loss is
rounding error; the realistic cost of over-enforcement is one-star reviews from
users whose paid app locked up in a tunnel.

---

## 6. Receipt verification

Client-side only is acceptable to start, and is where I'd begin — but two hard
limits of the Android client, both found while building `PlayBillingService`,
turn the server function from polish into the thing that makes entitlement
*exact*:

- **Play never tells the client when a subscription ends.** `PurchaseDetails`
  carries no expiry; only the Play Developer API does. What stands in for it is
  that Play returns *only currently active* subscriptions from a purchase query,
  so a purchase being present proves "active right now". `Entitlement.expiresAt`
  stays null and the trust window does the work, with a fresh confirmation (<24h)
  reading as `active`.
- **Play never tells the client which base plan was bought.** So a restore after
  reinstall cannot tell weekly from yearly — and the trust window is
  period-scaled. Mitigated two ways: the period is captured at purchase time
  (the one moment it is knowable), and `reconcile` carries a cached period
  forward when the purchase token matches. Failing both, the window falls back
  to the seven-day floor, which under-grants rather than over-grants.

Neither is a defect in the implementation; both are the documented shape of
client-side Play Billing. Server verification is what removes them.

If you want server verification later, you already have Netlify hosting the
privacy policy. A single Netlify Function calling the Play Developer API
(`purchases.subscriptionsv2.get`) is enough, costs nothing, and keeps the "no
server for messaging" promise intact — only *billing* touches a server, never
the mesh.

**Hard privacy constraint: never send `nodeId` to the verification endpoint.**
Send the purchase token and nothing else. Linking a payment identity to a mesh
node ID would deanonymise users on the mesh and would undo the anonymity the
architecture is built to provide. This deserves an explicit comment in the code
and a line in the privacy policy.

---

## 7. Existing users

`1.0.11+14` is live, and Rider Mode and public walkie already ship free.
Retroactively paywalling features people already have earns exactly the reviews
you'd expect.

**Public walkie has since been returned to the free tier**, so of the two only
Rider Mode is still taken away from an existing user on update.

**Grandfather them.** On first launch of the billing-enabled build, if a
pre-existing install is detected (identity already present in
`LocalIdentityStore`, or a persisted "first seen version" below the billing
release), write a permanent local `legacyUnlock` flag granting Plus. It costs
almost nothing — your existing base is small relative to the future one — and it
converts a group of annoyed users into advocates.

---

## 8. Play Console work

**One subscription product, three base plans — not three products.** Create a
single `airgrid_plus` subscription with weekly, monthly and yearly base plans.
Play then handles switching between them (proration, upgrade, downgrade) itself.
Three separate products means writing all of that migration logic by hand, and
it's the most common structural mistake in a first Play Billing integration.

**All plans are prepaid (non-renewing).** This matches the event-driven usage
pattern — users buying for festivals, hikes, or blackouts don't want auto-renewal
surprises. Play's prepaid base plans expire instead of renewing, which matches
the intent exactly. Auto-renewing plans are also the pattern Play's deceptive-
billing policies scrutinise hardest.

**Final pricing (AED):**
- Weekly: **0.99 AED** (~$0.27) — Entry point for short events
- Monthly: **1.99 AED** (~$0.54) — Revenue anchor, ~50% of yearly per 30 days
- Yearly: **11.99 AED** (~$3.26) — Power user option, ~84% savings vs. weekly

The paywall should clearly state the savings: "Yearly saves you 84% compared to
weekly plans" or equivalent messaging per region.

- Declare Play Billing with prepaid base plans only (no auto-renewal).
- Regional pricing and tax setup for all three tiers.
- Regional pricing and tax setup.
- Handle cancellation, refund and revocation.
- Note Play's own "grace period" and "account hold" are payment-failure states,
  distinct from the offline trust window above. Don't conflate them in code —
  name ours `offlineTrustWindow`.
- The store listing and privacy policy both need updating before rollout.

---

## 9. Testing

The suite is at 546 passing with a strict CI gate; keep it that way.

- `FakeBillingService` implementing the abstract interface — no test touches Play.
- State-machine tests with an **injected clock**: expiry, trust-window edges,
  rollback, offline-at-startup, restore-after-reinstall.
- Widget tests for paywall presentation and for each gated entry point.
- The architecture isolation test from §4.
- Deterministic UUID fixtures, per existing convention.

---

## 10. Suggested order

1. `Entitlement` model, `feature_gates.dart`, `FakeBillingService`, full test
   coverage. No Play dependency yet — the whole state machine lands testable.
2. `EntitlementStore` in secure storage, with migration.
3. Gate call sites in the controllers; grandfathering flag. Ship this build
   **before** billing exists, so the legacy flag is already written for current
   users.
4. `in_app_purchase` + `PlayBillingService`. Verify `minSdk` here.
5. Paywall UI.
6. Play Console products; internal testing track.
7. Optional: Netlify verification function.

Step 3 shipping ahead of step 4 is the important ordering detail — it means the
grandfather flag is in the field before the paywall is.

---

## 11. Open decisions for Jay

**Settled (2026-08-09):**
- Chat free / live voice paid
- Weekly + monthly + yearly periods
- No lifetime SKU
- **All three plans are prepaid (non-renewing)**
- Pricing: Weekly 0.99 AED, Monthly 1.99 AED, Yearly 11.99 AED

**Still open:**

1. **Voice notes free or paid?** §3.2 recommends free.
2. **Client-side verification only at launch, or Netlify function from day one?**

Non-negotiable regardless: free users can accept and fully participate in a
walkie session they didn't start (§3.1), and free devices keep relaying `audio`
(§3.1, §4). Both are load-bearing for the paid experience.
