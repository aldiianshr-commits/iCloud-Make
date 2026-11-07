import Foundation
import BackgroundTasks
import UIKit
import Network

/// Schedules automatic backups with BGTaskScheduler.
///
/// iOS decides when background tasks actually run (battery, usage patterns, network); a scheduled
/// time is the *earliest* start, not a guarantee. To compensate, an overdue backup also starts
/// automatically the next time the app is opened.
@MainActor
final class BackupScheduler {
    static let shared = BackupScheduler()
    weak var engine: BackupEngine?
    weak var store: DataStore?
    private var registered = false

    /// Must be called before the app finishes launching.
    func register() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConfig.backupProcessingTaskID, using: nil) { task in
            Task { @MainActor in self.handle(task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConfig.backupRefreshTaskID, using: nil) { task in
            Task { @MainActor in self.handleRefresh(task) }
        }
    }

    /// Next due date given the last successful backup, schedule and preferred hour.
    nonisolated static func nextDueDate(last: Date?, schedule: BackupSchedule, hour: Int, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let interval = schedule.interval else { return nil }
        guard let last else { return now }
        let base = last.addingTimeInterval(interval)
        // Align to the preferred hour on/after the base date.
        var comps = calendar.dateComponents([.year, .month, .day], from: base)
        comps.hour = hour
        comps.minute = 0
        var aligned = calendar.date(from: comps) ?? base
        if aligned < base.addingTimeInterval(-12 * 3600) { aligned = calendar.date(byAdding: .day, value: 1, to: aligned) ?? aligned }
        return max(aligned, now)
    }

    nonisolated static func isOverdue(last: Date?, schedule: BackupSchedule, hour: Int, now: Date = Date()) -> Bool {
        guard let due = nextDueDate(last: last, schedule: schedule, hour: hour, now: now) else { return false }
        return due <= now
    }

    func scheduleNext(settings: AppSettings) {
        guard !AppConfig.isRunningTests else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppConfig.backupProcessingTaskID)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppConfig.backupRefreshTaskID)
        guard let due = Self.nextDueDate(last: settings.lastBackupAt, schedule: settings.backupSchedule, hour: settings.backupHour) else { return }
        let req = BGProcessingTaskRequest(identifier: AppConfig.backupProcessingTaskID)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = settings.backupRequiresCharging
        req.earliestBeginDate = due
        let refresh = BGAppRefreshTaskRequest(identifier: AppConfig.backupRefreshTaskID)
        refresh.earliestBeginDate = due
        do {
            try BGTaskScheduler.shared.submit(req)
            try? BGTaskScheduler.shared.submit(refresh)
            if let store {
                let rec = store.jobRecord(AppConfig.backupProcessingTaskID)
                rec.lastScheduledAt = Date()
                rec.earliestBeginDate = due
                store.save()
            }
        } catch {
            Log.backup.error("BGTask submit failed: \(error.localizedDescription, privacy: .public)")
            if let store {
                let rec = store.jobRecord(AppConfig.backupProcessingTaskID)
                rec.lastResult = LF("Could not schedule: %@", error.localizedDescription)
                store.save()
            }
        }
    }

    private func handle(_ task: BGTask) {
        guard let engine, let store else { task.setTaskCompleted(success: false); return }
        let rec = store.jobRecord(task.identifier)
        rec.lastStartedAt = Date()
        rec.lastExpired = false
        store.save()
        if engine.settings.backupWiFiOnly && !NetworkMonitor.shared.isOnWiFi {
            rec.lastResult = L("Skipped: not on Wi-Fi")
            rec.lastFinishedAt = Date()
            store.save()
            scheduleNext(settings: engine.settings)
            task.setTaskCompleted(success: true)
            return
        }
        let work = Task { @MainActor in
            let run = await engine.run(kind: .incremental, trigger: .scheduled)
            rec.lastFinishedAt = Date()
            rec.lastResult = run?.status.title ?? L("not started")
            store.save()
            task.setTaskCompleted(success: run?.status == .completed)
        }
        task.expirationHandler = {
            Task { @MainActor in
                rec.lastExpired = true
                rec.lastResult = L("Stopped by iOS (time limit); will continue next time")
                store.save()
                engine.cancel()
                work.cancel()
            }
        }
    }

    private func handleRefresh(_ task: BGTask) {
        guard let engine else { task.setTaskCompleted(success: false); return }
        // App refresh windows are short (~30 s): only start if overdue and very small work is expected;
        // otherwise just make sure the processing task is queued.
        scheduleNext(settings: engine.settings)
        task.setTaskCompleted(success: true)
    }

    /// Called when the app becomes active: runs an overdue scheduled backup in the foreground.
    func runIfOverdue() {
        guard let engine, !engine.isRunning, !AppConfig.isRunningTests, !AppConfig.isScreenshotMode else { return }
        let s = engine.settings
        guard Self.isOverdue(last: s.lastBackupAt, schedule: s.backupSchedule, hour: s.backupHour) else { return }
        if s.backupWiFiOnly && !NetworkMonitor.shared.isOnWiFi { return }
        engine.start(kind: .incremental, trigger: .scheduled)
    }
}


/// Tracks whether the current path is Wi-Fi (for "Wi-Fi only" backups).
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private(set) var isOnWiFi = false
    private(set) var isConnected = false
    private(set) var isExpensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isConnected = path.status == .satisfied
            self?.isOnWiFi = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            self?.isExpensive = path.isExpensive
        }
        monitor.start(queue: DispatchQueue(label: "network.monitor"))
    }
}
