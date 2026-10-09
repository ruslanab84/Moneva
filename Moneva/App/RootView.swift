import SwiftUI

struct RootView: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @State private var isAdding = false
    @State private var isSpeaking = false
    @State private var isScanning = false
    @State private var isPaywall = false
    @State private var tab: AppTab = .home
    @State private var ads = AdsConsent()
    @Environment(ProStore.self) private var pro

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) { NavigationStack { HomeView() } }
            Tab("Transactions", systemImage: "list.bullet", value: AppTab.transactions) { TransactionsView() }
            Tab("Budget", systemImage: "chart.pie", value: AppTab.budget) { BudgetView() }
            Tab("Goals", systemImage: "flag", value: AppTab.goals) { GoalsView() }
            Tab("Subs", systemImage: "arrow.triangle.2.circlepath", value: AppTab.subs) { SubscriptionsView() }
        }
        .tint(Palette.accent)
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
                if OnDeviceAI.isSupported {
                    Button { openAI { isScanning = true } } label: {
                        Image(systemName: "doc.viewfinder")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 46, height: 46)
                            .background(Palette.card, in: .circle)
                            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
                    }
                    .accessibilityLabel("Scan a receipt")

                    Button { openAI { isSpeaking = true } } label: {
                        Image(systemName: "mic.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 46, height: 46)
                            .background(Palette.card, in: .circle)
                            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
                    }
                    .accessibilityLabel("Add by text or voice")
                }

                Button { isAdding = true } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Palette.card)
                        .frame(width: 60, height: 60)
                        .background(Palette.accent, in: .rect(cornerRadius: 21))
                        .shadow(color: Palette.accent.opacity(0.45), radius: 16, x: 0, y: 10)
                }
                .accessibilityLabel("Add transaction")
            }
            .padding(.trailing, 22)
            // The banner sits above the tab bar on Home/Transactions; keep the buttons clear of it.
            .padding(.bottom, 96 + (ProLimits.showsBanner(tab: tab, isPro: pro.isPro) ? ads.bannerHeight : 0))
        }
        .environment(ads)
        .task(id: pro.isPro) { if !pro.isPro { await ads.start() } }
        .sheet(isPresented: $isPaywall) { PaywallView() }
        .sheet(isPresented: $isAdding) { AddTransactionView() }
        .sheet(isPresented: $isSpeaking) { VoiceCaptureView() }
        .sheet(isPresented: $isScanning) { ReceiptScanView() }
        .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
    }

    private func openAI(_ open: () -> Void) {
        if ProLimits.canUseAI(usedThisMonth: AIUsage.count(), isPro: pro.isPro) { open() } else { isPaywall = true }
    }
}
