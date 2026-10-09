import SwiftUI
import SwiftData
import CloudKit

struct SettingsView: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Environment(\.dismiss) private var dismiss
    @Query private var members: [FamilyMember]
    @State private var activeShare: ShareBox?
    @State private var shareError: String?
    @State private var isLeaving = false
    @State private var isPaywall = false
    @Environment(ProStore.self) private var pro
    private var status = FamilySyncStatus.shared

    var body: some View {
        NavigationStack {
            Form {
                if !pro.isPro {
                    Section {
                        Button("Upgrade to Pro", systemImage: "sparkles") { isPaywall = true }
                    }
                }

                Section {
                    Picker("Theme", selection: $themeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Label(theme.title, systemImage: theme.symbol).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Appearance")
                }

                Section {
                    NavigationLink {
                        CurrencyPicker(code: $currencyCode)
                    } label: {
                        LabeledContent("Currency") { CurrencyLabel(code: currencyCode) }
                    }
                } footer: {
                    Text("Ledgea shows every amount in this currency. Past transactions keep the code they were saved with.")
                }

                Section {
                    NavigationLink {
                        StatementImportView()
                    } label: {
                        Label("Import statement", systemImage: "tablecells")
                    }
                    NavigationLink {
                        StatementExportView()
                    } label: {
                        Label("Export statement", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Read a CSV export from your bank, tick what to keep, and save it as transactions. Or export your own transactions back out to CSV.")
                }

                Section {
                    if status.role == nil {
                        Button("Invite someone", systemImage: "person.badge.plus") { presentShare() }
                    } else {
                        ForEach(members.sorted { $0.name < $1.name }, id: \.persistentModelID) { member in
                            LabeledContent(member.name) {
                                if member.isMe { Text("You").foregroundStyle(Palette.inkMuted) }
                            }
                        }
                        if status.role == .owner {
                            Button("Manage sharing", systemImage: "person.2") { presentShare() }
                        }
                        Button("Stop sharing", systemImage: "person.badge.minus", role: .destructive) { isLeaving = true }
                    }
                } header: {
                    Text("Family")
                } footer: {
                    Text(familyFooter)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $isPaywall) { PaywallView() }
            .sheet(item: $activeShare) { box in
                CloudSharingSheet(share: box.share, container: .default())
            }
            .alert("Could not create share", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
                Button("OK") { shareError = nil }
            } message: { Text(shareError ?? "") }
            .confirmationDialog("Stop sharing this budget?", isPresented: $isLeaving, titleVisibility: .visible) {
                Button("Stop sharing", role: .destructive) { FamilySyncEngine.shared.stopSharing() }
            } message: {
                Text("Shared transactions stay on this device. They just stop syncing.")
            }
        }
        .tint(Palette.accent)
    }

    private var familyFooter: String {
        if let error = status.lastError { return error }
        switch status.role {
        case nil:
            return String(localized: "Share the Shared side of Ledgea with one other person. Personal transactions never leave this device.")
        case .owner:
            return syncedLine ?? String(localized: "You started this family budget.")
        case .participant:
            return syncedLine ?? String(localized: "You joined this family budget.")
        }
    }

    private var syncedLine: String? {
        status.lastSyncedAt.map { String(localized: "Last synced \($0.formatted(date: .omitted, time: .shortened)).") }
    }

    private func presentShare() {
        Task {
            do { activeShare = ShareBox(share: try await FamilySyncEngine.shared.makeOrFetchShare()) }
            catch { shareError = error.localizedDescription }
        }
    }
}

private struct ShareBox: Identifiable {
    let id = UUID()
    let share: CKShare
}

/// Flag, code and symbol — the three things that tell one currency from another
/// at a glance. The flag is decorative; the code carries the meaning.
struct CurrencyLabel: View {
    let code: String

    var body: some View {
        let symbol = Money.displaySymbol(for: code)
        HStack(spacing: 8) {
            Text(Money.flag(for: code)).accessibilityHidden(true)
            Text(code).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
            // A few currencies (CHF) have no symbol but their code — "CHF CHF"
            // reads like a bug, so the repeat is dropped.
            if symbol != code {
                Text(symbol).font(.subheadline).foregroundStyle(Palette.inkMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(code)
    }
}

struct CurrencyPicker: View {
    @Binding var code: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var codes: [String] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return Money.pickerCodes }
        return Money.pickerCodes.filter { $0.localizedCaseInsensitiveContains(wanted) }
    }

    var body: some View {
        List(codes, id: \.self) { item in
            Button {
                code = item
                dismiss()
            } label: {
                HStack {
                    CurrencyLabel(code: item)
                    Spacer()
                    if item == code {
                        Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                    }
                }
            }
        }
        // Hosted in the navigation bar on purpose: the iOS 26 floating search
        // accessory has no bar to attach to inside a sheet and traps there.
        .searchable(text: $query, placement: .navigationBarDrawer, prompt: "Currency code")
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
    }
}
