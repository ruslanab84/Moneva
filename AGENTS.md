# Repository Guidelines

## Project Structure & Module Organization

`Moneva/` contains the SwiftUI application, grouped by feature: `Home/`, `Transactions/`, `Budget/`, `Subscriptions/`, `Accounts/`, `Goals/`, `Settings/`, `Categories/`, each with `Views/` and (where there is separable logic) `Core/` holding deterministic business rules (e.g. `Budget/Core/Budgeting.swift`, `Subscriptions/Core/Subscriptions.swift`, `Categories/Core/Categories.swift`). `AI/` holds on-device AI and OCR flows (`Core/VoiceDraft.swift`, `Core/AskTools.swift`, `Core/ReceiptDraft.swift`, `Core/ReceiptScan.swift`), their views, and the AI self-checks; `Sync/` holds CloudKit family sharing; `Shared/` holds `Models.swift`, `Theme.swift`, `Components.swift` and `SeedData.swift`; `App/` holds the app entry point and `RootView`. Views use feature-oriented names such as `SubscriptionsView.swift`. Assets are under `Moneva/Assets.xcassets`. Design sources are in `design/`, and supporting product notes are in `docs/`.

## Build, Test, and Development Commands

Open `Moneva.xcodeproj` in Xcode 26.6 or build from the repository root:

```bash
xcodebuild -project Moneva.xcodeproj -scheme Moneva \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build
```

For runtime verification, target a concrete iOS 26.5 simulator, install the built app, and exercise the changed flow. A DEBUG launch automatically runs `monevaSelfCheck()` from `Budgeting.swift`, including `aiFeaturesSelfCheck()`. There is currently no XCTest target.

## Coding Style & Naming Conventions

Use four-space indentation and standard Swift naming: `UpperCamelCase` for types and `lowerCamelCase` for properties and functions. Keep SwiftUI views small and compose existing components before adding new ones. Put reusable calculations in the existing rule enums rather than view bodies. Use `Decimal` for money and `Calendar` for date arithmetic. Foundation Models may extract guided `@Generable` data, but Swift must validate it and perform calculations. Keep untrusted user text in prompts, not model instructions.

## Testing Guidelines

Extend the existing assert-based self-check for changes to money, dates, persistence, or AI resolvers. Add the smallest regression that fails for the original bug. A successful compile is insufficient for SwiftData migrations or UI behavior; launch the DEBUG app and verify the affected screen.

## Commit & Pull Request Guidelines

Follow the existing imperative commit style, for example `Give subscriptions an optional end date`. Keep commits narrowly scoped. Pull requests should describe the user-visible change, list validation performed, and include screenshots for visual changes. Call out SwiftData schema changes and any device-only Foundation Models limitations.

## Security & Configuration

Moneva is local-only: do not add backend storage or upload receipt, voice, or financial data. Network code is allowed only for the AdMob banner and StoreKit; neither may receive app data. Preserve the personal/shared scope boundary and keep currencies separate in calculations.
