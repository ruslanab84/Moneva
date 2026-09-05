# Moneva on-device AI

The entry points are the floating Text & Voice and Receipt buttons, Subscriptions → Add from text or voice, and Transactions → Search & explain spending. All AI writes go through an editable review. Manual entry and manual search/report controls work without the model.

- Text and voice produce a batch of individually editable drafts. Unknown amounts, currency and dates request correction. Exact decimal strings cross the model boundary; invalid numbers or precision cannot save. Source-grounded merchant names and notes prevent invented merchant labels from becoming permanent rules.
- Category pickers include creation and show similar existing names. Only supported icons are accepted. Saving a transaction with the explicit “Remember this merchant’s category” switch creates/replaces a rule for that merchant in that scope.
- Receipt OCR uses Vision, camera capture uses VisionKit, and import uses PhotosPicker. Review shows the image and editable line items, quantities, unit prices, tax and discount lines. Informational adjustments already included in item amounts are excluded from calculations. A split must reconcile exactly. Group allocations belong to one transaction; budgets and category-filtered search use allocation amounts. Optional images and reviewed item details remain local. Possible duplicates compare date, currency, total and merchant (including missing merchants).
- Monthly subscription drafts keep their own currency and require review. Saving schedule edits changes future payments only. Pausing and resuming do not backfill paused months. The stored billing-day anchor survives short months; processed billing periods and draft IDs prevent repeat writes. Detection conservatively proposes equal amounts in consecutive months, then lets the model select likely services; it never invents candidate prices.
- Natural-language search resolves into an allowlisted Swift filter, with explicit dates, merchant, category, amount bounds, currency, transaction kind and the caller's scope. The model cannot broaden the selected partition or run database queries. Category-filtered totals use the matching allocation; expense and income totals remain separate by currency.
- Explanations select IDs from application-calculated facts. The UI displays the exact facts with source records instead of model-written numerical claims. Current-month comparisons explicitly disclose incomplete periods and unknown coverage. Recurring costs do not imply service usage.

Persistence remains local SwiftData. “Shared” is the existing local partition, not an implemented account, membership or sync system. No external AI provider or remote sync was added. New stored properties use optional columns/defaults; new allocation/rule models are included in the container. Legacy budgets had no currency metadata: the existing selected currency is captured once during upgrade, because the original currency cannot be recovered from those records.

## Validation

Build:

```sh
xcodebuild -project Moneva.xcodeproj -scheme Moneva -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

Debug launch runs the existing `monevaSelfCheck()` and `aiFeaturesSelfCheck()` in an in-memory store. Checks cover atomic rejection of incomplete batches, retries, merchant rule scope, exact currency amounts, included/exclusive tax, discounts, receipt reconciliation, allocations, category totals, duplicate warnings, search scope/date validation, recurring payment deduplication, future-only edits, pause/resume dates and historical transaction retention after deleting a schedule.

Simulator validation includes launching over an existing store, category-picker navigation, manual fallbacks, and the three-expense text example. Physical-device acceptance still needs microphone/audio lifecycle, camera/OCR with real receipts, Foundation Models in supported languages, and Dynamic Type/VoiceOver at accessibility sizes. Model generation is probabilistic; review is mandatory even when every field looks complete. No processing error saves partial drafts.

API references: [Foundation Models structured output](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation), [language availability](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models).
