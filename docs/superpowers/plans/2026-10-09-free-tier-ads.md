# Free Tier with Ads + Pro Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Free tier (AdMob banner, creation limits) and a Pro tier (subscription or lifetime, no ads, power features) in Ledgea/Moneva.

**Architecture:** Pure enums (`ProLimits`, `AIUsage`) decide what Free may do; an `@Observable ProStore` (StoreKit 2) owns `isPro` and is injected through the environment; one `.proGated()` modifier locks Pro-only UI and opens one `PaywallView`; one `AdBanner` in `RootView` shows on Home/Transactions when not Pro. Views read `@Query`/`@Environment` directly (no view-model layer, per CLAUDE.md).

**Tech Stack:** SwiftUI, SwiftData, StoreKit 2, Google Mobile Ads SDK (SPM) + UMP, Swift 5.0, iOS 26.5.

**Spec:** `docs/superpowers/specs/2026-10-09-free-tier-ads-design.md`

## Global Constraints

- Local-only except two sanctioned network uses: AdMob banner and StoreKit. Never send transactions, amounts, categories, receipt images, voice transcripts or OCR text to any SDK. `AdBanner` takes no app data.
- Free limits (verbatim from spec): subscriptions **5**, goals **2**, accounts **1**, AI receipt-scan + voice entry **5 per calendar month combined**. Limits apply to **creation only**; existing data is never deleted, hidden or made read-only.
- Ads: AdMob anchored adaptive banner, **non-personalized, no ATT** (no `NSUserTrackingUsageDescription`), UMP consent for EEA/UK. Banner on **Home and Transactions only**, never on Add flow. Debug builds use Google test ad IDs only.
- Pro: one entitlement; products `RuslanAbd.Moneva.pro.monthly`, `.yearly`, `.lifetime` (create in App Store Connect before release). Prices from `Product.displayPrice`, never hardcoded.
- Money is `Decimal`, dates via `Calendar` (CLAUDE.md). Business rules live in pure enums, not view bodies. Commits: short imperative subject, then a blank line and `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- **Name clash:** the app has a SwiftData model `Transaction`. In any file that imports StoreKit, write `StoreKit.Transaction` (a bare `Transaction` resolves to the app model).
- New `Text("...")` literals are picked up by `Localizable.xcstrings` on build; leave ru/az translations for the owner.
- Foundation Models and real AdMob fill do not run in the simulator; say so in every report instead of claiming them verified.

**Verification commands** (referenced as "Build" and "Launch check" below):

- Build: `xcodebuild -project Moneva.xcodeproj -scheme Moneva -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | grep -E "error:|BUILD"` — require an explicit `BUILD SUCCEEDED`; empty output is unconfirmed, retry once.
- Launch check (DEBUG self-checks run at launch): `xcrun simctl list devices booted` → pick the booted iOS 26.5 device `<UDID>`; `xcodebuild -project Moneva.xcodeproj -scheme Moneva -destination "id=<UDID>" -configuration Debug -derivedDataPath <scratchpad>/dd build 2>&1 | grep -E "error:|BUILD"`; `xcrun simctl install <UDID> <scratchpad>/dd/Build/Products/Debug-iphonesimulator/Moneva.app`; `xcrun simctl launch <UDID> <bundle id>`; wait ~6 s; `xcrun simctl spawn <UDID> launchctl list | grep -i moneva` shows a live PID and no new `Moneva-*.ips` in `~/Library/Logs/DiagnosticReports`. Delete the scratch derived data afterwards.

## Review Focus

1. A user already over a limit (8 subscriptions) must still see, edit and delete them; only "add" is blocked (pinned in Task 1 asserts, enforced by gating only creation buttons in Task 3).
2. Monthly AI counter across month and year boundaries (31 Jan → 1 Feb, 31 Dec → 1 Jan) with an explicit `Calendar`, not `.current` (Task 1 asserts).
3. Purchase edge cases: user cancels, purchase is pending (Ask to Buy), transaction unverified, or entitlement revoked/refunded must not set or keep `isPro`; cancel/pending show no error (Task 2 `ProStore.unlocks` asserts + manual StoreKit test).
4. Banner must not cover FAB, tab content or the Add flow, and must collapse to zero height with no fill/offline (Task 5 manual simulator check + fallback).
5. A Free user opening the app after being Pro must not see a banner flash or a lock flash at launch (Task 2 caches `isPro` in `UserDefaults` as the initial value).

---

### Task 1: ProLimits, AIUsage and asserts

**Files:**
- Create: `Moneva/Pro/Core/ProLimits.swift`
- Create: `Moneva/Pro/Core/AIUsage.swift`
- Create: `Moneva/Pro/Core/ProSelfCheck.swift`
- Modify: `Moneva/Budget/Core/Budgeting.swift:751` (add the call after `familySyncSelfCheck()`)

**Interfaces:**
- Produces: `enum AppTab { home, transactions, budget, goals, subs }`; `ProLimits.canCreate(_ kind: ProLimits.Limited, count: Int, isPro: Bool) -> Bool`; `ProLimits.canUseAI(usedThisMonth: Int, isPro: Bool) -> Bool`; `ProLimits.showsBanner(tab: AppTab, isPro: Bool) -> Bool`; `AIUsage.count(now:calendar:defaults:) -> Int`; `AIUsage.record(now:calendar:defaults:)`; `proSelfCheck()`.

- [ ] **Step 1: Write the failing asserts**

Create `Moneva/Pro/Core/ProSelfCheck.swift`:

```swift
import Foundation

