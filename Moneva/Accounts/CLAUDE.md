## Accounts and transfers

[Accounts.swift](Core/Accounts.swift) (pure helpers) + [AccountsView.swift](Views/AccountsView.swift). `Account` is deliberately **not** a partition the way `Scope` is — totals, charts, budgets, forecasts and the AI tools are never filtered by account, and an assert in `monevaSelfCheck()` guards that. Each account does carry a `scope` (`scopeRaw: String?`, nil reads as personal): it only decides whether the account syncs to the family (see [Sync](../Sync/CLAUDE.md)) and which side's forecast its opening balance feeds. One list still shows every account in both scopes.

- Balance = `openingBalance` + same-currency transactions + same-currency transfers. Nothing is converted; a transaction in another currency simply does not count toward that account's balance.
- A cross-account move is its own `Transfer` `@Model`, never two `Transaction`s — that's why no existing total needed new exclusion logic. `Accounts.canTransfer` requires two distinct live accounts with matching currency.
- `Transaction.account` and `Subscription.account` are optional relationships (additive column, lightweight migration). A recurring charge lands in the subscription's account only when the currency matches, otherwise it is recorded with no account. Archived accounts leave the pickers but keep receiving charges from subscriptions already pointing at them.
- The one place accounts feed a total: `Budgeting.forecast` adds same-currency `openingBalance`s (archived included, negatives allowed) to the recorded balance, each account in its own scope only — Personal sums personal accounts, Shared sums shared ones. Daily Limit (automatic) inherits this through the forecast.
- A SwiftUI `Picker` over `Account?` needs `.tag(Account?.some($0))`.
