import UIKit
import CloudKit

/// SwiftUI has no hook for CKShare acceptance — it arrives only through this
/// UIKit callback (not a URL, so `.onOpenURL` can't catch it), so this is the
/// one AppDelegate this app needs.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        let container = CKContainer(identifier: metadata.containerIdentifier)
        // The zone stays owned by whoever sent the invite; this device reaches
        // it through the shared database under that owner's name.
        let ownerName = metadata.share.recordID.zoneID.ownerName
        Task { @MainActor in
            do {
                try await container.accept(metadata)
                FamilySyncEngine.shared.acceptedShare(role: .participant, ownerName: ownerName)
            } catch {
                FamilySyncStatus.shared.lastError = error.localizedDescription
            }
        }
    }
}
