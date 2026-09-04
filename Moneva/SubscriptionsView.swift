import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case active, paused, shared
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Query(sort: \Subscription.nextPaymentDate) private var subscriptions: [Subscription]
    @Query private var categories: [SpendingCategory]
    @Query private var transactions: [Transaction]

    @State private var filter: Filter = .active
    @State private var advisor = SubscriptionAdvisor()
    @State private var pending: [SubscriptionEngine.Pending] = []
    @State private var editing: Subscription?
    @State private var creating: DetectedSubscription?
    @State private var isCreating = false
    @State private var question = ""

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }

    private var shown: [Subscription] {
        switch filter {
        case .active: return subscriptions.filter { $0.status == .active }
        case .paused: return subscriptions.filter { $0.status == .paused }
        case .shared: return subscriptions.filter { $0.scope == .shared }
        }
    }

    private var soon: [Subscription] {
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        return shown.filter { $0.nextPaymentDate <= horizon }
    }

    private var later: [Subscription] {
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        return shown.filter { $0.nextPaymentDate > horizon }
    }

    var body: some View {
        NavigationStack {
            ScreenScroll(title: "Subscriptions", eyebrow: "Every month") {
                totals

                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                ForEach(pending) { item in confirmation(item) }
                detection
                assistant

                if shown.isEmpty {
                    EmptyHint(
                        title: emptyTitle,
                        message: "Add a service to see what leaves your account each month.",
                        symbol: "arrow.triangle.2.circlepath"
                    )
                }

                group("Next 7 days", soon)
                group("Later", later)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") { isCreating = true }
                }
            }
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in
                // Coming back after a few days is exactly when a charge is due.
                if phase == .active { Task { await refresh() } }
            }
            .sheet(isPresented: $isCreating) { SubscriptionEditorView(scope: scope) }
            .sheet(item: $editing) { SubscriptionEditorView(editing: $0) }
            .sheet(item: $creating) { draft in
                SubscriptionEditorView(scope: scope, draft: draft, categories: categories)
            }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .active: return "No active subscriptions"
        case .paused: return "Nothing is paused"
        case .shared: return "No shared subscriptions"
        }
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Active total")
            Text(Subscriptions.monthlyTotal(subscriptions.filter { $0.status == .active }).money(currencyCode))
                .font(.money(.largeTitle))
                .foregroundStyle(Palette.ink)
            Text("\(subscriptions.filter { $0.status == .active }.count) active · \(subscriptions.filter { $0.status == .paused }.count) paused")
                .font(.footnote)
                .foregroundStyle(Palette.inkMuted)
        }
        .monevaCard()
    }

    /// Ask-before-adding charges that are already due. Nothing is written until
    /// one of these two buttons is tapped.
    private func confirmation(_ item: SubscriptionEngine.Pending) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Due now")
            Text("\(item.subscription.name) was due on \(item.date.formatted(date: .abbreviated, time: .omitted)). Add \(item.subscription.amount.money(item.subscription.currency)) as an expense?")
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
            HStack(spacing: 12) {
                Button("Skip this month") {
                    SubscriptionEngine.skip(item, in: context)
                    Task { await refresh() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Palette.ground, in: .rect(cornerRadius: 14))

                Button("Add it") {
                    SubscriptionEngine.confirm(item, in: context)
                    Task { await refresh() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.card)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Palette.accent, in: .rect(cornerRadius: 14))
            }
        }
        .monevaCard()
    }

    @ViewBuilder
    private var detection: some View {
        switch advisor.phase {
        case .working where advisor.detected.isEmpty:
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking through your history…").font(.footnote).foregroundStyle(Palette.inkMuted)
            }
            .monevaCard()
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(Palette.over).monevaCard()
        default:
            EmptyView()
        }

        ForEach(advisor.detected) { item in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Eyebrow("Spotted on device")
                    Spacer()
                    Text("Draft").font(.caption2.weight(.semibold)).foregroundStyle(Palette.warning)
                }
                Text("\(item.reason.isEmpty ? "This looks like it repeats." : item.reason) Track \(item.name) at \(item.amount.money(currencyCode)) a month?")
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
                HStack(spacing: 12) {
                    Button("Ignore") { advisor.dismissDetection(item) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Palette.ground, in: .rect(cornerRadius: 14))

                    Button("Add it") { creating = item }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.card)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Palette.accent, in: .rect(cornerRadius: 14))
                }
            }
            .monevaCard()
        }
    }

    @ViewBuilder
    private var assistant: some View {
        if !subscriptions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Ask about these")
                HStack(spacing: 10) {
                    TextField("How much will subscriptions cost this month?", text: $question, axis: .vertical)
                        .font(.subheadline)
                        .submitLabel(.send)
                    Button("Ask") {
                        Task { await advisor.ask(question, subscriptions: subscriptions) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !advisor.answer.isEmpty {
                    Text(advisor.answer).font(.subheadline).foregroundStyle(Palette.ink)
                }
                if let reason = SubscriptionAdvisor.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(Palette.inkFaint)
                }
            }
            .monevaCard()
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [Subscription]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(title)
                VStack(spacing: 0) {
                    ForEach(items, id: \.persistentModelID) { subscription in
                        Button { editing = subscription } label: { row(subscription) }
                    }
                }
                .monevaCard(padding: 14)
            }
        }
    }

    private func row(_ subscription: Subscription) -> some View {
        HStack(spacing: 12) {
            CategoryBadge(category: subscription.category)
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(subtitle(for: subscription)).font(.footnote).foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 8)
            Text(subscription.amount.money(subscription.currency))
                .font(.money(.title3))
                .foregroundStyle(Palette.ink)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func subtitle(for subscription: Subscription) -> String {
        var parts = [subscription.nextPaymentDate.formatted(date: .abbreviated, time: .omitted)]
        parts.append(subscription.frequency.title.lowercased())
        if subscription.scope == .shared { parts.append("Shared") }
        if subscription.status == .paused { parts.append("Paused") }
        if let days = subscription.reminderDays { parts.append("reminder \(days)d before") }
        return parts.joined(separator: " · ")
    }

    private func refresh() async {
        pending = SubscriptionEngine.catchUp(in: context)
        await advisor.detect(from: transactions, categories: categories, existing: subscriptions, scope: scope)
    }
}
