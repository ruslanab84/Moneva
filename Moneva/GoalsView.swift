import SwiftUI
import SwiftData

struct GoalsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @Query(sort: \Goal.createdAt, order: .reverse) private var goals: [Goal]
    @State private var isAdding = false
    @State private var topUpTarget: Goal?
    @State private var topUpText = ""

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
    private var visible: [Goal] { goals.filter { $0.scope == scope } }

    var body: some View {
        ScreenScroll(title: "Savings goals", eyebrow: "Goals") {
            ScopePicker(scope: Binding(get: { scope }, set: { scopeRaw = $0.rawValue }))

            if visible.isEmpty {
                EmptyHint(
                    title: "No goals yet",
                    message: "A goal is a name, a target and whatever you have put aside so far.",
                    symbol: "flag"
                )
            }

            ForEach(visible, id: \.persistentModelID) { goal in
                goalCard(goal)
            }

            Button("New goal", systemImage: "plus") { isAdding = true }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
        }
        .sheet(isPresented: $isAdding) { GoalEditor(scope: scope) }
        .alert("Add money", isPresented: Binding(get: { topUpTarget != nil }, set: { if !$0 { topUpTarget = nil } })) {
            TextField("Amount", text: $topUpText).keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) { topUpTarget = nil }
            Button("Add") {
                let amount = AmountField.parse(topUpText)
                if let goal = topUpTarget, amount > 0 { goal.saved += amount }
                topUpTarget = nil
                topUpText = ""
            }
        } message: {
            Text(topUpTarget.map { "Put money aside for \($0.name)." } ?? "")
        }
    }

    @ViewBuilder
    private func goalCard(_ goal: Goal) -> some View {
        let progress = Budgeting.progress(spent: goal.saved, limit: goal.target)

        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: goal.symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(Color(hex: goal.tintHex))
                    .frame(width: 44, height: 44)
                    .background(Color(hex: goal.tintHex).opacity(0.16), in: .rect(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.name).font(.headline).foregroundStyle(Palette.ink)
                    Text(subtitle(goal)).font(.footnote).foregroundStyle(Palette.inkMuted)
                }
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.money(.title3))
                    .foregroundStyle(Palette.ink)
            }

            Text("\(goal.saved.money()) of \(goal.target.money())")
                .font(.money(.title))
                .foregroundStyle(Palette.ink)

            ProgressBar(progress: progress, tint: Color(hex: goal.tintHex), height: 10)

            HStack {
                Text("\(goal.remaining.money()) to go")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
                Spacer()
                Button("Add money") {
                    topUpText = ""
                    topUpTarget = goal
                }
                .font(.footnote.weight(.semibold))
                .tint(Palette.accent)
            }
        }
        .monevaCard()
        .contextMenu {
            Button("Delete goal", systemImage: "trash", role: .destructive) { context.delete(goal) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(goal.name), \(goal.saved.money()) of \(goal.target.money()), \(Int(progress * 100)) percent saved")
    }

    private func subtitle(_ goal: Goal) -> String {
        var parts: [String] = []
        if let deadline = goal.deadline {
            parts.append("Deadline \(deadline.formatted(.dateTime.month(.abbreviated).year()))")
        }
        parts.append(goal.scope.title)
        return parts.joined(separator: " · ")
    }
}

struct GoalEditor: View {
    let scope: Scope

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var target: Decimal = 0
    @State private var saved: Decimal = 0
    @State private var symbol = "airplane"
    @State private var hasDeadline = false
    @State private var deadline = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now

    private let symbols = ["airplane", "shield", "laptopcomputer", "house", "car", "gift", "graduationcap", "heart"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal") {
                    TextField("Name", text: $name)
                    AmountField(title: "Target amount", value: $target)
                    AmountField(title: "Already saved", value: $saved)
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(symbols, id: \.self) { candidate in
                            Button { symbol = candidate } label: {
                                Image(systemName: candidate)
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                                    .background(symbol == candidate ? Palette.accentSoft : Color.clear, in: .rect(cornerRadius: 14))
                                    .foregroundStyle(symbol == candidate ? Palette.accent : Palette.inkMuted)
                            }
                            .accessibilityLabel(candidate)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Toggle("Deadline", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("By", selection: $deadline, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("New goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.isEmpty || target <= 0)
                }
            }
        }
    }

    private func save() {
        let goal = Goal(
            name: name,
            symbol: symbol,
            tintHex: "7A5B86",
            target: target,
            saved: saved,
            deadline: hasDeadline ? deadline : nil,
            scope: scope
        )
        context.insert(goal)
        dismiss()
    }
}