/// Regression net for the free-tier rules (CLAUDE.md: asserts here, not a test target).
func proSelfCheck() {
    // Creation limits: open below the limit, closed at it, Pro always open.
    for count in 0...4 { assert(ProLimits.canCreate(.subscription, count: count, isPro: false), "subscription \(count) of 5 is allowed") }
    assert(!ProLimits.canCreate(.subscription, count: 5, isPro: false), "the sixth subscription needs Pro")
    assert(!ProLimits.canCreate(.subscription, count: 8, isPro: false), "an already-over-limit user can't add, but nothing removes theirs")
    assert(ProLimits.canCreate(.subscription, count: 8, isPro: true), "Pro has no subscription limit")
    assert(ProLimits.canCreate(.goal, count: 1, isPro: false) && !ProLimits.canCreate(.goal, count: 2, isPro: false), "two free goals")
    assert(ProLimits.canCreate(.account, count: 0, isPro: false) && !ProLimits.canCreate(.account, count: 1, isPro: false), "one free account")
    assert(ProLimits.canCreate(.account, count: 9, isPro: true), "Pro has no account limit")

    // AI allowance.
    assert(ProLimits.canUseAI(usedThisMonth: 4, isPro: false) && !ProLimits.canUseAI(usedThisMonth: 5, isPro: false), "five AI entries a month")
    assert(ProLimits.canUseAI(usedThisMonth: 500, isPro: true), "Pro AI is unlimited")

    // Banner only on Home and Transactions, never for Pro.
    assert(ProLimits.showsBanner(tab: .home, isPro: false) && ProLimits.showsBanner(tab: .transactions, isPro: false))
    assert(!ProLimits.showsBanner(tab: .budget, isPro: false) && !ProLimits.showsBanner(tab: .goals, isPro: false) && !ProLimits.showsBanner(tab: .subs, isPro: false))
    assert(!ProLimits.showsBanner(tab: .home, isPro: true), "Pro never sees the banner")

    // Monthly counter: resets on a new month and across a year boundary.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let suite = "proSelfCheck"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let jan31 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 23, minute: 59))!
    let feb1 = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
    let dec31 = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23))!
    let jan1 = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
    assert(AIUsage.count(now: jan31, calendar: calendar, defaults: defaults) == 0)
    AIUsage.record(now: jan31, calendar: calendar, defaults: defaults)
    AIUsage.record(now: jan31, calendar: calendar, defaults: defaults)
    assert(AIUsage.count(now: jan31, calendar: calendar, defaults: defaults) == 2, "two saves in January")
    assert(AIUsage.count(now: feb1, calendar: calendar, defaults: defaults) == 0, "February starts at zero")
    AIUsage.record(now: dec31, calendar: calendar, defaults: defaults)
    assert(AIUsage.count(now: jan1, calendar: calendar, defaults: defaults) == 0, "a new year starts at zero")
    assert(AIUsage.count(now: dec31, calendar: calendar, defaults: defaults) == 1, "December keeps its own count")
    defaults.removePersistentDomain(forName: suite)
}
```

In `Moneva/Budget/Core/Budgeting.swift`, directly after the line `familySyncSelfCheck()` (currently line 751) add:

```swift
    proSelfCheck()
```

- [ ] **Step 2: Run Build to verify it fails**

Run: Build
Expected: FAIL with `cannot find 'ProLimits' in scope` / `cannot find 'AIUsage' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Moneva/Pro/Core/ProLimits.swift`:

```swift
import Foundation

/// The tabs, so "which tab shows the banner" can be a pure, asserted rule.
enum AppTab: Hashable { case home, transactions, budget, goals, subs }

/// Free-tier limits. Pure: no StoreKit, no UI. Every limit is about *creating*;
/// nothing here removes or hides data the user already has.
enum ProLimits {
    enum Limited { case subscription, goal, account }

    static let freeSubscriptions = 5
    static let freeGoals = 2
    static let freeAccounts = 1
    static let freeAIPerMonth = 5

    static func limit(_ kind: Limited) -> Int {
        switch kind {
        case .subscription: return freeSubscriptions
        case .goal: return freeGoals
        case .account: return freeAccounts
        }
    }

    static func canCreate(_ kind: Limited, count: Int, isPro: Bool) -> Bool {
        isPro || count < limit(kind)
    }

    static func canUseAI(usedThisMonth: Int, isPro: Bool) -> Bool {
        isPro || usedThisMonth < freeAIPerMonth
    }

