# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Moneva: SwiftUI + SwiftData personal/shared expense tracker for iOS. No backend — everything is local SwiftData, plus on-device Apple Intelligence (Foundation Models) for turning voice/receipt text into transaction drafts. Design source lives in `design/*.dc.html` (Claude Design canvas artboards + `design/Foundations.dc.html` for tokens) — `Theme.swift` mirrors those tokens.

## Build / run / test

Single target `Moneva`, no test target yet — correctness is enforced by an assert-based self-check (`monevaSelfCheck()` in [Budgeting.swift](Moneva/Budgeting.swift), run automatically in `#if DEBUG` from [MonevaApp.swift](Moneva/MonevaApp.swift) on every debug launch). It fans out into `smartInsightsSelfCheck()`, `aiFeaturesSelfCheck()` ([AIFeaturesSelfCheck.swift](Moneva/AIFeaturesSelfCheck.swift), which in turn calls `financialToolsSelfCheck()` in [FinancialToolsSelfCheck.swift](Moneva/FinancialToolsSelfCheck.swift)), `merchantEmbeddingSelfCheck()`, `categoryClassifierSelfCheck()` and `familySyncSelfCheck()` — that's the whole regression net, so any change to money/date/AI logic needs a new assert in the matching file, not a new test target.

```bash
xcodebuild -project Moneva.xcodeproj -scheme Moneva -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

To actually verify a change, build for a concrete simulator, launch the `.app`, and tap through the changed flow — a compile-only build misses runtime issues like SwiftData migration crashes or a broken Cancel/redraw.

Set `MONEVA_TOOL_MODEL_CHECK=1` in the Xcode scheme's Run environment (Apple Intelligence-capable device/sim only) to additionally run real `LanguageModelSession` evaluation of the financial tools against synthetic data — off by default since it needs a live model.

Environment: Xcode 26.6, iOS deployment target 26.5, Swift 5.0.

Foundation Models does not run in the simulator, so the build + DEBUG launch only proves the self-check asserts pass (live process, no new `Moneva-*.ips` in `~/Library/Logs/DiagnosticReports`); model routing/phrasing (Ask, Search, Explain, drafting) must be retested on a physical Apple Intelligence device.

Commits: short imperative style, e.g. `Give subscriptions an optional end date` — not Conventional Commits.

## Working rules

- Keep changes narrow and preserve unrelated worktree edits. Read the affected call flow and reuse the existing components or rule enums before adding code.
- This is a local-only app: do not add a backend, remote AI, analytics, or upload financial data, receipt images, voice transcripts, or OCR text.
- Preserve the `personal`/`shared` and income/expense partitions in every query, calculation, picker, and saved record. Keep currencies separate; do not convert or relabel historical amounts.
- Use `Decimal` for money and `Calendar` for date arithmetic. Put reusable money, date, and category logic in the existing pure enums, not SwiftUI view bodies.
- Treat SwiftData schema edits as migration work. New properties on existing models need a compatible default/optional storage strategy and verification against an existing store.
- For changes to money, dates, persistence, or AI resolvers, add the smallest regression to `monevaSelfCheck()` or `aiFeaturesSelfCheck()` and launch a DEBUG build. For UI or migration changes, also exercise the changed flow in the simulator.

## Core architecture: model drafts, Swift decides

The one pattern that spans the AI-touching files (voice capture, receipt OCR, subscription detection): an on-device model is only ever allowed to produce a narrow `@Generable` struct; it never writes to SwiftData and never does money/date arithmetic. Everything the model can get wrong is clamped in one pure resolver layer, not scattered across callers.

- [VoiceDraft.swift](Moneva/VoiceDraft.swift) — `DraftedTransaction` (`@Generable`) is what `LanguageModelSession` fills in from spoken text or OCR'd receipt text. `DraftResolver` turns that into a `TransactionDraft` (real `Decimal`, `Date`, `SpendingCategory`), rounding/clamping/matching everything itself. `TransactionDrafter` wraps one session, streams partial results (`PartiallyGenerated`) so the UI fills in field by field, and gates on `SystemLanguageModel.default.availability`.
- Trust boundary: app-owned data (category names, business rules) goes in the session's `instructions`; untrusted free text (transcript, OCR text) goes in the `prompt`.
- The model is never asked to compute a calendar date — it emits `daysAgo: Int` and `DraftResolver.date` resolves it with `Calendar`.
- [ReceiptScan.swift](Moneva/ReceiptScan.swift) — `DocumentScanner` wraps `VNDocumentCameraViewController`; `ReceiptText.read` does on-device Vision OCR, then reconstructs rows by vertical overlap and reads each row left-to-right. Its conservative rightmost-price heuristic is deliberately marked `ponytail:` with its upgrade boundary.
- [SpeechCapture.swift](Moneva/SpeechCapture.swift) — on-device transcription feeding the same `TransactionDrafter` in `.spoken` mode.
- [StatementImport.swift](Moneva/StatementImport.swift) — the third draft source, and the one with no model in it: pure CSV/bank-statement parsing (encoding sniffing, delimiter detection from the header line, RFC 4180 quoting) that emits ordinary `TransactionDraft`s, so every downstream guard (`Money.valid`, `CategoryLibrary.isSelectable`, `DraftStore.save`) applies unchanged.

Drafts from all three sources land in the same confirm-before-save UI; nothing from a model reaches the store un-reviewed.

## Financial tool-calling layer (Ask/Search/Explain)

A second, distinct AI pattern for read-only questions: `Question → typed Foundation Models tool selection → LanguageModelSession with selected tools → typed Tool → FinancialToolService.Request → validated domain calculation over local SwiftData → FinancialToolResult JSON → model explanation`. Defined in [AskTools.swift](Moneva/AskTools.swift) (ten registered tools, e.g. `GetTransactionsTool`, `GetBudgetTool`, `ComparePeriodsTool`) and [SpendingSearch.swift](Moneva/SpendingSearch.swift) (`DraftedSearch` → `SpendingFilter`). Full contract, JSON schema, and the authorization boundary (no login/tenant — isolation is local-store scope+currency, not authenticated multi-tenancy) are in [docs/AI_TOOL_LAYER.md](docs/AI_TOOL_LAYER.md).

- The model never sees `ModelContext`, raw records, or SQL — only bounded argument strings in, bounded `FinancialToolResult` JSON out. `FinancialToolService` fixes `Scope`/currency from the UI; model arguments cannot override them.
- All three entry points (Ask, Search, Explain in [SpendingAssistantView.swift](Moneva/SpendingAssistantView.swift), plus subscription Q&A in [SubscriptionInsight.swift](Moneva/SubscriptionInsight.swift), plus [SmartInsights.swift](Moneva/SmartInsights.swift)) must build their `LanguageModelSession` with the same category/date grounding via `OnDeviceAI.context(categories:)` — a session missing that context makes the model misfile category names into free-text filters instead of matching real categories, silently undercounting totals. If you add a new tool-calling entry point, copy an existing session-construction site rather than building context from scratch.
- Comparison differences (`comparePeriods`) are computed by Swift and the explanation preserves the signed value verbatim — live testing found the model could restate a correct value incorrectly, so numeric claims never round-trip through model prose unchecked.

## Smart Insights

[SmartInsights.swift](Moneva/SmartInsights.swift) computes spending-trend/spike/budget-projection signals with pure `Decimal` statistics off the main actor; Foundation Models is only allowed to pick which of two app-authored explanation strings to show (a constrained choice index), never to write numbers. See [docs/smart-insights/README.md](docs/smart-insights/README.md) for the exact thresholds.

## Accounts and transfers

[Accounts.swift](Moneva/Accounts.swift) (pure helpers) + [AccountsView.swift](Moneva/AccountsView.swift). `Account` is deliberately **not** a partition the way `Scope` is — totals, charts, budgets, forecasts and the AI tools are never filtered by account, and an assert in `monevaSelfCheck()` guards that. Accounts also sit outside scope: one list serves both personal and shared.

- Balance = `openingBalance` + same-currency transactions + same-currency transfers. Nothing is converted; a transaction in another currency simply does not count toward that account's balance.
- A cross-account move is its own `Transfer` `@Model`, never two `Transaction`s — that's why no existing total needed new exclusion logic. `Accounts.canTransfer` requires two distinct live accounts with matching currency.
- `Transaction.account` and `Subscription.account` are optional relationships (additive column, lightweight migration). A recurring charge lands in the subscription's account only when the currency matches, otherwise it is recorded with no account. Archived accounts leave the pickers but keep receiving charges from subscriptions already pointing at them.
- A SwiftUI `Picker` over `Account?` needs `.tag(Account?.some($0))`.

## Family sharing (CloudKit)

[FamilySync.swift](Moneva/FamilySync.swift) syncs `Transaction` records via `CKSyncEngine`, with `AppDelegate.swift` handling share acceptance and [CloudSharingSheet.swift](Moneva/CloudSharingSheet.swift) wrapping `UICloudSharingController` for invites. This is layered on top of, not a replacement for, local SwiftData — `Scope: .shared` remains a local partition, not proof of an accepted share. Treat any CloudKit-touching change as sync-conflict-sensitive: `FamilySyncEngine.catchUp()` runs at launch and is covered by `familySyncSelfCheck()`.

## Merchant/category classification

[MerchantSeeds.swift](Moneva/MerchantSeeds.swift) loads a bundled 241-entry merchant dataset ([Resources/merchant-seeds.json](Moneva/Resources)); [MerchantEmbedding.swift](Moneva/MerchantEmbedding.swift) and [CategoryClassifier.swift](Moneva/CategoryClassifier.swift) match free-text merchant names to the user's *live, editable* category list, not the seed data's own categories. `MerchantSeeds.resolved(strict:)` defaults `strict: true` (traps on an unresolvable seed) for the self-check fixture, but the live classifier call site must pass `strict: false` — a user can delete/rename categories the seed data references, and that must degrade to skipping the seed, not crashing mid-draft.

## Localization

User-facing strings live in [Resources/Localizable.xcstrings](Moneva/Resources/Localizable.xcstrings); shared components take `LocalizedStringKey`/`Text`, not raw `String`. Known English-only gaps: dynamic report sentence glue in AskTools/SpendingSearch and `Transaction.source.rawValue` labels. Other docs: [docs/AI_FEATURES.md](docs/AI_FEATURES.md), [docs/RECEIPT_WORKFLOW.md](docs/RECEIPT_WORKFLOW.md).

## Data model ([Models.swift](Moneva/Models.swift))

SwiftData `@Model` classes: `Transaction`, `SpendingCategory`, `Budget`/`BudgetLimit`, `Goal`, `Subscription`/`SubscriptionPayment`.

- **Scope** (`personal`/`shared`) cuts across almost every model — it's a from-scratch partition, not a filter of convenience. Budgeting, category visibility, and totals all key off it.
- **Money**: amounts are `Decimal`, never `Double`, until they cross into the Foundation Models boundary (which only speaks `Double`) — `DraftResolver.amount` is the one place that round-trips through a string to avoid float noise, at receipt precision (2 decimal places).
- Every transaction/subscription keeps its own `currency` code even though the app displays one active currency (`Money.code` in [Theme.swift](Moneva/Theme.swift)) — changing the display currency never rewrites history.
- Schema evolution landmine: `SpendingCategory.scope` is stored as `scopeRaw: String?` (optional), not a non-optional enum column. SwiftData can't backfill a new enum column for rows written before it existed, and reading a genuinely-empty enum column force-casts and crashes. Any new enum-backed column on an existing `@Model` needs the same optional-raw-string-plus-computed-property treatment, or a real migration plan.

## Business logic lives in enums, not views

[Budgeting.swift](Moneva/Budgeting.swift), [Subscriptions.swift](Moneva/Subscriptions.swift), [Accounts.swift](Moneva/Accounts.swift), and category rules (`CategoryLibrary`) are plain enums of pure static functions over the model types — no `@Model` logic, no view-embedded math. `SubscriptionEngine` (also in Subscriptions.swift) is the one `@MainActor` piece that actually touches `ModelContext`, driven by `Subscriptions`' pure date/period math:

- A subscription's billing day is an **anchor**, not a stride — `Subscriptions.nextDate` clamps to the target month's length (31st → Feb 28th) but keeps the anchor for later months (March still lands on the 31st).
- `SubscriptionEngine.catchUp` runs on launch and reconciles missed months via `duePeriods`, deduped against `SubscriptionPayment.billingPeriod` so a launch after weeks away can't double-charge. `paymentMode: .ask` never writes on its own — it queues a `Pending` the UI must `confirm`/`skip`.

When extending money/date logic, add it to these enums and extend `monevaSelfCheck()` in the same PR — that assert block is the only regression net.

## UI structure

[RootView.swift](Moneva/RootView.swift) is a `TabView` (Home/Transactions/Budget/Goals/Subs) with a floating action stack (scan receipt / voice / add) presented as sheets. Views read `@Query`/`@Environment(\.modelContext)` directly (no view-model layer) and delegate all computation to the enums above. Shared visual primitives (`Palette`, `monevaCard`, `ProgressBar`, `Eyebrow`, currency formatting) live in [Theme.swift](Moneva/Theme.swift); design tokens there are hand-mirrored from `design/Foundations.dc.html`, so a design-token change needs updating both.

Local payment reminders live in [Reminders.swift](Moneva/Reminders.swift): notification permission is only requested when a user actually switches a reminder on, and `Reminders.reschedule` replaces the subscription's pending notifications after every create/edit/pause/resume.

[AGENTS.md](AGENTS.md) covers the same ground in a shorter, style-guide form (indentation, naming, PR expectations); this file is the fuller architecture doc. Keep the two consistent when a rule changes.
