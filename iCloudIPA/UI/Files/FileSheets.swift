import SwiftUI
import SwiftData

/// Choose a destination folder in any connected account (copy / move / sync targets).
struct FolderPickerView: View {
    let title: String
    let onPick: (UUID, RemoteFolder) -> Void
    @EnvironmentObject var accounts: AccountManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(accounts.accounts) { acc in
                if let p = try? accounts.provider(for: acc.id) {
                    NavigationLink {
                        FolderPickList(accountID: acc.id, folder: p.rootFolder) { folder in
                            onPick(acc.id, folder)
                            dismiss()
                        }
                    } label: { AccountRow(account: acc) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
        }
    }
}

struct FolderPickList: View {
    let accountID: UUID
    let folder: RemoteFolder
    let onChoose: (RemoteFolder) -> Void
    @EnvironmentObject var accounts: AccountManager
    @State private var folders: [RemoteItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        List {
            if loading { ProgressView() }
            ForEach(folders) { f in
                NavigationLink {
                    FolderPickList(accountID: accountID, folder: RemoteFolder(item: f), onChoose: onChoose)
                } label: { Label(f.name, systemImage: "folder.fill") }
            }
        }
        .overlay { if !loading && folders.isEmpty { EmptyStateView(title: L("No subfolders"), systemImage: "folder") } }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(L("Choose")) { onChoose(folder) } }
            ToolbarItem(placement: .bottomBar) { Button { creating = true } label: { Label(L("New folder"), systemImage: "folder.badge.plus") } }
        }
        .alert(L("New folder"), isPresented: $creating) {
            TextField(L("Name"), text: $newName)
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Create")) {
                Task {
                    do {
                        let p = try accounts.provider(for: accountID)
                        folders.append(try await p.createFolder(name: AppPaths.sanitize(newName), in: folder))
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .task {
            do {
                let p = try accounts.provider(for: accountID)
                folders = try await p.list(folder: folder).filter(\.isFolder)
            } catch { self.error = error.localizedDescription }
            loading = false
        }
        .errorAlert($error)
    }
}

struct FileInfoView: View {
    let item: RemoteItem
    let accountID: UUID
    @EnvironmentObject var accounts: AccountManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        FileIcon(item: item, size: 48)
                        VStack(alignment: .leading) {
                            Text(item.name).font(.headline)
                            Text(item.category.title).foregroundStyle(.secondary)
                        }
                    }
                }
                Section(L("Details")) {
                    if !item.isFolder { LabeledContent(L("Size"), value: Fmt.bytes(item.size)) }
                    LabeledContent(L("Created"), value: Fmt.date(item.createdAt))
                    LabeledContent(L("Modified"), value: Fmt.date(item.modifiedAt))
                    if let m = item.mimeType { LabeledContent(L("Type"), value: m) }
                    if let md5 = item.md5 { LabeledContent("MD5", value: md5).font(.caption.monospaced()) }
                    if item.name.hasSuffix(".\(FileEncryptor.encryptedExtension)") {
                        Label(L("Encrypted by iCloud IPA"), systemImage: "lock.fill").foregroundStyle(.green)
                    }
                }
                Section(L("Location")) {
                    if let acc = accounts.store.account(accountID) {
                        LabeledContent(L("Provider"), value: acc.provider.title)
                        LabeledContent(L("Account"), value: acc.email.isEmpty ? acc.displayName : acc.email)
                    }
                    LabeledContent(L("Path / ID"), value: item.path ?? item.id).font(.caption)
                }
            }
            .navigationTitle(L("Info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
    }
}

/// File version history (Google Drive revisions).
struct VersionsView: View {
    let item: RemoteItem
    let accountID: UUID
    @EnvironmentObject var accounts: AccountManager
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [RemoteRevision] = []
    @State private var loading = true
    @State private var error: String?
    @State private var restoredTo: LocalFile?

