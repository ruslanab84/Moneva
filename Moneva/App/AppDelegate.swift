import UIKit
import CloudKit
import UserNotifications

/// SwiftUI has no hook for CKShare acceptance — it arrives only through a
/// UIKit callback (not a URL, so `.onOpenURL` can't catch it). This app is
/// scene-based, so UIKit delivers it to the scene delegate, never to the app
/// delegate's deprecated `userDidAcceptCloudKitShareWith`; the app delegate's
/// only job is to install that scene delegate.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Without this iOS drops a notification fired while Ledgea is open — exactly
    /// when a budget alert lands, right after the expense that crossed the line.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch from the invite link: the metadata rides in on the
    /// connection options instead of the callback below.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            FamilySyncEngine.shared.accept(metadata)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        FamilySyncEngine.shared.accept(cloudKitShareMetadata)
    }
}
