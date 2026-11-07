import Foundation
import SwiftUI

/// Composition root: creates every service once and hands them to the UI.
@MainActor
final class AppEnvironment: ObservableObject {
    let store: DataStore
    let settings: AppSettings
    let lock: AppLockManager
    let accounts: AccountManager
    let transfers: TransferManager
    let backup: BackupEngine
    let restore: RestoreEngine
    let indexer: StorageIndexer
    let sync: SyncEngine

    init(inMemory: Bool = false, defaults: UserDefaults = .standard) {
        store = DataStore(inMemory: inMemory)
        settings = AppSettings(defaults: defaults)
        lock = AppLockManager(settings: settings)
        accounts = AccountManager(store: store)
        transfers = TransferManager(store: store, accounts: accounts, settings: settings)
        backup = BackupEngine(store: store, accounts: accounts, settings: settings)
        restore = RestoreEngine(store: store, accounts: accounts)
        indexer = StorageIndexer(store: store, accounts: accounts)
        sync = SyncEngine(store: store, accounts: accounts)
        BackupScheduler.shared.engine = backup
        BackupScheduler.shared.store = store
    }

    func onLaunch() {
        _ = NetworkMonitor.shared
        transfers.recoverAfterLaunch()
        for run in backup.runs(limit: 5) where run.status == .running {
            // The app was terminated mid-backup: close the run so history stays consistent.
            run.status = .cancelled
            run.finishedAt = run.finishedAt ?? Date()
            run.message = L("Interrupted (app was closed). The next run continues incrementally.")
        }
        store.save()
        BackupScheduler.shared.scheduleNext(settings: settings)
        Task { await accounts.refreshAll() }
    }

    func onBecameActive() {
        BackupScheduler.shared.runIfOverdue()
    }
}
