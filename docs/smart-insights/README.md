# Smart Insights

The Home screen snapshots expense values into immutable, Sendable input. The pure statistical engine runs in a utility-priority detached task. It returns up to three signals; SwiftUI immediately displays deterministic titles and explanations. Foundation Models then selects a faithful explanation variant for each signal, serially, with a fresh session per signal. No model runs for an empty signal list.

## Rules

| Signal | Rule |
| --- | --- |
| Spending increase/decrease | At least 10% away from the average of matching elapsed-day periods in the previous three months. |
| Unusual spike | At least 50% above that average and more than two population standard deviations above it. Zero-variance baselines still require the 50% increase. |
| Budget projection | Completed-day spending pace projects more than 110% of the category's monthly limit. |
| Budget exceeded | Recorded spending through yesterday already exceeds the category limit. |

Trends and projections require seven completed days. Historical trends require at least three recorded entries in each of the three baseline periods, plus three current entries (or zero current spending). Projections require three current entries; actual overruns do not. Short historical months are normalized by their available day count. Today's incomplete day and future-dated entries are excluded. A sparse ledger produces no trend claim, not a fabricated baseline.

Money sums, averages, variance, and projections use Decimal. Only the final rounded percentage display crosses to Double. The snapshot filters expense/income, personal/shared scope, and the active currency, and preserves category allocations. Category IDs, rather than names, define groups. Category budget warnings take priority over category trends; results are ordered by severity, then stable category identity.

## Model boundary and fallback

The model receives only a detected signal and two app-authored explanations, never raw transactions, merchants, notes, or receipts. Structured generation returns a constrained choice index. Swift validates that index and uses the default explanation if it is invalid. This deliberately limits AI to wording selection: arbitrary generated prose cannot add unsupported numbers, causes, advice, or facts. Unavailable models, unsupported English, refusals, and generation errors retain deterministic copy.

No database schema or global provider changed. All state is local to the insight view. Ledger changes restart the task; cancellation checks prevent stale AI results from appearing. A one-minute timeline catches day boundaries and newly eligible future entries while Home is visible. SwiftData snapshotting stays on the main actor; statistical processing runs off it. The snapshot still traverses the Home screen's existing fetch-all query, so extremely large ledgers would benefit from a date-bounded query.

## Files

- `Moneva/Home/Core/SmartInsights.swift`: snapshot, threshold constants, engine, Foundation Models adapter, and DEBUG regression checks.
- `Moneva/Home/Views/SmartInsightsView.swift`: themed card, task lifecycle, no-signal state, and narrow/light and accessibility/dark Xcode previews.
- `Moneva/Home/Views/HomeView.swift`: placement between the budget summary and today's transactions.
- `Moneva/Budget/Core/Budgeting.swift`: registers the new check in the existing DEBUG self-check suite.

## Verification

Debug Simulator build succeeded. The iOS 26.5 app logged `Smart Insights self-check passed` and `Moneva AI feature self-checks passed`. Assertions cover +34% restaurant spending, a 12% decrease, unchanged spending, a category spike, projected and actual budget overruns, sparse/early history, future and invalid values, invalid model selections, split allocations, income exclusion, and scope/currency isolation.

Simulator screenshots show the actual Home layout. Populated screenshots use the +34% fixture input in a temporary preview build; the committed Home integration uses real ledger input, and fixture transactions were never saved. Xcode previews additionally cover 320-point width and accessibility Dynamic Type. Physical-device Foundation Models generation remains unverified; simulator validation establishes fallback rendering and deterministic output validation, not live model quality.

Visual checks: iPhone 17 Pro (402 points) in light and dark mode, compact iPhone SE layout (375 points), and accessibility-medium text. The existing Home floating action stack overlaps scroll content on compact/large-text layouts; scrolling moves the insight clear of it. The compact screenshot is captured after that scroll. No global navigation/control layout was changed.

- [Light fixture](home-signal-light.png)
- [Dark fixture](home-signal-dark.png)
- [Compact fixture after scrolling](home-signal-compact.png)
- [Enlarged text](home-accessibility.png)
- [No-signal light](home-empty-light.png)
- [No-signal dark](home-empty-dark.png)
