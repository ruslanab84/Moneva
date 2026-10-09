import SwiftUI

/// Locks Pro-only UI for Free users: dimmed, a lock badge, and any tap opens the paywall.
/// Pro users get the content untouched.
struct ProGate: ViewModifier {
    @Environment(ProStore.self) private var pro
    @State private var isPaywall = false

    func body(content: Content) -> some View {
        if pro.isPro {
            content
        } else {
            content
                .allowsHitTesting(false)
                .opacity(0.55)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Palette.accent)
                        .padding(6)
                }
                .overlay { Color.clear.contentShape(Rectangle()).onTapGesture { isPaywall = true } }
                .accessibilityHint("Requires Pro")
                .sheet(isPresented: $isPaywall) { PaywallView() }
        }
    }
}

extension View {
    func proGated() -> some View { modifier(ProGate()) }
}