    static func showsBanner(tab: AppTab, isPro: Bool) -> Bool {
        !isPro && (tab == .home || tab == .transactions)
    }
}
```

Create `Moneva/Pro/Core/AIUsage.swift`:

```swift
import Foundation

/// Free scan/voice entries used this calendar month. The month is part of the
/// key, so a new month starts at zero with no reset code.
// ponytail: UserDefaults is wiped by a reinstall, which resets the allowance.
// Upgrade path: iCloud key-value store if abuse ever matters.
enum AIUsage {
    static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "aiUsage.%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func count(now: Date = .now, calendar: Calendar = .current, defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: key(for: now, calendar: calendar))
    }

    static func record(now: Date = .now, calendar: Calendar = .current, defaults: UserDefaults = .standard) {
        defaults.set(count(now: now, calendar: calendar, defaults: defaults) + 1, forKey: key(for: now, calendar: calendar))
    }
}
```

- [ ] **Step 4: Run Build and Launch check to verify it passes**

Run: Build, then Launch check.
Expected: `BUILD SUCCEEDED`; live PID, no new `.ips` (asserts passed).

- [ ] **Step 5: Commit**

```bash
git add Moneva/Pro Moneva/Budget/Core/Budgeting.swift
git commit -m "Add free-tier limits and monthly AI usage counter" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: ProStore, PaywallView, ProGate

**Files:**
- Create: `Moneva/Pro/Core/ProStore.swift`
- Create: `Moneva/Pro/Views/PaywallView.swift`
- Create: `Moneva/Pro/Views/ProGate.swift`
- Create: `Moneva/Pro/Moneva.storekit` (via Xcode, see Step 1)
- Modify: `Moneva/App/MonevaApp.swift` (inject store), `Moneva/Settings/Views/SettingsView.swift` (Upgrade row), `Moneva/Pro/Core/ProSelfCheck.swift`

**Interfaces:**
- Consumes: `ProLimits` from Task 1.
- Produces: `ProStore` (`@MainActor @Observable`): `isPro: Bool`, `products: [Product]`, `purchase(_:) async -> String?` (returns an error message or nil), `restore() async -> String?`, `static func unlocks(productID: String, isRevoked: Bool) -> Bool`; `PaywallView()`; `View.proGated() -> some View`. Everything reads the store via `@Environment(ProStore.self)`.

**Owner input needed before this task is finished:** the public privacy-policy URL for the paywall footer. Put it in `PaywallLinks.privacy` (Step 4). Do not ship a placeholder URL; stop and ask the owner if it is not known.

- [ ] **Step 1: Create the StoreKit test configuration (Xcode UI, one-time)**

In Xcode: File ▸ New ▸ File ▸ StoreKit Configuration File → save as `Moneva/Pro/Moneva.storekit` (uncheck "Sync with App Store Connect"). Add a **subscription group** "Ledgea Pro" with auto-renewable `RuslanAbd.Moneva.pro.monthly` (1 month) and `RuslanAbd.Moneva.pro.yearly` (1 year), plus a **non-consumable** `RuslanAbd.Moneva.pro.lifetime`; set any test prices. Edit Scheme ▸ Run ▸ Options ▸ StoreKit Configuration → `Moneva.storekit`.

- [ ] **Step 2: Write the failing assert**

Append to the end of `proSelfCheck()` in `Moneva/Pro/Core/ProSelfCheck.swift` (before the closing brace):

```swift

    // Entitlements: only our products unlock, and a revoked/refunded one never does.
    assert(ProStore.unlocks(productID: "RuslanAbd.Moneva.pro.monthly", isRevoked: false))
    assert(ProStore.unlocks(productID: "RuslanAbd.Moneva.pro.lifetime", isRevoked: false))
    assert(!ProStore.unlocks(productID: "RuslanAbd.Moneva.pro.yearly", isRevoked: true), "a refund takes Pro away")
    assert(!ProStore.unlocks(productID: "com.other.product", isRevoked: false), "an unknown product never unlocks Pro")
```

Run: Build. Expected: FAIL `cannot find 'ProStore' in scope`.

- [ ] **Step 3: Implement ProStore**

Create `Moneva/Pro/Core/ProStore.swift`:

