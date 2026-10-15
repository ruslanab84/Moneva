## Family sharing (CloudKit)

[FamilySync.swift](FamilySync.swift) syncs `Transaction` records via `CKSyncEngine`, with `AppDelegate.swift` handling share acceptance and [CloudSharingSheet.swift](CloudSharingSheet.swift) wrapping `UICloudSharingController` for invites. This is layered on top of, not a replacement for, local SwiftData — `Scope: .shared` remains a local partition, not proof of an accepted share. Treat any CloudKit-touching change as sync-conflict-sensitive: `FamilySyncEngine.catchUp()` runs at launch and is covered by `familySyncSelfCheck()`.
