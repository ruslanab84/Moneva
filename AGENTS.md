# Repository Guidelines

## Project Structure & Module Organization

`Moneva/` contains the SwiftUI application. Views use feature-oriented names such as `SubscriptionsView.swift`; shared UI and design tokens live in `Components.swift` and `Theme.swift`. SwiftData models are in `Models.swift`, while deterministic business rules belong in files such as `Budgeting.swift`, `Subscriptions.swift`, and `Categories.swift`. On-device AI and OCR flows live in `VoiceDraft.swift`, `SubscriptionInsight.swift`, `ReceiptDraft.swift`, and `ReceiptScan.swift`. Assets are under `Moneva/Assets.xcassets`. Design sources are in `design/`, and supporting product notes are in `docs/`.

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

Moneva is local-only: do not add backend storage or upload receipt, voice, or financial data. Preserve the personal/shared scope boundary and keep currencies separate in calculations.