```swift
import StoreKit
import Observation

/// Single source of truth for "is this user Pro". One entitlement covers the
/// subscriptions and the lifetime purchase. Note `StoreKit.Transaction`: a bare
/// `Transaction` is the app's SwiftData model.
@MainActor @Observable
final class ProStore {
    static let productIDs = [
        "RuslanAbd.Moneva.pro.monthly",
        "RuslanAbd.Moneva.pro.yearly",
        "RuslanAbd.Moneva.pro.lifetime",
    ]
    private static let cacheKey = "pro.cachedIsPro"

    /// Starts from the last known answer so a Pro user sees no banner/lock flash at launch.
    private(set) var isPro = UserDefaults.standard.bool(forKey: ProStore.cacheKey)
    private(set) var products: [Product] = []
    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task {
            await loadProducts()
            await refresh()
        }
    }

    deinit { updates?.cancel() }

    nonisolated static func unlocks(productID: String, isRevoked: Bool) -> Bool {
        !isRevoked && productIDs.contains(productID)
    }

    func loadProducts() async {
        let loaded = (try? await Product.products(for: Self.productIDs)) ?? []
        products = loaded.sorted { (Self.productIDs.firstIndex(of: $0.id) ?? 0) < (Self.productIDs.firstIndex(of: $1.id) ?? 0) }
    }

    func refresh() async {
        var pro = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               Self.unlocks(productID: transaction.productID, isRevoked: transaction.revocationDate != nil) {
                pro = true
            }
        }
        isPro = pro
        UserDefaults.standard.set(pro, forKey: Self.cacheKey)
    }

    /// Returns a user-facing error, or nil on success, cancel or pending (those are not errors).
    func purchase(_ product: Product) async -> String? {
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return String(localized: "The purchase could not be verified.") }
                await transaction.finish()
                await refresh()
                return nil
            case .userCancelled, .pending:
                return nil
            @unknown default:
                return nil
            }
        } catch {
            return error.localizedDescription
        }
    }

    func restore() async -> String? {
        do {
            try await AppStore.sync()
            await refresh()
            return isPro ? nil : String(localized: "No previous purchase found for this Apple ID.")
        } catch {
            return error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Implement PaywallView and ProGate**

Create `Moneva/Pro/Views/PaywallView.swift`:

```swift
import SwiftUI
import StoreKit

enum PaywallLinks {
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// Owner supplies the real policy URL (App Store requires one). Replace before shipping.
    static let privacy = URL(string: "OWNER_PRIVACY_POLICY_URL")!
}

struct PaywallView: View {
    @Environment(ProStore.self) private var pro
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("No ads", systemImage: "nosign")
                    Label("Family sharing", systemImage: "person.2")
                    Label("Ask, search and explain your spending", systemImage: "sparkles")
                    Label("Forecast, insights and daily limit", systemImage: "chart.line.uptrend.xyaxis")
                    Label("Unlimited subscriptions, goals and accounts", systemImage: "infinity")
                    Label("Unlimited receipt scans and voice entries", systemImage: "doc.viewfinder")
                    Label("Statement import, budget carry-over, subcategories", systemImage: "tablecells")
                } header: {
                    Text("Ledgea Pro")
                }

                Section {
                    if pro.products.isEmpty {
                        Text("Prices are not available right now. Check your connection and try again.")
                            .foregroundStyle(Palette.inkMuted)
                    }
                    ForEach(pro.products) { product in
                        Button {
                            Task { await buy(product) }
                        } label: {
                            LabeledContent(product.displayName) { Text(product.displayPrice).fontWeight(.semibold) }
                        }
                        .disabled(busy)
                    }
                    Button("Restore purchases") { Task { await restore() } }.disabled(busy)
                } footer: {
                    Text("Subscriptions renew automatically unless cancelled at least 24 hours before the period ends. Manage or cancel in Settings ▸ Apple ID ▸ Subscriptions. Lifetime is a one-time purchase.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(Palette.over) }
                }

                Section {
                    Link("Terms of Use", destination: PaywallLinks.terms)
                    Link("Privacy Policy", destination: PaywallLinks.privacy)
                }
            }
            .navigationTitle("Upgrade to Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: pro.isPro) { _, isPro in if isPro { dismiss() } }
        }
        .tint(Palette.accent)
    }

    private func buy(_ product: Product) async {
        busy = true
        defer { busy = false }
        message = await pro.purchase(product)
    }

    private func restore() async {
        busy = true
        defer { busy = false }
        message = await pro.restore()
    }
}
```

Replace `OWNER_PRIVACY_POLICY_URL` with the real URL the owner gives you. Stop and ask if it is missing: `URL(string:)` accepts the placeholder text as a relative URL, so it would compile and ship a dead link without any warning.

Create `Moneva/Pro/Views/ProGate.swift`:

```swift
import SwiftUI

/// Locks Pro-only UI for Free users: dimmed, a lock badge, and any tap opens the paywall.
/// Pro users get the content untouched.
struct ProGate: ViewModifier {
    @Environment(ProStore.self) private var pro
    @State private var isPaywall = false

    func body(content: Content) -> some View {
        if pro.isPro {
            content
        } else {
            content
                .allowsHitTesting(false)
                .opacity(0.55)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Palette.accent)
                        .padding(6)
                }
                .overlay { Color.clear.contentShape(Rectangle()).onTapGesture { isPaywall = true } }
                .accessibilityHint("Requires Pro")
                .sheet(isPresented: $isPaywall) { PaywallView() }
        }
    }
}

extension View {
    func proGated() -> some View { modifier(ProGate()) }
}
```

- [ ] **Step 5: Inject the store and add the Settings upgrade row**

In `Moneva/App/MonevaApp.swift` add `@State private var pro = ProStore()` under `private let container: ModelContainer`, and add `.environment(pro)` on the line after `RootView()` (before the `#if DEBUG` `.task`).