    var body: some View {
        NavigationStack {
            List(revisions) { rev in
                HStack {
                    VStack(alignment: .leading) {
                        Text(Fmt.date(rev.modifiedAt))
                        Text(rev.size.map(Fmt.bytes) ?? "—").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Download")) { Task { await download(rev) } }.buttonStyle(.bordered)
                }
            }
            .overlay {
                if loading { ProgressView() }
                else if revisions.isEmpty { EmptyStateView(title: L("No earlier versions"), systemImage: "clock") }
            }
            .navigationTitle(L("Versions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
            .task {
                do { revisions = try await accounts.provider(for: accountID).revisions(of: item) } catch { self.error = error.localizedDescription }
                loading = false
            }
            .sheet(item: $restoredTo) { QuickLookView(url: $0.url) }
            .errorAlert($error)
        }
    }

    private func download(_ rev: RemoteRevision) async {
        do {
            let p = try accounts.provider(for: accountID)
            let base = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            let name = "\(base) (\(BackupEngine.snapshotName("version", date: rev.modifiedAt ?? Date())))" + (ext.isEmpty ? "" : ".\(ext)")
            let dest = AppPaths.uniqueURL(in: AppPaths.downloads, name: name)
            try await p.downloadRevision(rev, of: item, to: dest)
            if let md5 = rev.md5, try FileHasher.md5Hex(of: dest) != md5.lowercased() { throw AppError.integrityCheckFailed(name) }
            restoredTo = LocalFile(url: dest)
        } catch { self.error = error.localizedDescription }
    }
}

/// Upload / download queue and history.
struct TransfersView: View {
    @EnvironmentObject var transfers: TransferManager
    @Query(sort: \TransferRecord.createdAt, order: .reverse) private var records: [TransferRecord]

    var body: some View {
        List {
            let active = records.filter { !$0.status.isFinished }
            if !active.isEmpty {
                Section(L("Queue")) { ForEach(active) { TransferRow(record: $0) } }
            }
            Section(L("History")) {
                ForEach(records.filter(\.status.isFinished)) { TransferRow(record: $0) }
            }
        }
        .overlay { if records.isEmpty { EmptyStateView(title: L("No transfers"), systemImage: "arrow.up.arrow.down") } }
        .navigationTitle(L("Transfers"))
        .toolbar {
            Button(L("Clear history")) { transfers.clearFinished() }.disabled(!records.contains(where: \.status.isFinished))
        }
    }
}

struct TransferRow: View {
    @EnvironmentObject var transfers: TransferManager
    let record: TransferRecord

    var statusText: String {
        switch record.status {
        case .queued: return L("Waiting")
        case .running: return L("In progress")
        case .paused: return L("Paused")
        case .completed: return record.verified ? L("Completed · verified") : L("Completed")
        case .failed: return L("Failed")
        case .cancelled: return L("Cancelled")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: record.kind == .upload ? "arrow.up.circle" : record.kind == .download ? "arrow.down.circle" : "arrow.left.arrow.right.circle")
                Text(record.name).lineLimit(1)
                if record.encrypted { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.green) }
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(record.status == .failed ? .red : .secondary)
            }
            if let live = transfers.live[record.id] {
                ProgressView(value: live.fraction)
                Text("\(Fmt.bytes(live.completed)) / \(Fmt.bytes(live.total))").font(.caption2).foregroundStyle(.secondary)
            } else if record.status == .running || record.status == .queued {
                ProgressView().controlSize(.small)
            }
            if let e = record.errorMessage, record.status == .failed { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(3) }
        }
        .swipeActions {
            if record.status == .running || record.status == .queued {
                Button(L("Pause")) { transfers.pause(record) }.tint(.orange)
                Button(L("Cancel"), role: .destructive) { transfers.cancel(record) }
            } else if record.status == .paused || record.status == .failed {
                Button(record.status == .failed ? L("Retry") : L("Resume")) { transfers.resume(record) }.tint(.green)
                Button(L("Cancel"), role: .destructive) { transfers.cancel(record) }
            }
        }
    }
}

/// Files stored inside the app (Downloads, Restored) — also visible in the Files app.
struct LocalFilesView: View {
    var directory: URL = AppPaths.documents
    @EnvironmentObject var transfers: TransferManager
    @EnvironmentObject var accounts: AccountManager
    @State private var files: [URL] = []
    @State private var preview: LocalFile?
    @State private var share: LocalFile?
    @State private var error: String?
    @State private var uploadTarget: URL?

    var body: some View {
        List(files, id: \.self) { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            Group {
                if isDir {
                    NavigationLink { LocalFilesView(directory: url) } label: { Label(url.lastPathComponent, systemImage: "folder.fill") }
                } else {
                    Button { preview = LocalFile(url: url) } label: {
                        HStack {
                            FileIcon(item: RemoteItem(id: url.path, name: url.lastPathComponent, isFolder: false, size: AppPaths.fileSize(url)))
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent).lineLimit(1)
                                Text(Fmt.bytes(AppPaths.fileSize(url))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
            .contextMenu {
                Button { share = LocalFile(url: url) } label: { Label(L("Share…"), systemImage: "square.and.arrow.up") }
                Button { uploadTarget = url } label: { Label(L("Upload to cloud…"), systemImage: "icloud.and.arrow.up") }
                if !isDir && (url.pathExtension.lowercased() == "zip") {
                    Button { extract(url) } label: { Label(L("Extract here"), systemImage: "archivebox") }
                }
                Button { compress(url) } label: { Label(L("Compress (ZIP)"), systemImage: "doc.zipper") }
                Button(role: .destructive) { try? FileManager.default.removeItem(at: url); reload() } label: { Label(L("Delete"), systemImage: "trash") }
            }
        }
        .overlay { if files.isEmpty { EmptyStateView(title: L("Nothing here yet"), systemImage: "iphone", message: L("Downloads and restored files are stored here and in the Files app.")) } }
        .navigationTitle(directory == AppPaths.documents ? L("On this device") : directory.lastPathComponent)
        .onAppear(perform: reload)
        .refreshable { reload() }
        .sheet(item: $preview) { QuickLookView(url: $0.url).ignoresSafeArea() }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
        .sheet(item: Binding(get: { uploadTarget.map(LocalFile.init) }, set: { uploadTarget = $0?.url })) { file in
            FolderPickerView(title: L("Upload to…")) { account, folder in
                do { try transfers.enqueueUpload(file: file.url, account: account, folder: folder) } catch { self.error = error.localizedDescription }
            }
        }
        .errorAlert($error)
    }

    private func reload() {
        AppPaths.ensure(directory)
        files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func extract(_ url: URL) {
        do {
            let dest = AppPaths.uniqueURL(in: url.deletingLastPathComponent(), name: url.deletingPathExtension().lastPathComponent)
            _ = try ZipService.unzip(url, to: dest)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func compress(_ url: URL) {
        do {
            let out = AppPaths.uniqueURL(in: url.deletingLastPathComponent(), name: url.deletingPathExtension().lastPathComponent + ".zip")
            try ZipService.zip([url], into: out)
            reload()
        } catch { self.error = error.localizedDescription }
    }
}
