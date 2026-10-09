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
