import GoogleMobileAds
import UserMessagingPlatform
import UIKit
import Observation

/// UMP consent (only shows a form in EEA/UK), then starts the SDK. Ads load only
/// after `canRequestAds`. No ATT: requests are non-personalized.
@MainActor @Observable
final class AdsConsent {
    private(set) var canRequestAds = false
    /// True when the user may reopen the consent form (EEA/UK): Google requires an entry point for it.
    private(set) var privacyOptionsRequired = false
    private var banners = BannerHeights()
    @ObservationIgnored private var started = false

    /// Height of the banner currently on screen (0 when none), so the floating buttons can clear it.
    var bannerHeight: CGFloat { banners.height }

    func reportBanner(_ id: UUID, height: CGFloat) { banners.report(id, height: height) }
    func removeBanner(_ id: UUID) { banners.remove(id) }

    func start() async {
        guard !started else { return }
        started = true
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
            try await ConsentForm.loadAndPresentIfRequired(from: Self.rootViewController)
        } catch {
            // Consent could not be resolved now; a previously stored answer still counts via canRequestAds.
        }
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        guard ConsentInformation.shared.canRequestAds else { return }
        _ = await MobileAds.shared.start()
        canRequestAds = true
    }

    func presentPrivacyOptions() async {
        try? await ConsentForm.presentPrivacyOptionsForm(from: Self.rootViewController)
    }

    static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
    }
}
