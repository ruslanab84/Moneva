# Financial AI tool layer

Financial questions now follow:

`Question → typed Foundation Models tool selection → LanguageModelSession with selected tools → typed Tool → FinancialToolService.Request → validated domain calculation over local SwiftData → FinancialToolResult JSON → model explanation`

Apple's `Tool` protocol and `@Generable` provide the function-calling schemas. No external dependency was added. Reference: [Apple tool-calling documentation](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling).

## Authorization boundary

Moneva has **no app login, authenticated user ID, tenant ownership column, or backend domain API**. This implementation is local-store isolation, not authenticated multi-tenant authorization. `FinancialToolService` captures the UI's `ModelContext`, `Scope`, and currency; these cannot be supplied or overridden through model arguments. Every invocation checks that the capability is active, enforces a six-call limit, and filters records by the fixed scope and currency before projection. The capability is revoked after each answer. Each question creates a fresh session.

Existing family CloudKit synchronization is unchanged. The AI tools read only the local store; they do not call CloudKit or upload data. An authenticated tenant guarantee would additionally require an approved identity lifecycle and account-specific storage/ownership design. A fabricated user ID would not establish that guarantee.

The model receives neither `ModelContext`, managed models, persistent IDs, notes, SQL, nor database schemas. SwiftData fetches are private to the service. Errors become stable status values without raw database error descriptions. Merchant filters are literal text, and category selection requires one exact normalized match in the fixed scope/kind. Argument strings and output labels are bounded. Money remains `Decimal` until encoded as a decimal string.

## Schemas and mapping

Definitions and registry: `Moneva/AskTools.swift`. `FinancialToolSelection` restricts routing to an enum of the ten registered names and at most three tools per question. This keeps unrelated function schemas out of the execution session. `Tool.parameters` exposes the generated `GenerationSchema` for each typed `Arguments` contract.

`FinancialPeriod` requires `period` (`all`, `today`, `yesterday`, `thisMonth`, `lastMonth`, `lastWeekend`, `custom`). `start` and `end` are optional ISO `YYYY-MM-DD` strings. For presets they are ignored: the named period is authoritative and redundant model dates cannot widen it. For custom ranges both dates must resolve successfully. Custom endpoints are inclusive; the domain converts them to a half-open date range using `Calendar`.

All fields below are required unless explicitly described as optional. An empty filter string explicitly means no filter.

| Tool / function | Arguments | Domain operation | Principal returned metrics |
|---|---|---|---|
| `GetTransactionsTool` / `getTransactions` | dates, kind (`expense/income/all`); optional category, merchant, minimum, maximum | `transactions` → `SpendingFilter.results/amount` | expense/income totals separately; dated purchase rows |
| `GetSpendingByCategoryTool` / `getSpendingByCategory` | dates, category (empty for breakdown) | `spending` → `Budgeting.spendingByCategory` | expense total; category allocation rows |
| `GetIncomeTool` / `getIncome` | FinancialPeriod | `income` → `SpendingFilter` with income fixed | income |
| `GetBudgetTool` / `getBudget` | year (1900–2200), month (1–12) | `budget` → `Budgeting.monthRange/spent` | limit, spent, remaining; category limits/usage |
| `GetSubscriptionsTool` / `getSubscriptions` | name, period (`monthly/thisMonth/nextTwelveMonths/restOfYear/details/unsupported`) | `subscriptions` → `Subscriptions.monthlyTotal/projectedCost/firstFutureDate` | monthlyScheduled, optional projectedCost; active schedule rows |
| `ComparePeriodsTool` / `comparePeriods` | first, second (FinancialPeriod); optional category | `compare` → two scoped spending totals | firstExpense, secondExpense, differenceFirstMinusSecond, counts |
| `GetMerchantSpendingTool` / `getMerchantSpending` | dates, nonblank merchant | `merchant` → `SpendingFilter` with expense fixed | expense |
| `GetUpcomingPaymentsTool` / `getUpcomingPayments` | days (1–366) | `upcoming` → `Subscriptions.firstFutureDate/nextDate/hasEnded` | scheduledTotal; future subscription occurrences |
| `GetFinancialSummaryTool` / `getFinancialSummary` | FinancialPeriod | `summary` → separate expense/income totals, Decimal subtraction | expense, income, net |
| `GetForecastTool` / `getForecast` | none | `forecast` → `Budgeting.forecast` (same as the Home forecast card) | recordedBalance, expectedIncome, scheduledSubscriptions, estimatedExpenses, projectedMonthEnd |

Amount bounds must be nonnegative decimal strings (or null/empty), no more than 30 characters, with minimum ≤ maximum. Text filters are at most 100 characters. Unknown/ambiguous categories fail closed. No tool accepts currency, scope, user IDs, arbitrary predicates, table names, or SQL.

