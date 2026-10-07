import SwiftUI
import CloudKit
import UIKit

/// Apple's system sharing UI, wrapped once. The invite row in Settings is its
/// only caller.
struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func itemTitle(for csc: UICloudSharingController) -> String? { "Ledgea family budget" }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { @MainActor in
                FamilySyncEngine.shared.acceptedShare(role: .owner, ownerName: CKCurrentUserDefaultName)
            }
        }

        /// The owner ended the share from Apple's own UI. Local records stay;
        /// they just stop travelling.
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            Task { @MainActor in FamilySyncEngine.shared.stopSharing() }
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            Task { @MainActor in FamilySyncStatus.shared.lastError = error.localizedDescription }
        }
    }
}
