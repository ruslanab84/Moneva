import SwiftUI
import SwiftData

/// Settings › Trips: the active trip, past trips, and starting a new one.
struct TripsView: View {
    @Query(sort: \Trip.startDate, order: .reverse) private var trips: [Trip]
    @AppStorage(Trips.activeKey) private var activeRaw = ""
    @State private var isStarting = false

    private var active: Trip? { trips.first { $0.cloudID.uuidString == activeRaw } }

    var body: some View {
        Form {
            Section {
                if let active {
                    NavigationLink { TripDetailView(trip: active) } label: { TripLabel(trip: active) }
                } else {
                    Button("Start a trip", systemImage: "airplane") { isStarting = true }
                }
            } header: {
                Text("Active trip")
            } footer: {
                Text("While a trip is active, new entries are tagged with it and logged in its currency. Trip totals stay in each currency, never converted.")
            }
            let past = trips.filter { $0 !== active }
            if !past.isEmpty {
                Section("Past trips") {
                    ForEach(past, id: \.persistentModelID) { trip in
                        NavigationLink { TripDetailView(trip: trip) } label: { TripLabel(trip: trip) }
                    }
                }
            }
        }
        .navigationTitle("Trips")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if active != nil {
                Button("Start a trip", systemImage: "plus") { isStarting = true }
            }
        }
        .sheet(isPresented: $isStarting) { TripEditor() }
    }
}

private struct TripLabel: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(trip.name)
            Text("\(trip.currency) · \(trip.startDate.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(Palette.inkMuted)
        }
    }
}

/// Name, local currency, start date. Saving makes it the active trip.
private struct TripEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var trips: [Trip]
    @State private var name = ""
    @State private var currency = Money.code
    @State private var startDate = Date.now

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Trip name", text: $name)
                NavigationLink {
                    CurrencyPicker(code: $currency)
                } label: {
                    LabeledContent("Local currency") { CurrencyLabel(code: currency) }
                }
                DatePicker("Starts", selection: $startDate, displayedComponents: .date)
            }
            .navigationTitle("New trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let trip = Trip(name: String(trimmed.prefix(60)), currency: currency, startDate: startDate)
                        context.insert(trip)
                        Trips.start(trip, endingOthersIn: trips)
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
    }
}

/// A trip's totals — one line per currency per scope, never converted — and its entries.
struct TripDetailView: View {
    let trip: Trip
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var trips: [Trip]
    @AppStorage(Trips.activeKey) private var activeRaw = ""
    @State private var selected: Transaction?
    @State private var confirmingDelete = false

    private var isActive: Bool { trip.cloudID.uuidString == activeRaw }
    private var entries: [Transaction] { trip.transactions.sorted { $0.date > $1.date } }

    var body: some View {
        Form {
            Section {
                LabeledContent("Local currency") { CurrencyLabel(code: trip.currency) }
                LabeledContent("Started", value: trip.startDate.formatted(date: .abbreviated, time: .omitted))
                if let end = trip.endDate {
                    LabeledContent("Ended", value: end.formatted(date: .abbreviated, time: .omitted))
                }
                if isActive {
                    Button("End trip", systemImage: "flag.checkered") { Trips.end(trip) }
                } else {
                    Button("Make active again", systemImage: "airplane") { Trips.start(trip, endingOthersIn: trips) }
                }
            }

            // Personal and shared stay apart, like every other total.
            ForEach(Scope.allCases) { scope in
                let spent = Trips.totals(entries, trip: trip, scope: scope)
                let earned = Trips.totals(entries, trip: trip, scope: scope, kind: .income)
                if !spent.isEmpty || !earned.isEmpty {
                    Section(scope.title) {
                        ForEach(spent, id: \.currency) { LabeledContent("Spent", value: $0.amount.money($0.currency)) }
                        ForEach(earned, id: \.currency) { LabeledContent("Income", value: $0.amount.money($0.currency)) }
                    }
                }
            }

            Section("Transactions") {
                if entries.isEmpty {
                    Text("Nothing tagged yet. New entries join the trip while it is active; tag older ones from their edit screen.")
                        .foregroundStyle(Palette.inkMuted)
                }
                ForEach(entries, id: \.persistentModelID) { transaction in
                    TransactionRow(transaction: transaction)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = transaction }
                }
            }

            Section {
                Button("Delete trip", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("Its transactions stay; they just lose the tag.")
            }
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { tx in
            NavigationStack { TransactionEditView(transaction: tx) }
        }
        .confirmationDialog("Delete this trip?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Trips.end(trip)
                context.delete(trip)
                dismiss()
            }
        }
    }
}

/// Home: the active trip at a glance, in the Home scope.
struct TripCard: View {
    let trip: Trip
    let scope: Scope

    var body: some View {
        let spent = Trips.totals(trip.transactions, trip: trip, scope: scope)
        NavigationLink { TripDetailView(trip: trip) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(trip.name) · \(trip.currency)", systemImage: "airplane")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.inkFaint)
                        .flipsForRightToLeftLayoutDirection(true)
                }
                if spent.isEmpty {
                    Text("New entries log in \(trip.currency) and join this trip.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkMuted)
                } else {
                    HStack(spacing: 16) {
                        ForEach(spent, id: \.currency) { line in
                            Text(line.amount.money(line.currency)).font(.money(.title3)).foregroundStyle(Palette.ink)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .monevaCard()
        }
        .buttonStyle(.plain)
    }
}
