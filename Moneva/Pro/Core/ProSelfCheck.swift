import Foundation

/// Regression net for the free-tier rules (CLAUDE.md: asserts here, not a test target).
func proSelfCheck() {
    // Creation limits: open below the limit, closed at it, Pro always open.
    for count in 0...4 { assert(ProLimits.canCreate(.subscription, count: count, isPro: false), "subscription \(count) of 5 is allowed") }
    assert(!ProLimits.canCreate(.subscription, count: 5, isPro: false), "the sixth subscription needs Pro")
    assert(!ProLimits.canCreate(.subscription, count: 8, isPro: false), "an already-over-limit user can't add, but nothing removes theirs")
    assert(ProLimits.canCreate(.subscription, count: 8, isPro: true), "Pro has no subscription limit")
    assert(ProLimits.canCreate(.goal, count: 1, isPro: false) && !ProLimits.canCreate(.goal, count: 2, isPro: false), "two free goals")
    assert(ProLimits.canCreate(.account, count: 0, isPro: false) && !ProLimits.canCreate(.account, count: 1, isPro: false), "one free account")
    assert(ProLimits.canCreate(.account, count: 9, isPro: true), "Pro has no account limit")

    // AI allowance.
    assert(ProLimits.canUseAI(usedThisMonth: 4, isPro: false) && !ProLimits.canUseAI(usedThisMonth: 5, isPro: false), "five AI entries a month")
    assert(ProLimits.canUseAI(usedThisMonth: 500, isPro: true), "Pro AI is unlimited")

    // Banner only on Home and Transactions, never for Pro.
    assert(ProLimits.showsBanner(tab: .home, isPro: false) && ProLimits.showsBanner(tab: .transactions, isPro: false))
    assert(!ProLimits.showsBanner(tab: .budget, isPro: false) && !ProLimits.showsBanner(tab: .goals, isPro: false) && !ProLimits.showsBanner(tab: .subs, isPro: false))
    assert(!ProLimits.showsBanner(tab: .home, isPro: true), "Pro never sees the banner")

    // Monthly counter: resets on a new month and across a year boundary.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let suite = "proSelfCheck"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let jan31 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 23, minute: 59))!
    let feb1 = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
    let dec31 = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23))!
    let jan1 = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
    assert(AIUsage.count(now: jan31, calendar: calendar, defaults: defaults) == 0)
    AIUsage.record(now: jan31, calendar: calendar, defaults: defaults)
    AIUsage.record(now: jan31, calendar: calendar, defaults: defaults)
    assert(AIUsage.count(now: jan31, calendar: calendar, defaults: defaults) == 2, "two saves in January")
    assert(AIUsage.count(now: feb1, calendar: calendar, defaults: defaults) == 0, "February starts at zero")
    AIUsage.record(now: dec31, calendar: calendar, defaults: defaults)
    assert(AIUsage.count(now: jan1, calendar: calendar, defaults: defaults) == 0, "a new year starts at zero")
    assert(AIUsage.count(now: dec31, calendar: calendar, defaults: defaults) == 1, "December keeps its own count")
    defaults.removePersistentDomain(forName: suite)

    // Banner heights: Home and Transactions both keep a banner alive in the TabView. Leaving one
    // screen must not zero the offset the other, still visible banner needs.
    var banners = BannerHeights()
    let homeBanner = UUID(), transactionsBanner = UUID()
    banners.report(homeBanner, height: 50)
    banners.report(transactionsBanner, height: 50)
    banners.remove(transactionsBanner)
    assert(banners.height == 50, "the Home banner is still showing after Transactions' banner goes away")
    banners.report(homeBanner, height: 0)
    assert(banners.height == 0, "a banner that failed to load stops taking space")
    banners.report(homeBanner, height: 50)
    banners.remove(homeBanner)
    assert(banners.height == 0, "no banner on screen, no offset")

    // Entitlements: only our products unlock, and a revoked/refunded one never does.
    assert(ProStore.unlocks(productID: "RuslanAbd.Moneva.pro.monthly", isRevoked: false))
    assert(ProStore.unlocks(productID: "RuslanAbd.Moneva.pro.lifetime", isRevoked: false))
    assert(!ProStore.unlocks(productID: "RuslanAbd.Moneva.pro.yearly", isRevoked: true), "a refund takes Pro away")
    assert(!ProStore.unlocks(productID: "com.other.product", isRevoked: false), "an unknown product never unlocks Pro")
}