In `Moneva/Settings/Views/SettingsView.swift`, inside the view add `@Environment(ProStore.self) private var pro` and `@State private var isPaywall = false`; as the first `Section` of the `Form` add:

```swift
                if !pro.isPro {
                    Section {
                        Button("Upgrade to Pro", systemImage: "sparkles") { isPaywall = true }
                    }
                }
```

and next to the existing `.sheet(item: $activeShare)` add `.sheet(isPresented: $isPaywall) { PaywallView() }`.

- [ ] **Step 6: Run Build and Launch check**

Run: Build, then Launch check.
Expected: `BUILD SUCCEEDED`; live PID, no new `.ips`.

- [ ] **Step 7: Manual StoreKit check (simulator with the `.storekit` scheme option)**

Settings ▸ Upgrade to Pro opens the paywall with three priced products. Buy monthly: sheet closes, row disappears. Debug ▸ StoreKit ▸ Manage Transactions: refund it → `isPro` returns to false (Settings row reappears after relaunch/refresh). Cancel a purchase: no error text. Restore with nothing bought shows "No previous purchase found…".

- [ ] **Step 8: Commit**

```bash
git add Moneva/Pro Moneva/App/MonevaApp.swift Moneva/Settings/Views/SettingsView.swift Moneva.xcodeproj
git commit -m "Add Pro store, paywall and lock modifier" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Gate creation limits (subscriptions, goals, accounts, AI)

**Files:**
- Modify: `Moneva/Subscriptions/Views/SubscriptionsView.swift` (lines ~55, ~82, `creating =` sites, sheets at ~90)
- Modify: `Moneva/Goals/Views/GoalsView.swift:32`
- Modify: `Moneva/Accounts/Views/AccountsView.swift:31`
- Modify: `Moneva/App/RootView.swift` (scan and mic buttons)
- Modify: `Moneva/AI/Views/ReceiptScanView.swift:271`, `Moneva/AI/Views/VoiceCaptureView.swift` (lines ~179, ~242, ~302, ~311)

**Interfaces:**
- Consumes: `ProLimits.canCreate`, `ProLimits.canUseAI`, `AIUsage.count()`, `AIUsage.record()`, `PaywallView`, `ProStore`.
- Produces: no new API; behavior only.

- [ ] **Step 1: Subscriptions**

In `SubscriptionsView` add `@Environment(ProStore.self) private var pro` and `@State private var isPaywall = false` with the other state, plus:

```swift
    private var canAddSubscription: Bool {
        ProLimits.canCreate(.subscription, count: subscriptions.count, isPro: pro.isPro)
    }
```

Change the "Add from text or voice" button (line ~55) to:

```swift
                    Button("Add from text or voice", systemImage: "sparkles") {
                        if canAddSubscription && ProLimits.canUseAI(usedThisMonth: AIUsage.count(), isPro: pro.isPro) { isSmartCreating = true }
                        else { isPaywall = true }
                    }
```

Change the toolbar "Add" button (line ~82) to `{ if canAddSubscription { isCreating = true } else { isPaywall = true } }`. Run `grep -n "creating = " Moneva/Subscriptions/Views/SubscriptionsView.swift` and wrap every assignment of the detected-subscription state (`creating = <value>`) the same way: `if canAddSubscription { creating = <value> } else { isPaywall = true }`. Add next to the other sheets:

```swift
            .sheet(isPresented: $isPaywall) { PaywallView() }
```

Editing, pausing and deleting existing subscriptions stay untouched.

- [ ] **Step 2: Goals and Accounts**

`GoalsView`: add `@Environment(ProStore.self) private var pro`, `@State private var isPaywall = false`; change line 32 to:

```swift
            Button("New goal", systemImage: "plus") {
                if ProLimits.canCreate(.goal, count: goals.count, isPro: pro.isPro) { isAdding = true } else { isPaywall = true }
            }
