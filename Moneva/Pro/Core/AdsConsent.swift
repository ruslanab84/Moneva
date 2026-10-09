import GoogleMobileAds
import UserMessagingPlatform
import UIKit
import Observation

/// UMP consent (only shows a form in EEA/UK), then starts the SDK. Ads load only
/// after `canRequestAds`. No ATT: requests are non-personalized.
@MainActor @Observable
final class AdsConsent {
    private(set) var canRequestAds = false
    /// Height of the banner currently on screen (0 when none), so the floating buttons can clear it.
    var bannerHeight: CGFloat = 0
    @ObservationIgnored private var started = false

    func start() async {
        guard !started else { return }
        started = true
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters())
            try await ConsentForm.loadAndPresentIfRequired(from: Self.rootViewController)
        } catch {
            // Consent could not be resolved now; a previously stored answer still counts via canRequestAds.
        }
        guard ConsentInformation.shared.canRequestAds else { return }
        _ = await MobileAds.shared.start()
        canRequestAds = true
    }

    static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
    }
}
