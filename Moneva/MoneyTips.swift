import SwiftUI

/// App-authored advice on saving and growing money. Static content — no model,
/// no records, no arithmetic — so nothing here can misreport a number.
enum MoneyTips {
    struct Tip {
        let title: String.LocalizationValue
        let body: String.LocalizationValue
    }

    static let all: [Tip] = [
        Tip(title: "Pay yourself first",
            body: "Move a fixed share of every payday into savings before you budget the rest. What never reaches the spending account never gets spent."),
        Tip(title: "Sleep on it",
            body: "Give any non-essential purchase 24 hours. Most impulse buys lose their appeal overnight."),
        Tip(title: "Audit your subscriptions",
            body: "Once a quarter, list every recurring charge and cancel the ones you did not use last month."),
        Tip(title: "Build a one-month buffer",
            body: "Keep one month of expenses in cash before anything else. It turns emergencies into inconveniences."),
        Tip(title: "Round up the change",
            body: "Round every expense up to the nearest whole unit and save the difference. Small and painless, it adds up over a year."),
        Tip(title: "Cook one more meal at home",
            body: "Replacing two restaurant meals a week with home cooking is often the single largest cut available to you."),
        Tip(title: "Negotiate your recurring bills",
            body: "Phone, internet and insurance providers keep retention offers for people who ask. One call can lower a bill for a whole year."),
        Tip(title: "Aim for three to six months",
            body: "Grow your emergency fund to three months of expenses if your income is steady, six if it is not."),
        Tip(title: "Automate the transfer",
            body: "Schedule savings for the day after payday. Willpower is unreliable; a standing order is not."),
        Tip(title: "Let raises go to savings",
            body: "When your income rises, bank the difference instead of upgrading your lifestyle. Lifestyle creep quietly eats every raise."),
        Tip(title: "Pay off the highest rate first",
            body: "Attack the debt with the steepest interest while paying the minimum on the rest. That saves the most money per unit paid."),
        Tip(title: "Shop with a list",
            body: "A written grocery list and a full stomach beat any coupon. Unplanned items are where the budget leaks."),
        Tip(title: "Know your fixed costs",
            body: "Add up rent, utilities and subscriptions. Everything above that number is where you actually have a choice."),
        Tip(title: "Review last month before planning this one",
            body: "Look at what you really spent, category by category, before setting a new limit. Budgets built on guesses break."),
        Tip(title: "Use a separate account for bills",
            body: "Keep fixed costs in their own account so the money left over is genuinely free to spend."),
        Tip(title: "Question the annual plan",
            body: "Yearly billing is cheaper only for things you are certain to still use in twelve months. Otherwise monthly buys you an exit."),
        Tip(title: "Track the small and frequent",
            body: "Coffee, delivery fees and taxis rarely feel like decisions, yet together they often outweigh the rent increase you worried about."),
        Tip(title: "Set a goal with a date",
            body: "A savings target with a deadline turns an intention into a monthly number you can actually check."),
        Tip(title: "Buy quality where you use it daily",
            body: "Shoes, a mattress, a chair: the cost per use is what matters, not the price tag."),
        Tip(title: "Wait for the second sale",
            body: "If you missed a discount, the item will be discounted again. Missing a sale costs nothing; buying what you did not need costs the full price."),
        Tip(title: "Keep an eye on the interest you earn",
            body: "Idle cash in a zero-interest account loses value every year. A savings account with a real rate is the lowest-effort return available."),
        Tip(title: "Invest what you will not touch",
            body: "Only invest money you can leave alone for years. Everything you may need sooner belongs in cash."),
        Tip(title: "Spread your investments",
            body: "A broad, low-cost index fund beats most attempts at picking winners, and it costs far less in fees."),
        Tip(title: "Mind the fees",
            body: "A one percent annual fee can eat a quarter of your returns over decades. Compare costs before performance claims."),
        Tip(title: "Invest on a schedule",
            body: "Investing the same amount every month removes the need to guess the right moment to buy."),
        Tip(title: "Take the employer match",
            body: "Any matched retirement contribution is an immediate, guaranteed return. Contribute at least enough to collect all of it."),
        Tip(title: "Insure the disasters, not the annoyances",
            body: "Cover what would ruin you — health, income, home. Skip the extended warranty on a cheap appliance."),
        Tip(title: "Give every windfall a job",
            body: "Decide where a bonus or refund goes before it lands: debt, buffer or goal. Unassigned money disappears."),
        Tip(title: "Keep a no-spend day each week",
            body: "One deliberate day without any purchase resets habits and shows how much of your spending was automatic."),
        Tip(title: "Check for forgotten price rises",
            body: "Services raise prices quietly at renewal. Compare what you pay today with what you signed up for."),
        Tip(title: "Write down why you are saving",
            body: "A concrete reason — a move, a course, a calmer year — survives temptation far better than a number in an account does.")
    ]

    /// Day-of-year rotation: every tip appears equally often, unlike a day-of-month
    /// rotation, which would surface the 31st tip only about seven times a year.
    static func index(for date: Date, calendar: Calendar = .current) -> Int {
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        return (day - 1) % all.count
    }

    static func tip(for date: Date, calendar: Calendar = .current) -> Tip {
        all[index(for: date, calendar: calendar)]
    }
}

struct MoneyTipCard: View {
    let date: Date

    var body: some View {
        let number = MoneyTips.index(for: date) + 1
        let tip = MoneyTips.tip(for: date)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb").foregroundStyle(Palette.accent)
                Eyebrow("Money tips")
            }

            Text(String(localized: tip.title))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)

            Text(String(localized: tip.body))
                .font(.footnote)
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Palette.line)

            Text("Tip \(number) of \(MoneyTips.all.count) · a new one every day")
                .font(.caption)
                .foregroundStyle(Palette.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .monevaCard()
        .accessibilityElement(children: .combine)
    }
}
