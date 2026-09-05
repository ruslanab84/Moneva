import SwiftUI

struct SettingsView: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Moneva shows every amount in this currency. Past transactions keep the code they were saved with.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Palette.accent)
    }
}

/// Flag, code and symbol — the three things that tell one currency from another
/// at a glance. The flag is decorative; the code carries the meaning.
struct CurrencyLabel: View {
    let code: String

    var body: some View {
        let symbol = Money.symbol(for: code)
        HStack(spacing: 8) {
            Text(Money.flag(for: code)).accessibilityHidden(true)
            Text(code).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
            // Some locales print the code itself as the symbol — "ALL ALL"
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
