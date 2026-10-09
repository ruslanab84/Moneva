import SwiftUI
import GoogleMobileAds

/// Anchored adaptive banner. Takes only a width: no app data ever reaches the SDK.
/// The container is zero-height until an ad arrives (and again if loading fails), but the
/// banner view itself always gets its full adaptive size, or the SDK rejects the request.
struct AdBanner: View {
    @Environment(AdsConsent.self) private var ads
    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 0
    @State private var id = UUID()

    var body: some View {
        Color.clear
            .frame(height: height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .top) {
                if width > 0 {
                    let size = currentOrientationAnchoredAdaptiveBanner(width: width).size
                    BannerRepresentable(width: width, height: $height)
                        .frame(width: size.width, height: size.height)
                }
            }
            .clipped()
            .accessibilityLabel("Advertisement")
            .onChange(of: height) { _, new in ads.reportBanner(id, height: new) }
            .onAppear { ads.reportBanner(id, height: height) }
            .onDisappear { ads.removeBanner(id) }
    }
}

/// Puts the banner above the tab bar for Free users once consent allows ads.
/// Apply it only to the screens that may show ads (Home, Transactions).
private struct AdSlot: ViewModifier {
    @Environment(AdsConsent.self) private var ads
    @Environment(ProStore.self) private var pro

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if ads.canRequestAds && !pro.isPro { AdBanner() }
        }
    }
}

extension View {
    func adSupported() -> some View { modifier(AdSlot()) }
}

private struct BannerRepresentable: UIViewRepresentable {
    let width: CGFloat
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> BannerView {
        let banner = BannerView(adSize: currentOrientationAnchoredAdaptiveBanner(width: width))
        banner.adUnitID = Bundle.main.object(forInfoDictionaryKey: "AdBannerUnitID") as? String
        banner.rootViewController = AdsConsent.rootViewController
        banner.delegate = context.coordinator
        let request = Request()
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]   // non-personalized, no ATT
        request.register(extras)
        banner.load(request)
        return banner
    }

    func updateUIView(_ banner: BannerView, context: Context) {}

    final class Coordinator: NSObject, BannerViewDelegate {
        @Binding var height: CGFloat
        init(height: Binding<CGFloat>) { _height = height }

        func bannerViewDidReceiveAd(_ bannerView: BannerView) { height = bannerView.adSize.size.height }
        func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) { height = 0 }
    }
}
