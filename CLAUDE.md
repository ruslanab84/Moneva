# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Moneva: SwiftUI + SwiftData personal/shared expense tracker for iOS. No backend — everything is local SwiftData, plus on-device Apple Intelligence (Foundation Models) for turning voice/receipt text into transaction drafts. Design source lives in `design/*.dc.html` (Claude Design canvas artboards + `design/Foundations.dc.html` for tokens) — `Theme.swift` mirrors those tokens.

## Build / run / test

Single target `Moneva`, no test target yet — correctness is enforced by an assert-based self-check (`monevaSelfCheck()` in [Budgeting.swift](Moneva/Budgeting.swift), run automatically in `#if DEBUG` from [MonevaApp.swift](Moneva/MonevaApp.swift) on every debug launch).

```bash
xcodebuild -project Moneva.xcodeproj -scheme Moneva -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

To actually verify a change, build for a concrete simulator, launch the `.app`, and tap through the changed flow — a compile-only build misses runtime issues like SwiftData migration crashes or a broken Cancel/redraw.

Environment: Xcode 26.6, iOS deployment target 26.5, Swift 5.0.

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

Drafts from either source land in the same confirm-before-save UI; nothing from a model reaches the store un-reviewed.

## Data model ([Models.swift](Moneva/Models.swift))

SwiftData `@Model` classes: `Transaction`, `SpendingCategory`, `Budget`/`BudgetLimit`, `Goal`, `Subscription`/`SubscriptionPayment`.

- **Scope** (`personal`/`shared`) cuts across almost every model — it's a from-scratch partition, not a filter of convenience. Budgeting, category visibility, and totals all key off it.
- **Money**: amounts are `Decimal`, never `Double`, until they cross into the Foundation Models boundary (which only speaks `Double`) — `DraftResolver.amount` is the one place that round-trips through a string to avoid float noise, at receipt precision (2 decimal places).
- Every transaction/subscription keeps its own `currency` code even though the app displays one active currency (`Money.code` in [Theme.swift](Moneva/Theme.swift)) — changing the display currency never rewrites history.
- Schema evolution landmine: `SpendingCategory.scope` is stored as `scopeRaw: String?` (optional), not a non-optional enum column. SwiftData can't backfill a new enum column for rows written before it existed, and reading a genuinely-empty enum column force-casts and crashes. Any new enum-backed column on an existing `@Model` needs the same optional-raw-string-plus-computed-property treatment, or a real migration plan.

## Business logic lives in enums, not views

[Budgeting.swift](Moneva/Budgeting.swift), [Subscriptions.swift](Moneva/Subscriptions.swift), and category rules (`CategoryLibrary`) are plain enums of pure static functions over the model types — no `@Model` logic, no view-embedded math. `SubscriptionEngine` (also in Subscriptions.swift) is the one `@MainActor` piece that actually touches `ModelContext`, driven by `Subscriptions`' pure date/period math:

- A subscription's billing day is an **anchor**, not a stride — `Subscriptions.nextDate` clamps to the target month's length (31st → Feb 28th) but keeps the anchor for later months (March still lands on the 31st).
- `SubscriptionEngine.catchUp` runs on launch and reconciles missed months via `duePeriods`, deduped against `SubscriptionPayment.billingPeriod` so a launch after weeks away can't double-charge. `paymentMode: .ask` never writes on its own — it queues a `Pending` the UI must `confirm`/`skip`.

When extending money/date logic, add it to these enums and extend `monevaSelfCheck()` in the same PR — that assert block is the only regression net.

## UI structure

[RootView.swift](Moneva/RootView.swift) is a `TabView` (Home/Transactions/Budget/Goals/Subs) with a floating action stack (scan receipt / voice / add) presented as sheets. Views read `@Query`/`@Environment(\.modelContext)` directly (no view-model layer) and delegate all computation to the enums above. Shared visual primitives (`Palette`, `monevaCard`, `ProgressBar`, `Eyebrow`, currency formatting) live in [Theme.swift](Moneva/Theme.swift); design tokens there are hand-mirrored from `design/Foundations.dc.html`, so a design-token change needs updating both.
