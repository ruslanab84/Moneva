# Free tier with ads + Pro — design

Status: draft for review (2026-10-09). No code written yet.

## Intent

Monetize Ledgea (Moneva) with a free tier that shows ads and a paid **Pro** tier that removes ads and unlocks power features. Ads are mandatory for Free (owner decision). Basic money tracking must never be paywalled; Pro sells power (AI, forecasts), sharing (family) and time-saving (import, multi-account).

Decisions made by the owner:

| Decision | Choice |
|---|---|
| Ad privacy mode | AdMob, non-personalized, **no ATT** (UMP consent for EEA/UK only) |
| Pro sales model | Monthly + yearly subscription **and** lifetime, one entitlement `pro` |
| Ad format / placement | Anchored adaptive **banner** at the bottom, on Home and Transactions only |
| Architecture | Approach A: pure-enum limits + StoreKit 2 `ProStore` + single `AdBanner` |
| Rule change | CLAUDE.md / AGENTS.md may be relaxed for ad SDK + StoreKit (see Rules) |

## Free vs Pro

**Free (with ads):** manual income/expense transactions, categories, personal scope, simple budget, month totals and category chart, 1 account, CSV export, subscriptions (max 5), goals (max 2), AI receipt scan + voice entry (max 5 per calendar month combined).

**Pro (no ads):** family sharing (CloudKit), Ask/Search/Explain, Smart Insights, forecast, daily limit, budget rollover, subcategories, recurring income, CSV import, multiple accounts and transfers, unlimited subscriptions/goals/AI scans.

Hard rules:
- Limits apply to **creation only**. Existing data is never deleted, hidden or made read-only; a user with 8 subscriptions can still view, edit and delete them.
- Pro expiry stops family sync but keeps all local data.
- Pro-only features stay visible with a lock and open the paywall; they are not hidden. Hardware-unsupported AI stays hidden via the existing `OnDeviceAI.isSupported` gate (device gate first, then Pro gate).
- The ad SDK never receives app data. `AdBanner` takes a size only; no models, `ModelContext`, text or amounts.

## Components

| Component | Role |
|---|---|
| `ProLimits` (pure enum, `Shared/Core`) | Free limits as constants; `canCreate(_:count:isPro:)`, `canUseAI(usedThisMonth:isPro:)`, `ProFeature` set. No UI, no StoreKit. |
| `ProStore` (`@MainActor @Observable`) | StoreKit 2: loads products, reads `Transaction.currentEntitlements`, listens to `Transaction.updates`, exposes `isPro`. Injected via environment. |
| `AIUsage` | Monthly scan/voice counter in `UserDefaults`, key `yyyy-MM`, month via `Calendar`. Increments when a draft is **saved**, not when the screen opens. No SwiftData change. Reinstall resets it (accepted; `ponytail:` note in code). |
| `AdBanner` | Wraps the AdMob anchored adaptive banner. Collapses to zero height on no-fill/offline. |
| `PaywallView` | One sheet: monthly, yearly, lifetime (prices from `Product.displayPrice`), Restore, auto-renewal text, terms/privacy links. |

## Banner placement

One banner in `RootView`, not per screen: `TabView` gets a `selection` and `Tab(value:)` tags; `.safeAreaInset(edge: .bottom) { AdBanner() }` is shown when `selection` is Home or Transactions and `!isPro`. The FAB overlay is attached to the `TabView`, so the inset should shrink its area and lift the FAB without touching the existing `padding(.bottom, 96)`. **This is a hypothesis about iOS 26 layout; verify in the simulator.** Fallback: per-screen `safeAreaInset` in `HomeView`/`TransactionsView` and raise the FAB padding by the banner height.

Debug builds use Google's test ad unit IDs only; real IDs live in the Release configuration. Buying Pro hides the banner immediately (`isPro` is observable).

## Consent and privacy

- Google UMP runs at launch; ads load only after `canRequestAds`. Non-EEA/UK users see no form.
- No ATT prompt, no `NSUserTrackingUsageDescription`. Non-personalized requests are set via the request parameter; the exact API is confirmed against current AdMob docs at plan time.
- New dependency: Google Mobile Ads SDK (SPM). `Info.plist` gets `GADApplicationIdentifier` and the SKAdNetwork identifier list.
- App Store privacy labels are updated from Google's official SDK data-disclosure list at plan time; they are not guessed here.

## Gating call sites

Limits (create only):

| Limit | Site |
|---|---|
| Subscriptions 5 | `SubscriptionsView.swift` new-button before `isCreating = true`; voice drafts in `VoiceCaptureView.swift` (draft → `SubscriptionEditorView`) |
| Goals 2 | `GoalsView.swift` "New goal" |
| Accounts 1 | `AccountsView.swift` "New account" |
| AI scans/voice 5 per month | `RootView.swift` `isScanning` / `isSpeaking` buttons; counter bumped on save |

Pro-only: `HomeAskCard` (`HomeView.swift`), `SpendingAssistantView` (`TransactionsView.swift`), `CloudSharingSheet` (`SettingsView.swift`), `StatementImportView` (`SettingsView.swift`). Smart Insights, forecast, daily limit, rollover, transfers, recurring income and subcategories are located at plan time (spread across Budget and Home).

When a check fails, `PaywallView` opens instead of the editor. Paywall entry points: hitting a limit, tapping a lock, and an "Upgrade to Pro" row in Settings. The banner never opens the paywall itself.

## Rules change (owner approved)

CLAUDE.md and AGENTS.md currently say no analytics/remote. Replace with: network code is allowed only for AdMob and StoreKit; uploading financial data, receipt images, voice transcripts or OCR text remains forbidden. Applied as its own commit during implementation.

## Testing

In `monevaSelfCheck()` (no new test target):
- `ProLimits` boundaries: subscriptions at 4/5/6 (creation closed at 5), `isPro` always allowed.
- Already-over-limit data (8 subscriptions) does not block view/edit.
- `AIUsage`: 31 Jan → 1 Feb resets via `Calendar`; +1 after a save.
- `ProFeature` set is closed for Free, open for Pro.

Manual in simulator with a `.storekit` configuration: purchase, restore, banner disappears, FAB not covered, limit opens paywall. Real AdMob fill and Foundation Models behaviour cannot be verified in the simulator and need a physical device.

## Implementation order

1. `ProLimits`, `AIUsage`, asserts.
2. `ProStore`, `PaywallView`, `.storekit` file.
3. Gating of limits and Pro-only features.
4. AdMob SDK, UMP consent, `AdBanner` in `RootView`.
5. CLAUDE.md/AGENTS.md update, privacy labels.

## Out of scope

Rewarded ads, interstitials, ATT/personalized ads, house ads, server-side receipt validation, remote config for limits, A/B tests.