`FinancialToolResult` is Codable JSON:

```json
{
  "status": "ok",
  "currency": "USD",
  "scope": "personal",
  "metrics": {"expense": "340", "startInclusive": "2026-08-01", "endExclusive": "2026-09-01"},
  "rows": [],
  "count": 1,
  "truncated": false
}
```

Statuses: `ok`, `empty`, `invalidArguments`, `unavailable`, `accessDenied`, `limitReached`. Rows contain `label`, decimal-string `amount`, and optional `date`, `kind`, `spent`, `remaining`. Lists contain at most 12 rows, labels at most 80 characters. Aggregates cover all matching records even when rows are truncated. `count` means matching transactions, budget limits, active subscriptions, or scheduled occurrences, depending on the operation. Optional `message` explains forecast/coverage limits. Comparison differences are first minus second; missing records do not establish zero real-world activity. Upcoming payments are subscription schedules only, not bank bills.

## Integration

- `SpendingAssistantView.swift`: Ask and Explain use the registry; manual reports stay deterministic. Search extracts typed filters and performs no model-based financial explanation.
- `SubscriptionInsight.swift` and `SubscriptionsView.swift`: subscription Q&A uses the same service. Recurring-candidate classification obtains bounded, precomputed facts through `FinancialFactsTool`.
- `SmartInsights.swift`: explanation selection obtains its precomputed choices through `FinancialFactsTool`.
- `VoiceDraft.swift`: shared generation wrapper accepts registered tools. User-entered voice/text/receipt drafting remains a separate structured-input flow.
- `MonevaApp.swift`: opt-in DEBUG model-query evaluation.

`FinancialFactsTool` is a separate, read-only snapshot tool for existing ID-selection flows. Its empty argument schema cannot fetch more information. It returns up to eight indexed facts from already-scoped domain calculations. It holds value strings, not database objects.

The answer wrapper rejects responses with no tool invocation or failed tool results and provides a deterministic empty-result response. Model availability, refusal, and generation failures use the existing UI error path; manual filters/reports remain available. Comparison explanations preserve the domain-authored signed difference and date labels verbatim, because live testing found a model could misstate the difference despite correct tool values. Other natural-language phrasing remains model behavior, not an authorization guarantee.

## Verification

`FinancialToolsSelfCheck.swift`, called by `aiFeaturesSelfCheck()` on every DEBUG launch, uses an isolated in-memory store. It covers all ten domain operations, JSON round-trip, generated argument decoding, mixed scopes/currencies/kinds, unknown category, malformed/reversed bounds, invalid periods, SQL-like text, deterministic empty/error answer fallbacks, revoked capability, call limits, unavailable budget state, and row/notes payload limits.

Synthetic query evaluation is opt-in: set `MONEVA_TOOL_MODEL_CHECK=1` in the Xcode scheme's Run environment on an Apple Intelligence-capable device. It invokes the real registry/model, checks the selected tool, expected financial metric, and presence of the calculated amount in the final answer, and attempts a cross-scope/SQL prompt injection. Its data store is synthetic, never the user's store.

| Evaluation question | Expected tool / metric |
|---|---|
| List my expense transactions last month | getTransactions / expense 340 |
| How much did I spend on Restaurants last month? | getSpendingByCategory / expense 340 |
| How much income did I record this month? | getIncome / income 900 |
| How much budget remains this month? | getBudget / remaining 450 |
| What is my monthly subscription cost? | getSubscriptions / monthlyScheduled 10 |
| Compare this month's spending to last month | comparePeriods / difference -290 |
| How much did I spend at Cafe last month? | getMerchantSpending / expense 340 |
| What subscription payments are due in the next 1 day? | getUpcomingPayments / scheduledTotal 10 |
| Summarize income, expenses and net this month | getFinancialSummary / net 850 |

No backend API exists to fault-inject. The checks exercise the structured unavailable path using an ambiguous persisted budget; SDK/API errors use the wrapper's existing error handling. Live model routing and injection results must be reported separately from deterministic handler checks.

### Verified run — 2026-09-15

- Debug build passed on the iOS 26.5 iPhone 17 Pro simulator.
- Startup financial-tool, AI-feature, and Smart Insights self-checks passed.
- Real `LanguageModelSession` evaluation passed all nine queries, checking routing, calculated metrics, and final-answer amounts.
- Cross-scope/SQL prompt-injection evaluation passed; query failures: **0**.
- `git diff --check` passed.

These are simulator results, not physical-device results or proof of resistance to every possible prompt injection. Authenticated tenant isolation remains pending an approved authentication/storage design; only the existing local-store scope/currency boundary is implemented.
