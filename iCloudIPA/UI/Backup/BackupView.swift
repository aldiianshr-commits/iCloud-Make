import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct BackupView: View {
    @EnvironmentObject var backup: BackupEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var accounts: AccountManager
    @EnvironmentObject var env: AppEnvironment
    @Query(sort: \BackupRun.startedAt, order: .reverse) private var runs: [BackupRun]
    @Query(sort: \BackupFolderSource.addedAt) private var folders: [BackupFolderSource]
    @Query private var jobs: [BackgroundJobRecord]
    @State private var pickingFolder = false
    @State private var error: String?
    @State private var verifying = false
    @State private var report: BackupEngine.VerificationReport?
    @State private var confirmFull = false

    var body: some View {
        List {
            statusSection
            Section {
                ForEach(BackupCategory.allCases) { cat in
                    Toggle(isOn: Binding(get: { settings.backupCategories.contains(cat) },
                                         set: { on in if on { settings.backupCategories.insert(cat) } else { settings.backupCategories.remove(cat) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(cat.title, systemImage: cat.symbol)
                            Text(cat.scopeNote).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(L("What to back up"))
            } footer: {
                Text(L("iOS only lets apps read the data listed here. A full iPhone system backup and other apps' private data are not accessible to any App Store app."))
            }

            Section {
                ForEach(folders) { f in Label(f.name, systemImage: "folder") }
                    .onDelete { idx in for i in idx { env.store.context.delete(folders[i]) }; env.store.save() }
                Button { pickingFolder = true } label: { Label(L("Add folder…"), systemImage: "folder.badge.plus") }
            } header: {
                Text(L("Folders (Documents, Audio, Files)"))
            } footer: {
                Text(L("Pick folders in the Files app (On My iPhone, iCloud Drive, external drives…). iCloud IPA keeps access to them for future backups."))
            }

            Section(L("Schedule")) {
                Picker(L("Automatic backup"), selection: $settings.backupSchedule) {
                    ForEach(BackupSchedule.allCases) { Text($0.title).tag($0) }
                }
                if settings.backupSchedule != .off {
                    Picker(L("Preferred time"), selection: $settings.backupHour) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }
                    Toggle(L("Wi-Fi only"), isOn: $settings.backupWiFiOnly)
                    Toggle(L("Only while charging"), isOn: $settings.backupRequiresCharging)
                    backgroundStatus
                }
            }
            .onChange(of: settings.backupSchedule) { _, _ in BackupScheduler.shared.scheduleNext(settings: settings) }
            .onChange(of: settings.backupHour) { _, _ in BackupScheduler.shared.scheduleNext(settings: settings) }
            .onChange(of: settings.backupRequiresCharging) { _, _ in BackupScheduler.shared.scheduleNext(settings: settings) }

            Section {
                Picker(L("Destination"), selection: $settings.backupAccountID) {
                    Text(L("Automatic (primary, then most free space)")).tag(UUID?.none)
                    ForEach(accounts.accounts) { a in Text("\(a.provider.title) · \(a.email.isEmpty ? a.displayName : a.email)").tag(UUID?.some(a.id)) }
                }
                Toggle(L("Encrypt backups (AES-256)"), isOn: $settings.encryptBackups)
                Picker(L("Deleted on device"), selection: $settings.deletedItemPolicy) {
                    ForEach(DeletedItemPolicy.allCases) { Text($0.title).tag($0) }
                }
            } header: { Text(L("Options")) } footer: {
                Text(L("Backups never delete cloud copies when something is deleted on this device; such items are marked and stay restorable."))
            }

            Section(L("Restore & verify")) {
                NavigationLink { RestoreView() } label: { Label(L("Restore…"), systemImage: "clock.arrow.circlepath") }
                Button {
                    Task {
                        verifying = true
                        defer { verifying = false }
                        do { report = try await backup.verify() } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    HStack { Label(L("Verify backup"), systemImage: "checkmark.shield"); if verifying { Spacer(); ProgressView() } }
                }
                .disabled(verifying || backup.isRunning)
                if let report {
                    Text(LF("%d checked · %d OK · %d missing · %d mismatched", report.checked, report.ok, report.missing.count, report.mismatched.count))
                        .font(.caption).foregroundStyle(report.missing.isEmpty && report.mismatched.isEmpty ? .green : .orange)
                }
            }

            Section(L("History")) {
                if runs.isEmpty { Text(L("No backups yet")).foregroundStyle(.secondary) }
                ForEach(runs.prefix(50)) { run in
                    NavigationLink { BackupRunDetailView(run: run) } label: { BackupRunRow(run: run) }
                }
            }
        }
        .navigationTitle(L("Backup"))
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): addFolder(url)
            case .failure(let e): error = e.localizedDescription
            }
        }
        .confirmationDialog(L("Run a full backup?"), isPresented: $confirmFull) {
            Button(L("Full backup")) { backup.start(kind: .full, trigger: .manual) }
        } message: {
            Text(L("Every selected item is uploaded again, even if unchanged. Older copies go to the provider's trash."))
        }
        .errorAlert($error)
    }

    private var statusSection: some View {
        Section {
            if backup.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    if let c = backup.progress.category { Label(c.title, systemImage: c.symbol).font(.headline) }
                    Text(backup.progress.phase).font(.subheadline)
                    ProgressView(value: backup.progress.fraction)
                    Text(backup.progress.itemName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(LF("%d of %d · %@", backup.progress.processed, backup.progress.total, Fmt.bytes(backup.progress.bytes))).font(.caption)
                    Button(L("Stop"), role: .destructive) { backup.cancel() }
                }
            } else {
                LabeledContent(L("Last backup"), value: settings.lastBackupAt.map { Fmt.date($0) } ?? L("Never"))
                if let m = backup.lastMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button { backup.start(kind: .incremental, trigger: .manual) } label: {
                        Label(L("Backup Now"), systemImage: "arrow.clockwise.icloud").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { confirmFull = true } label: { Text(L("Full")).frame(maxWidth: 80) }
                        .buttonStyle(.bordered)
                }
                .disabled(accounts.accounts.isEmpty)
                if accounts.accounts.isEmpty { Text(L("Connect a cloud account first.")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var backgroundStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let job = jobs.first(where: { $0.identifier == AppConfig.backupProcessingTaskID }) {
                if let d = job.earliestBeginDate { Text(LF("Next background window: not before %@", Fmt.date(d))).font(.caption) }
                if let r = job.lastResult { Text(LF("Last background run: %@", r)).font(.caption).foregroundStyle(.secondary) }
            }
            Text(L("iOS decides when background backups actually run (battery, network, usage). If one is overdue, it starts the next time you open the app."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func addFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            env.store.context.insert(BackupFolderSource(name: url.lastPathComponent, bookmark: bookmark))
            env.store.save()
        } catch { self.error = error.localizedDescription }
    }
}

struct BackupRunRow: View {
    let run: BackupRun

    var color: Color {
        switch run.status {
        case .completed: return .green
        case .completedWithErrors: return .orange
        case .failed: return .red
        case .running: return .accentColor
        case .cancelled: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(Fmt.date(run.startedAt)).font(.subheadline)
                Spacer()
                Text(run.kind == .full ? L("Full") : L("Incremental")).font(.caption).foregroundStyle(.secondary)
            }
            Text(LF("%d uploaded, %d unchanged, %d failed", run.itemsUploaded, run.itemsSkipped, run.itemsFailed)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BackupRunDetailView: View {
    let run: BackupRun
    @EnvironmentObject var accounts: AccountManager

    var body: some View {
        List {
            Section {
                LabeledContent(L("Status"), value: run.status.title)
                LabeledContent(L("Type"), value: run.kind == .full ? L("Full") : L("Incremental"))
                LabeledContent(L("Trigger"), value: run.trigger == .manual ? L("Manual") : L("Scheduled"))
                LabeledContent(L("Started"), value: Fmt.date(run.startedAt))
                LabeledContent(L("Finished"), value: Fmt.date(run.finishedAt))
                if let a = accounts.store.account(run.accountID) { LabeledContent(L("Account"), value: a.email.isEmpty ? a.displayName : a.email) }
                LabeledContent(L("Categories"), value: run.categories.map(\.title).joined(separator: ", "))
            }
            Section(L("Results")) {
                LabeledContent(L("Items found"), value: "\(run.itemsTotal)")
                LabeledContent(L("Uploaded"), value: "\(run.itemsUploaded)")
                LabeledContent(L("Verified uploads"), value: "\(run.verifiedCount)")
                LabeledContent(L("Unchanged (skipped)"), value: "\(run.itemsSkipped)")
                LabeledContent(L("Failed"), value: "\(run.itemsFailed)")
                LabeledContent(L("Deleted on device (kept in cloud)"), value: "\(run.itemsDeletedDetected)")
                LabeledContent(L("Data uploaded"), value: Fmt.bytes(run.bytesUploaded))
                LabeledContent(L("Manifest"), value: run.manifestRemoteID == nil ? "—" : L("Saved"))
            }
            if let m = run.message {
                Section(L("Messages")) { Text(m).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
        .navigationTitle(L("Backup details"))
    }
}
