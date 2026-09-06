#if DEBUG
import Foundation
import SwiftData

@MainActor
func aiFeaturesSelfCheck() {
    do {
        let container = try ModelContainer(for: Transaction.self, SpendingCategory.self, TransactionAllocation.self,
            MerchantCategoryRule.self, Subscription.self, SubscriptionPayment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let food = SpendingCategory(name: "Food", symbol: "cart", tintHex: "B5813F", softHex: "F0E6D6")
        let home = SpendingCategory(name: "Home", symbol: "house", tintHex: "B5813F", softHex: "F0E6D6")
        let shared = SpendingCategory(name: "Shared", symbol: "house", tintHex: "B5813F", softHex: "F0E6D6", scope: .shared)
        context.insert(food); context.insert(home); context.insert(shared)
        try context.save()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Baku")!
        assert(DraftResolver.grounded("Coffee Shop", in: "coffee 5 AZN").isEmpty, "invented merchant labels are removed")
        assert(DraftResolver.grounded("Bravo", in: "Spent 5 AZN at Bravo") == "Bravo")
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5))!
        let forecastStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6))!
        let forecastEnd = calendar.date(byAdding: .month, value: 12, to: forecastStart)!
        let forecastRange = forecastStart..<forecastEnd
        let iCloud = Subscription(name: "iCloud", amount: 3, currency: "AZN",
            nextPaymentDate: calendar.date(from: DateComponents(year: 2026, month: 9, day: 8))!, category: food, calendar: calendar)
        let otherCurrency = Subscription(name: "Other service", amount: 10, currency: "USD", nextPaymentDate: forecastStart, category: home, calendar: calendar)
        assert(Subscriptions.projectedCost(iCloud, in: forecastRange, calendar: calendar) == 36, "iCloud at 3 AZN monthly costs 36 AZN over the next year")
        let sharedCloud = Subscription(name: "iCloud", amount: 100, currency: "AZN", nextPaymentDate: forecastStart, scope: .shared, category: shared, calendar: calendar)
        let question = "How much will I spend on iCloud in a year?"
        let request = SubscriptionQuestion(name: "iCloud", period: .nextTwelveMonths)
        let selected = request.selectedSubscriptions(in: [iCloud, otherCurrency, sharedCloud], scope: .personal, question: question)
        assert(selected.count == 1 && selected[0] === iCloud, "a named question never includes another service or scope")
        assert(SubscriptionQuestion(name: "ALL", period: .nextTwelveMonths).selectedSubscriptions(in: [iCloud, sharedCloud], scope: .personal, question: question).isEmpty, "a model cannot replace a named service with all subscriptions")
        assert(SubscriptionQuestion(name: "Dropbox", period: .nextTwelveMonths).selectedSubscriptions(in: [iCloud], scope: .personal, question: "Dropbox cost per year?").isEmpty, "unknown services never fall back to all subscriptions")
        let annualAnswer = SubscriptionDigest.costAnswer(.nextTwelveMonths, subscriptions: [iCloud], now: forecastStart, calendar: calendar)
        assert(annualAnswer.hasPrefix("iCloud: \(Decimal(36).money("AZN")) for the next 12 months"), "the answer uses the annual total for the selected subscription")
        let combinedAnswer = SubscriptionDigest.costAnswer(.nextTwelveMonths, subscriptions: [iCloud, otherCurrency], now: forecastStart, calendar: calendar)
        assert(combinedAnswer.contains(Decimal(120).money("USD")) && combinedAnswer.contains(Decimal(36).money("AZN")), "currencies must not be summed together")
        assert(SubscriptionDigest.costAnswer(.restOfYear, subscriptions: [iCloud], now: forecastStart, calendar: calendar).hasPrefix("iCloud: \(Decimal(12).money("AZN"))"), "remaining calendar year differs from a full year")
        iCloud.endDate = calendar.date(from: DateComponents(year: 2026, month: 12, day: 8))!
        assert(Subscriptions.projectedCost(iCloud, in: forecastRange, calendar: calendar) == 12, "the final payment date is inclusive")
        iCloud.status = .paused
        assert(Subscriptions.projectedCost(iCloud, in: forecastRange, calendar: calendar) == 0)
        iCloud.status = .active
        iCloud.endDate = date
        assert(Subscriptions.projectedCost(iCloud, in: forecastRange, calendar: calendar) == 0, "ended subscriptions have no future cost")
        let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 31))!
        iCloud.endDate = nil
        iCloud.nextPaymentDate = january
        iCloud.anchorDay = 31
        assert(Subscriptions.projectedCost(iCloud, in: january..<calendar.date(byAdding: .year, value: 1, to: january)!, calendar: calendar) == 36, "a payment today is included and the anniversary is excluded, including short months")
        var first = TransactionDraft(amount: 5, merchant: "Cafe", date: date, category: food, currency: "AZN", source: .text, reviewed: true, rememberCategory: true)
        let second = TransactionDraft(amount: 12, merchant: "Taxi", date: date, category: home, currency: "USD", source: .voice, reviewed: true)
        var invalid = first
        invalid.id = UUID()
        invalid.amount = 0
        do { try DraftStore.save([first, invalid], in: context); assertionFailure("Incomplete batch was saved") } catch {}
        let emptyCount = try context.fetchCount(FetchDescriptor<Transaction>())
        assert(emptyCount == 0)
        try DraftStore.save([first, second], in: context)
        try DraftStore.save([first, second], in: context)
        let savedCount = try context.fetchCount(FetchDescriptor<Transaction>())
        assert(savedCount == 2, "retry must not duplicate saves")
        let rules = try context.fetch(FetchDescriptor<MerchantCategoryRule>())
        assert(rules.count == 1 && CategoryLibrary.ruleCategory(merchant: " cafe ", scope: .personal, rules: rules) === food)
        assert(CategoryLibrary.ruleCategory(merchant: "Cafe", scope: .shared, rules: rules) == nil)
        first.category = shared
        assert(!first.canSave, "personal entry cannot use shared-only category")

        var items = [ReceiptItem(name: "Food", amount: 10, category: food), ReceiptItem(name: "Cleaning", amount: 5, category: home),
            ReceiptItem(name: "Discount", kind: .discount, amount: 1, category: food), ReceiptItem(name: "Tax included", kind: .tax, amount: 2, alreadyIncluded: true, category: food)]
        assert(ReceiptMath.reconciled(items, total: 14, currency: "AZN", scope: .personal), "included tax isn't added twice")
        assert(!ReceiptMath.reconciled(items, total: 16, currency: "AZN", scope: .personal), "mismatched split is blocked")
        items[3].alreadyIncluded = false
        assert(ReceiptMath.reconciled(items, total: 16, currency: "AZN", scope: .personal), "exclusive tax is counted explicitly")
        let receipt = TransactionDraft(amount: 16, merchant: "Market", date: date, category: food, currency: "AZN", source: .receipt, reviewed: true)
        try DraftStore.save([receipt], in: context, allocations: ReceiptMath.allocations(items))
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let savedReceipt = transactions.first { $0.source == .receipt }!
        assert(transactions.count == 3 && savedReceipt.allocations.count == 2)
        assert(savedReceipt.amount(in: food) == 11 && savedReceipt.amount(in: home) == 5 && savedReceipt.amount == 16)
        assert(Budgeting.spent(transactions, in: Budgeting.monthRange(for: date, calendar: calendar), scope: .personal, currency: "AZN") == 21, "one receipt total, USD excluded")
        assert(ReceiptMath.duplicates(receipt, in: transactions, calendar: calendar).count == 1)
        let filter = SpendingFilter(category: food, scope: .personal)
        let matches = filter.results(transactions)
        assert(matches.reduce(Decimal.zero) { $0 + filter.amount($1) } == 16, "category search uses allocations")
        let totalOnly = TransactionDraft(amount: Decimal(string: "14.25")!, merchant: "Another market", date: date, category: food, currency: "AZN", source: .receipt, reviewed: true)
        try DraftStore.save([totalOnly], in: context)
        try DraftStore.save([totalOnly], in: context)
        let totalOnlyTransactions = try context.fetch(FetchDescriptor<Transaction>()).filter { $0.draftID == totalOnly.id.uuidString }
        assert(totalOnlyTransactions.count == 1, "receipt total is saved once")
        let totalOnlyReceipt = totalOnlyTransactions[0]
        assert(totalOnlyReceipt.amount == totalOnly.amount && totalOnlyReceipt.allocations.isEmpty && totalOnlyReceipt.receiptItems == nil)
        assert(totalOnlyReceipt.amount(in: food) == totalOnly.amount && totalOnlyReceipt.amount(in: home) == 0, "the whole receipt belongs to one category")
        let malicious = DraftedSearch(period: .all, start: nil, end: nil, category: "", merchant: "", minimum: "", maximum: "", currency: "", scope: "shared", kind: "expense", clarification: "")
        do { _ = try SpendingSearch.resolve(malicious, categories: [food], scope: .personal); assertionFailure("scope escalation accepted") } catch {}
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7))!
        let weekend = try SpendingSearch.range(.lastWeekend, now: monday, calendar: calendar)!
        assert(weekend.contains(date) && !weekend.contains(monday), "local weekend range is half-open")
        let subscription = Subscription(name: "Netflix", amount: 15, currency: "USD", nextPaymentDate: date, paymentMode: .ask, category: home, calendar: calendar)
        context.insert(subscription)
        try context.save()
        let due = try SubscriptionEngine.catchUp(in: context, now: date, calendar: calendar)
        assert(due.count == 1)
        try SubscriptionEngine.confirm(due[0], in: context, calendar: calendar)
        try SubscriptionEngine.confirm(due[0], in: context, calendar: calendar)
        assert(subscription.payments.count == 1, "a payment is idempotent")
        let past = subscription.payments[0].transaction!
        subscription.amount = 20
        subscription.currency = "AZN"
        subscription.category = food
        try context.save()
        assert(past.amount == 15 && past.currency == "USD" && past.category === home, "schedule edits preserve historical payments")
        let stale = SubscriptionEngine.Pending(subscription: subscription, period: "2026-10", date: calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!)
        subscription.nextPaymentDate = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))!
        try context.save()
        try SubscriptionEngine.confirm(stale, in: context, calendar: calendar)
        assert(subscription.payments.count == 1, "an old pending confirmation cannot rewrite a changed schedule")
        assert(Subscriptions.firstFutureDate(subscription, now: monday, calendar: calendar) == subscription.nextPaymentDate, "resuming preserves a later future payment date")
        subscription.status = .paused
        let resume = Subscriptions.firstFutureDate(subscription, now: monday, calendar: calendar)
        assert(resume >= monday, "resume skips paused billing periods")
        context.delete(subscription)
        try context.save()
        let afterDelete = try context.fetch(FetchDescriptor<Transaction>())
        assert(afterDelete.contains { $0 === past }, "deleting schedule preserves history")
        print("Moneva AI feature self-checks passed")
    } catch { assertionFailure("AI feature self-check failed: \(error)") }
}
#endif
