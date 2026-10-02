import SwiftUI

struct RootView: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @State private var isAdding = false
    @State private var isSpeaking = false
    @State private var isScanning = false

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") { NavigationStack { HomeView() } }
            Tab("Transactions", systemImage: "list.bullet") { TransactionsView() }
            Tab("Budget", systemImage: "chart.pie") { BudgetView() }
            Tab("Goals", systemImage: "flag") { GoalsView() }
            Tab("Subs", systemImage: "arrow.triangle.2.circlepath") { SubscriptionsView() }
        }
        .tint(Palette.accent)
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
                if OnDeviceAI.isSupported {
                    Button { isScanning = true } label: {
                        Image(systemName: "doc.viewfinder")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 46, height: 46)
                            .background(Palette.card, in: .circle)
                            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
                    }
                    .accessibilityLabel("Scan a receipt")

                    Button { isSpeaking = true } label: {
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
            .padding(.bottom, 96)
        }
        .sheet(isPresented: $isAdding) { AddTransactionView() }
        .sheet(isPresented: $isSpeaking) { VoiceCaptureView() }
        .sheet(isPresented: $isScanning) { ReceiptScanView() }
        .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
    }
}