```

and add `.sheet(isPresented: $isPaywall) { PaywallView() }` after the existing `.sheet(isPresented: $isAdding)`.

`AccountsView`: same pattern with `ProLimits.canCreate(.account, count: visible.count, isPro: pro.isPro)` on the "New account" button (line 31) and the same `isPaywall` sheet.

- [ ] **Step 3: AI scan and voice in RootView**

In `RootView` add `@Environment(ProStore.self) private var pro` and `@State private var isPaywall = false`. Replace the two button actions:

```swift
                    Button { openAI { isScanning = true } } label: {
```
```swift
                    Button { openAI { isSpeaking = true } } label: {
```

and add inside `RootView`:

```swift
    private func openAI(_ open: () -> Void) {
        if ProLimits.canUseAI(usedThisMonth: AIUsage.count(), isPro: pro.isPro) { open() } else { isPaywall = true }
    }
```

Add `.sheet(isPresented: $isPaywall) { PaywallView() }` with the other sheets.

- [ ] **Step 4: Count a use only when something is saved**

`ReceiptScanView.save()` (line ~271): after `saved = true` add `AIUsage.record()`.

`VoiceCaptureView`: add `@State private var counted = false` and

```swift
    private func recordUsage() {
        guard !counted else { return }
        counted = true
        AIUsage.record()
    }
```

Call `recordUsage()` immediately before `dismiss()` in the auto-save at line ~242, in `save()` (line ~302) after a successful `DraftStore.save`, and in `saveOne` (line ~311) after a successful save. Change line ~179 to `onSaved: { recordUsage(); dismiss() }`. One capture session counts once however many drafts it saves.

- [ ] **Step 5: Run Build and Launch check**

Run: Build, then Launch check. Expected: `BUILD SUCCEEDED`, live PID.

- [ ] **Step 6: Manual check in the simulator**

Free user: create 5 subscriptions, the 6th "Add" opens the paywall; the existing 5 still edit and delete. Same for 2 goals, 1 account. Record 5 AI saves (in the simulator the Foundation Models draft path is unavailable; verify the counter instead by temporarily calling `AIUsage.record()` five times from a debug action, then remove it) and confirm the scan/mic buttons open the paywall on the sixth tap. State plainly in the report that the model-backed draft flow is device-only.

- [ ] **Step 7: Commit**

```bash
git add Moneva
git commit -m "Gate subscription, goal, account and AI creation behind Pro limits" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Lock Pro-only features

**Files:**
- Modify: `Moneva/Home/Views/HomeView.swift` (lines ~42, ~49, ~54-76)
- Modify: `Moneva/Transactions/Views/TransactionsView.swift` (assistant button that sets `assistantOpen`)
- Modify: `Moneva/Accounts/Views/AccountsView.swift` (Transfer button)
- Modify: `Moneva/Budget/Views/BudgetView.swift` (rollover toggle ~245, effect ~104)
- Modify: `Moneva/Settings/Views/SettingsView.swift` (import link ~41, Invite button ~58)
- Modify: `Moneva/Subscriptions/Views/SubscriptionEditorView.swift` (Type picker ~85)
- Modify: `Moneva/Categories/Views/CategoryPickerView.swift:130` (SubcategoryPicker), `Moneva/Categories/Views/CategoryEditorView.swift:116`

**Interfaces:**
- Consumes: `View.proGated()`, `ProStore.isPro`.
- Produces: no new API.

- [ ] **Step 1: Home**

In `HomeView.swift`: append `.proGated()` after `.id(scope)` on `DailyLimitCard`; change `HomeAskCard(scope: scope)` to `HomeAskCard(scope: scope).proGated()`; on the `HStack(alignment: .top, spacing: 12) { … }` that holds the forecast and Smart Insights links, add `.proGated()` after its existing `.buttonStyle(.plain)`. (One lock covers both previews; the cards stay visible as a dimmed teaser.)

- [ ] **Step 2: Assistant, transfers, import, invite**

Run `grep -n "assistantOpen = true" Moneva/Transactions/Views/TransactionsView.swift`; append `.proGated()` to the view (button/toolbar item label) that contains that assignment. In `AccountsView` append `.proGated()` to `Button("Transfer", …)`. In `SettingsView` append `.proGated()` to the `NavigationLink { StatementImportView() } label: {…}` and to `Button("Invite someone", …)`. Do **not** gate "Manage sharing", "Stop sharing" or accepting an invite: an invited partner joins free and a lapsed owner can still leave cleanly.

- [ ] **Step 3: Budget carry-over**

In `BudgetView` (both the main view ~line 13 and `BudgetEditor` ~line 235) add `@Environment(ProStore.self) private var pro`. Main view line ~104 becomes:

```swift
        let rollover = !(rolloverOn && pro.isPro) ? 0 : Budgeting.rolloverAmount(for: limit.category, transactions: transactions, budgets: budgets, monthStart: range.lowerBound, scope: scope, currency: currencyCode)
```

In `BudgetEditor` replace the Toggle with:

```swift
                    Toggle("Carry over unspent budget", isOn: pro.isPro ? rolloverOn : .constant(false))
                        .proGated()
```

The stored preference is untouched, so it resumes if the user upgrades.

- [ ] **Step 4: Recurring income and subcategories**

`SubscriptionEditorView`: add `@Environment(ProStore.self) private var pro` and `@State private var isPaywall = false`; on the `Picker("Type", selection: $kind) {…}` add

```swift
                    .onChange(of: kind) { _, newKind in
                        if newKind == .income && !pro.isPro { kind = .expense; isPaywall = true }
                    }
```

and a `.sheet(isPresented: $isPaywall) { PaywallView() }` on the form. Existing income subscriptions open with `kind == .income` and are not affected (the change handler only fires on a user change).

`SubcategoryPicker` (`CategoryPickerView.swift:130`): append `.proGated()` to the top-level view in its `body`. `CategoryEditorView.swift:116`: append `.proGated()` to `TextField("Add subcategory", …)`.

- [ ] **Step 5: Run Build and Launch check**

Run: Build, then Launch check. Expected: `BUILD SUCCEEDED`, live PID.

- [ ] **Step 6: Manual check**

As Free: each locked item is dimmed with a lock and opens the paywall on tap; rollover shows off. Buy Pro in the StoreKit scheme: locks vanish immediately and rollover returns to the stored value. Existing income subscription still opens and saves as Free.

- [ ] **Step 7: Commit**

```bash
git add Moneva
git commit -m "Lock Pro-only features behind the paywall" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: AdMob banner, consent and RootView placement

**Files:**
- Create: `Config/Ads-Info.plist` (outside the synchronized `Moneva/` group so it is not bundled twice)
- Create: `Moneva/Pro/Core/AdsConsent.swift`
- Create: `Moneva/Pro/Views/AdBanner.swift`
- Modify: `Moneva.xcodeproj` (SPM package, `INFOPLIST_FILE`), `Moneva/App/RootView.swift`, `Moneva/App/MonevaApp.swift`

**Interfaces:**
- Consumes: `ProLimits.showsBanner(tab:isPro:)`, `AppTab`, `ProStore.isPro`.
- Produces: `AdsConsent` (`@MainActor @Observable`, `canRequestAds: Bool`, `start() async`); `AdBanner` view.

- [ ] **Step 1: Add the SDK and confirm its API**

Xcode ▸ File ▸ Add Package Dependencies… ▸ `https://github.com/googleads/swift-package-manager-google-mobile-ads` ▸ latest stable release ▸ add `GoogleMobileAds` to target `Moneva` (UMP comes with it as `UserMessagingPlatform`). Before writing Steps 3–4, check the installed version's current symbol names with Context7 / Google's iOS docs (this plan assumes v11+ naming without the `GAD` prefix: `MobileAds.shared.start()`, `BannerView`, `Request`, `Extras`, `currentOrientationAnchoredAdaptiveBanner(width:)`, `ConsentInformation.shared`, `ConsentForm.loadAndPresentIfRequired(from:)`); adjust names to what the installed version exposes and keep the behavior identical.

- [ ] **Step 2: Info.plist keys (test IDs)**

Create `Config/Ads-Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>GADApplicationIdentifier</key>
    <string>ca-app-pub-3940256099942544~1458002511</string>
    <key>AdBannerUnitID</key>
    <string>ca-app-pub-3940256099942544/2435281174</string>
    <key>SKAdNetworkItems</key>
    <array>
        <dict>
            <key>SKAdNetworkIdentifier</key>
            <string>cstr6suwn9.skadnetwork</string>
        </dict>
    </array>
</dict>
</plist>
```

These are Google's published sample app/banner IDs. In the target's Build Settings set `INFOPLIST_FILE = Config/Ads-Info.plist` (it merges with `GENERATE_INFOPLIST_FILE = YES`). Add the full SKAdNetwork identifier list from Google's current "Update your Info.plist" page to the array. **Owner action before App Store release:** replace both IDs with the real AdMob app ID and banner unit ID.

- [ ] **Step 3: Consent**

Create `Moneva/Pro/Core/AdsConsent.swift`:

```swift
import GoogleMobileAds
import UserMessagingPlatform
import UIKit
import Observation

/// UMP consent (only shows a form in EEA/UK), then starts the SDK. Ads load only
/// after `canRequestAds`. No ATT: requests are non-personalized.
@MainActor @Observable
final class AdsConsent {
    private(set) var canRequestAds = false
    @ObservationIgnored private var started = false

    func start() async {
        guard !started else { return }
        started = true
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
            if let root = Self.rootViewController {
                try await ConsentForm.loadAndPresentIfRequired(from: root)
            }
        } catch {
            // Consent could not be resolved: fall through; canRequestAds stays false unless a prior answer exists.
        }
        guard ConsentInformation.shared.canRequestAds else { return }
        MobileAds.shared.start()
        canRequestAds = true
    }

    static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
    }
}
```

- [ ] **Step 4: AdBanner**

Create `Moneva/Pro/Views/AdBanner.swift`:

```swift
import SwiftUI
import GoogleMobileAds

/// Anchored adaptive banner. Takes only a width: no app data ever reaches the SDK.
/// Collapses to zero height until an ad arrives and again if loading fails.
struct AdBanner: View {
    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(height: height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay {
                if width > 0 { BannerRepresentable(width: width, height: $height) }
            }
            .accessibilityLabel("Advertisement")
    }
}

private struct BannerRepresentable: UIViewRepresentable {
    let width: CGFloat
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: width))
        banner.adUnitID = Bundle.main.object(forInfoDictionaryKey: "AdBannerUnitID") as? String
        banner.rootViewController = AdsConsent.rootViewController
        banner.delegate = context.coordinator
        let request = Request()
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]   // non-personalized, no ATT
        request.register(extras)
        banner.load(request)
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {}

    final class Coordinator: NSObject, BannerViewDelegate {
        @Binding var height: CGFloat
        init(height: Binding<CGFloat>) { _height = height }

        func bannerViewDidReceiveAd(_ bannerView: BannerView) { height = bannerView.adSize.size.height }
        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) { height = 0 }
    }
}
```

- [ ] **Step 5: Place it in RootView**

In `RootView`: add `@Environment(ProStore.self) private var pro`, `@State private var ads = AdsConsent()`, `@State private var tab: AppTab = .home`. Tag the tabs and bind selection:

```swift
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) { NavigationStack { HomeView() } }
            Tab("Transactions", systemImage: "list.bullet", value: AppTab.transactions) { TransactionsView() }
            Tab("Budget", systemImage: "chart.pie", value: AppTab.budget) { BudgetView() }
            Tab("Goals", systemImage: "flag", value: AppTab.goals) { GoalsView() }
            Tab("Subs", systemImage: "arrow.triangle.2.circlepath", value: AppTab.subs) { SubscriptionsView() }
        }
        .tint(Palette.accent)
        .overlay(alignment: .bottomTrailing) { /* existing FAB stack, unchanged */ }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if ads.canRequestAds && ProLimits.showsBanner(tab: tab, isPro: pro.isPro) { AdBanner() }
        }
        .task { await ads.start() }
```

Keep the existing `.sheet`s and `.preferredColorScheme` after these.

- [ ] **Step 6: Run Build and Launch check**

Run: Build, then Launch check. Expected: `BUILD SUCCEEDED`, live PID, no new `.ips`.

- [ ] **Step 7: Manual simulator check**

Free: a Google test banner appears under the tab bar on Home and Transactions only, not on Budget/Goals/Subs, not in any sheet. Check the FAB is not covered. **If the FAB is covered**, apply the spec fallback: move the inset into `HomeView` and `TransactionsView` and raise the FAB `.padding(.bottom, 96)` by the banner height. Turn off networking: banner collapses, no gap. Buy Pro: banner disappears at once. Real AdMob fill is device-only; say so.

- [ ] **Step 8: Commit**

```bash
git add Config Moneva Moneva.xcodeproj
git commit -m "Show a non-personalized AdMob banner to free users" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Rules, docs and release checklist

**Files:**
- Modify: `CLAUDE.md`, `AGENTS.md`
- Modify: `docs/AI_FEATURES.md` only if it mentions "no network"

**Interfaces:** none.

- [ ] **Step 1: Relax the local-only rule (owner approved)**

Run `grep -n -i "no backend\|local-only\|remote AI\|analytics\|upload" CLAUDE.md AGENTS.md`. In each hit that states the blanket rule (CLAUDE.md "Working rules", the opening "What this is" paragraph, and AGENTS.md's equivalent), replace the "no backend / no remote" wording with:

> Network code is allowed only for two things: the AdMob banner (non-personalized, no ATT) and StoreKit purchases. Do not add a backend or remote AI, and never send financial data, receipt images, voice transcripts or OCR text to any SDK. `AdBanner` must keep taking no app data.

Also add one line to CLAUDE.md under "Working rules": "Free-tier limits and Pro gates live in `ProLimits`/`AIUsage` (`Moneva/Pro/Core`); add an assert to `proSelfCheck()` for any new limit." Keep CLAUDE.md and AGENTS.md consistent.

- [ ] **Step 2: Commit the rule change on its own**

```bash
git add CLAUDE.md AGENTS.md
git commit -m "Allow AdMob and StoreKit network use in project rules" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Owner release checklist (report, do not do)**

List to the owner, unchecked: (1) create the three IAP products in App Store Connect with the exact IDs and a subscription group; (2) replace the test AdMob app ID and banner unit ID in `Config/Ads-Info.plist`; (3) paste the real privacy-policy URL into `PaywallLinks.privacy`; (4) update App Store privacy labels from Google's official "SDK data disclosure" list for the Mobile Ads SDK and UMP; (5) test on a physical device: real banner fill, EEA consent form (set a debug geography), Foundation Models flows behind the AI limit; (6) translate the new strings (ru/az) in `Localizable.xcstrings`.

---

## Self-review notes

- **Spec coverage:** Free/Pro split → Tasks 3–4; `ProLimits`/`AIUsage`/`ProStore`/`AdBanner`/`PaywallView` → Tasks 1, 2, 5; banner placement + fallback → Task 5; consent/privacy → Tasks 5–6; rules change → Task 6; tests → Task 1/2 asserts + manual StoreKit/simulator checks.
- **Deliberate deviations from the spec (flag to owner):** (a) no `ProFeature` enum or its assert: `.proGated()` just checks `isPro`, so the assert would test `x == x`; (b) Family: only *inviting* is locked; Pro expiry does **not** stop an existing share's sync (enforcing that needs sync-engine changes and an early `isPro`; cached `isPro` makes it possible later); (c) rollover is switched off for Free users in the calculation too, so existing users lose carry-over until they upgrade; (d) detected subscriptions and AI subscription drafts count against the subscription limit.
- **Type consistency:** `ProLimits.Limited`, `canCreate`, `canUseAI`, `showsBanner`, `AppTab`, `AIUsage.count/record`, `ProStore.unlocks/isPro/products/purchase/restore`, `PaywallView`, `proGated()` are defined in Tasks 1–2 and used unchanged afterwards.
