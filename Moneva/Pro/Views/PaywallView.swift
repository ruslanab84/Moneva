import SwiftUI
import StoreKit

enum PaywallLinks {
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// Owner supplies the real policy URL (App Store requires one). Replace before shipping.
    static let privacy = URL(string: "OWNER_PRIVACY_POLICY_URL")!
}

struct PaywallView: View {
    @Environment(ProStore.self) private var pro
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("No ads", systemImage: "nosign")
                    Label("Family sharing", systemImage: "person.2")
                    Label("Ask, search and explain your spending", systemImage: "sparkles")
                    Label("Forecast, insights and daily limit", systemImage: "chart.line.uptrend.xyaxis")
                    Label("Unlimited subscriptions, goals and accounts", systemImage: "infinity")
                    Label("Unlimited receipt scans and voice entries", systemImage: "doc.viewfinder")
                    Label("Statement import, budget carry-over, subcategories", systemImage: "tablecells")
                } header: {
                    Text("Ledgea Pro")
                }

                Section {
                    if pro.products.isEmpty {
                        Text("Prices are not available right now. Check your connection and try again.")
                            .foregroundStyle(Palette.inkMuted)
                    }
                    ForEach(pro.products) { product in
                        Button {
                            Task { await buy(product) }
                        } label: {
                            LabeledContent(product.displayName) { Text(product.displayPrice).fontWeight(.semibold) }
                        }
                        .disabled(busy)
                    }
                    Button("Restore purchases") { Task { await restore() } }.disabled(busy)
                } footer: {
                    Text("Subscriptions renew automatically unless cancelled at least 24 hours before the period ends. Manage or cancel in Settings ▸ Apple ID ▸ Subscriptions. Lifetime is a one-time purchase.")
                }

                if let message {
                    Section { Text(message).foregroundStyle(Palette.over) }
                }

                Section {
                    Link("Terms of Use", destination: PaywallLinks.terms)
                    Link("Privacy Policy", destination: PaywallLinks.privacy)
                }
            }
            .navigationTitle("Upgrade to Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: pro.isPro) { _, isPro in if isPro { dismiss() } }
        }
        .tint(Palette.accent)
    }

    private func buy(_ product: Product) async {
        busy = true
        defer { busy = false }
        message = await pro.purchase(product)
    }

    private func restore() async {
        busy = true
        defer { busy = false }
        message = await pro.restore()
    }
}
