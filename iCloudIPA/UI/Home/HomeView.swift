import SwiftUI
import SwiftData

struct HomeView: View {
    @EnvironmentObject var accounts: AccountManager
    @EnvironmentObject var backup: BackupEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var transfers: TransferManager
    @EnvironmentObject var router: Router
    @Query(sort: \CloudAccount.sortOrder) private var accountList: [CloudAccount]
    @Query(sort: \ActivityItem.date, order: .reverse) private var activity: [ActivityItem]
    @Query(sort: \TransferRecord.createdAt, order: .reverse) private var transferList: [TransferRecord]
    @State private var showUploader = false
    @State private var error: String?

    private var recentFiles: [TransferRecord] {
        Array(transferList.filter { $0.status == .completed && ($0.kind == .upload || $0.kind == .download) }.prefix(6))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                storageCard
                quickActions
                backupCard
                if transfers.activeCount > 0 { activeTransfersCard }
                recentFilesCard
                activityCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("Home"))
        .refreshable { await accounts.refreshAll() }
        .sheet(isPresented: $showUploader) { UploadSheet() }
        .sheet(isPresented: $router.showRestore) { NavigationStack { RestoreView() } }
        .errorAlert($error)
    }

    // MARK: Storage

    private var storageCard: some View {
        Card(title: L("Storage"), systemImage: "internaldrive") {
            if accountList.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("No cloud account connected yet.")).foregroundStyle(.secondary)
                    Button(L("Connect an account")) { router.tab = .accounts }.buttonStyle(.borderedProminent)
                }
            } else {
                let used = accountList.compactMap(\.quotaUsed).reduce(0, +)
                let total = accountList.compactMap(\.quotaTotal).reduce(0, +)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.bytes(used)).font(.title2.bold())
                        if total > 0 { Text(LF("of %@", Fmt.bytes(total))).foregroundStyle(.secondary) }
                    }
                    if total > 0 { QuotaBar(fraction: Double(used) / Double(total), height: 10) }
                    Text(LF("Across %d separate accounts — each account keeps its own limit.", accountList.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                ForEach(accountList) { acc in
                    HStack(spacing: 10) {
                        ProviderBadge(kind: acc.provider, size: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(acc.email.isEmpty ? acc.displayName : acc.email).font(.subheadline).lineLimit(1)
                                Spacer()
                                StatusDot(status: acc.status)
                            }
                            QuotaBar(fraction: acc.usageFraction, height: 5)
                            Text(acc.quotaFree.map { LF("%@ free", Fmt.bytes($0)) } ?? (acc.quotaUsed.map { LF("%@ used", Fmt.bytes($0)) } ?? L("Not refreshed yet")))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink {
                    StorageDashboardView()
                } label: {
                    Label(L("Storage analysis"), systemImage: "chart.pie").font(.subheadline.weight(.medium))
                }
            }
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 12) {
            actionButton(L("Backup Now"), "arrow.clockwise.icloud.fill", disabled: backup.isRunning || accountList.isEmpty) {
                backup.start(kind: .incremental, trigger: .manual)
            }
            actionButton(L("Upload"), "icloud.and.arrow.up.fill", disabled: accountList.isEmpty) { showUploader = true }
            actionButton(L("Restore"), "clock.arrow.circlepath", disabled: accountList.isEmpty) { router.showRestore = true }
        }
    }

    private func actionButton(_ title: String, _ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
        .disabled(disabled)
    }

    // MARK: Backup

    private var backupCard: some View {
        Card(title: L("Backup status"), systemImage: "checkmark.icloud") {
            if backup.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    Text(backup.progress.phase).font(.subheadline)
                    ProgressView(value: backup.progress.fraction)
                    Text(LF("%d of %d · %@", backup.progress.processed, backup.progress.total, Fmt.bytes(backup.progress.bytes)))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Cancel"), role: .destructive) { backup.cancel() }.font(.footnote)
                }
            } else {
                LabeledContent(L("Last backup"), value: settings.lastBackupAt.map { Fmt.relative($0) } ?? L("Never"))
                LabeledContent(L("Schedule"), value: settings.backupSchedule.title)
                if let due = BackupScheduler.nextDueDate(last: settings.lastBackupAt, schedule: settings.backupSchedule, hour: settings.backupHour) {
                    LabeledContent(L("Next (earliest)"), value: Fmt.date(due))
                }
                if let m = backup.lastMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var activeTransfersCard: some View {
        Card(title: LF("%d transfers in progress", transfers.activeCount), systemImage: "arrow.up.arrow.down.circle") {
            NavigationLink(L("Show transfers")) { TransfersView() }
        }
    }

    // MARK: Recent

    private var recentFilesCard: some View {
        Card(title: L("Recent files"), systemImage: "clock") {
            if recentFiles.isEmpty {
                Text(L("Files you upload or download appear here.")).font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(recentFiles) { r in
                    HStack {
                        Image(systemName: r.kind == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(r.kind == .upload ? Color.accentColor : .green)
                        VStack(alignment: .leading) {
                            Text(r.name).lineLimit(1)
                            Text("\(Fmt.bytes(r.totalBytes)) · \(Fmt.relative(r.finishedAt))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if r.verified { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).accessibilityLabel(L("Verified")) }
                    }
                }
            }
        }
    }

    private var activityCard: some View {
        Card(title: L("Recent activity"), systemImage: "list.bullet.rectangle") {
            if activity.isEmpty {
                Text(L("No activity yet.")).font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(activity.prefix(8)) { a in ActivityRow(item: a) }
                NavigationLink(L("All activity")) { ActivityListView() }.font(.subheadline)
            }
        }
    }
}

struct ActivityRow: View {
    let item: ActivityItem

    var symbol: String {
        switch item.kind {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .delete: return "trash"
        case .rename: return "pencil"
        case .move: return "folder"
        case .copy: return "doc.on.doc"
        case .backup: return "icloud.and.arrow.up"
        case .restore: return "clock.arrow.circlepath"
        case .account: return "person.crop.circle"
        case .sync: return "arrow.triangle.2.circlepath"
        case .security: return "lock"
        case .error: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(item.success ? Color.accentColor : .red).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline)
                if let d = item.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                Text(Fmt.relative(item.date)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct ActivityListView: View {
    @Query(sort: \ActivityItem.date, order: .reverse) private var activity: [ActivityItem]
    var body: some View {
        List(activity) { ActivityRow(item: $0) }
            .navigationTitle(L("Activity"))
            .overlay { if activity.isEmpty { EmptyStateView(title: L("No activity yet."), systemImage: "list.bullet") } }
    }
}

/// Upload from Files/Photos with automatic account selection.
struct UploadSheet: View {
    @EnvironmentObject var accounts: AccountManager
    @EnvironmentObject var transfers: TransferManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var selected: UUID?
    @State private var encrypt = false
    @State private var error: String?
    @State private var queued = 0

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Destination")) {
                    Picker(L("Account"), selection: $selected) {
                        Text(L("Automatic (most free space)")).tag(UUID?.none)
                        ForEach(accounts.accounts) { a in Text("\(a.provider.title) · \(a.email.isEmpty ? a.displayName : a.email)").tag(UUID?.some(a.id)) }
                    }
                    Text(L("Files go to the root folder of the account. Use the Files tab to upload into a specific folder.")).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle(L("Encrypt before upload"), isOn: $encrypt)
                } footer: {
                    Text(L("AES-256-GCM on this device. Encrypted files can only be opened with iCloud IPA and your recovery key."))
                }
                Section {
                    Button { picking = true } label: { Label(L("Choose files…"), systemImage: "doc.badge.plus") }
                    if queued > 0 { Text(LF("%d files queued", queued)).foregroundStyle(.green) }
                }
            }
            .navigationTitle(L("Upload"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): enqueue(urls)
                case .failure(let e): error = e.localizedDescription
                }
            }
            .onAppear { encrypt = settings.encryptUploads }
            .errorAlert($error)
        }
    }

    private func enqueue(_ urls: [URL]) {
        do {
            let bytes = urls.reduce(Int64(0)) { $0 + AppPaths.fileSize($1) }
            let account = try accounts.pickAccount(forBytes: bytes, preferred: selected)
            let provider = try accounts.provider(for: account.id)
            for url in urls {
                try transfers.enqueueUpload(file: url, account: account.id, folder: provider.rootFolder, encrypt: encrypt)
                queued += 1
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
