import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject var accounts: AccountManager
    @Query(sort: \CloudAccount.sortOrder) private var accountList: [CloudAccount]
    @State private var selectedAccount: UUID?

    var body: some View {
        Group {
            if accountList.isEmpty {
                List {
                    Section { NavigationLink { LocalFilesView() } label: { Label(L("On this device"), systemImage: "iphone") } }
                }
                .overlay { EmptyStateView(title: L("No cloud account"), systemImage: "icloud.slash", message: L("Connect Google Drive or TeraBox in Cloud Accounts.")) }
            } else if let id = selectedAccount ?? accounts.activeAccount?.id, let acc = accountList.first(where: { $0.id == id }),
                      let provider = try? accounts.provider(for: acc.id) {
                FolderBrowserView(accountID: acc.id, folder: provider.rootFolder, title: acc.provider.title)
                    .id(acc.id)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                Picker(L("Account"), selection: Binding(get: { selectedAccount ?? accounts.activeAccount?.id }, set: { selectedAccount = $0 })) {
                                    ForEach(accountList) { a in
                                        Label(a.email.isEmpty ? a.displayName : a.email, systemImage: a.provider.symbol).tag(UUID?.some(a.id))
                                    }
                                }
                                Divider()
                                NavigationLink { LocalFilesView() } label: { Label(L("On this device"), systemImage: "iphone") }
                                NavigationLink { TransfersView() } label: { Label(L("Transfers"), systemImage: "arrow.up.arrow.down") }
                            } label: {
                                Label(L("Accounts"), systemImage: "person.2.circle")
                            }
                        }
                    }
            }
        }
    }
}

/// Browses one folder of one account. All actions call the provider API directly.
struct FolderBrowserView: View {
    let accountID: UUID
    let folder: RemoteFolder
    let title: String

    @EnvironmentObject var accounts: AccountManager
    @EnvironmentObject var transfers: TransferManager
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var lock: AppLockManager
    @EnvironmentObject var env: AppEnvironment

    @State private var items: [RemoteItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var searchResults: [RemoteItem]?
    @State private var filter: FileCategory?
    @State private var openFolder: RemoteFolder?
    @State private var preview: LocalFile?
    @State private var share: LocalFile?
    @State private var renaming: RemoteItem?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var importing = false
    @State private var transferTarget: (item: RemoteItem, move: Bool)?
    @State private var showTransferPicker = false
    @State private var infoItem: RemoteItem?
    @State private var versionsItem: RemoteItem?
    @State private var confirmDelete: RemoteItem?
    @State private var busy: String?
    @State private var selection = Set<String>()
    @State private var selecting = false

    private var provider: CloudProvider? { try? accounts.provider(for: accountID) }

    private var shown: [RemoteItem] {
        var list = searchResults ?? items
        if let filter { list = list.filter { $0.category == filter || ($0.isFolder && searchResults == nil && filter == .folder) } }
        return sort(list)
    }

    private func sort(_ list: [RemoteItem]) -> [RemoteItem] {
        let asc = settings.sortAscending
        return list.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let r: Bool
            switch settings.sortMode {
            case .name: r = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date: r = (a.modifiedAt ?? .distantPast) < (b.modifiedAt ?? .distantPast)
            case .size: r = a.size < b.size
            case .type: r = (a.name as NSString).pathExtension.lowercased() < (b.name as NSString).pathExtension.lowercased()
            }
            return asc ? r : !r
        }
    }

    var body: some View {
        content
            .navigationTitle(folder.name.isEmpty ? title : folder.name)
            .searchable(text: $search, prompt: L("Search in this account"))
            .onSubmit(of: .search) { Task { await runSearch() } }
            .onChange(of: search) { _, v in if v.isEmpty { searchResults = nil } }
            .refreshable { await load() }
            .task { if items.isEmpty { await load() } }
            .toolbar { toolbar }
            .navigationDestination(item: $openFolder) { f in
                FolderBrowserView(accountID: accountID, folder: f, title: title)
            }
            .sheet(item: $preview) { QuickLookView(url: $0.url).ignoresSafeArea() }
            .sheet(item: $share) { ShareSheet(items: [$0.url]) }
            .sheet(item: $infoItem) { item in FileInfoView(item: item, accountID: accountID) }
            .sheet(item: $versionsItem) { item in VersionsView(item: item, accountID: accountID) }
            .sheet(isPresented: $showTransferPicker) {
                if let t = transferTarget {
                    FolderPickerView(title: t.move ? L("Move to…") : L("Copy to…")) { target, folder in
                        transfers.enqueueTransfer(t.item, from: accountID, to: target, folder: folder, move: t.move)
                        if t.move { items.removeAll { $0.id == t.item.id } }
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { upload(urls) }
                if case .failure(let e) = result { error = e.localizedDescription }
            }
            .alert(L("Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(L("Name"), text: $newName)
                Button(L("Cancel"), role: .cancel) {}
                Button(L("Rename")) { if let r = renaming { Task { await rename(r, to: newName) } } }
            }
            .alert(L("New folder"), isPresented: $creatingFolder) {
                TextField(L("Name"), text: $newName)
                Button(L("Cancel"), role: .cancel) {}
                Button(L("Create")) { Task { await createFolder(newName) } }
            }
            .confirmationDialog(L("Delete?"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), presenting: confirmDelete) { item in
                Button(L("Move to trash"), role: .destructive) { Task { await delete(item) } }
            } message: { item in
                Text(LF("“%@” will be moved to the provider's trash. You can restore it from Storage ▸ Recently deleted.", item.name))
            }
            .overlay(alignment: .bottom) {
                if let busy {
                    HStack { ProgressView(); Text(busy).font(.footnote) }
                        .padding(12).background(.regularMaterial, in: Capsule()).padding()
                }
            }
            .errorAlert($error)
    }

    @ViewBuilder private var content: some View {
        if loading && items.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            EmptyStateView(title: searchResults != nil ? L("No results") : L("Empty folder"), systemImage: searchResults != nil ? "magnifyingglass" : "folder")
        } else if settings.fileViewMode == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                    ForEach(shown) { item in
                        Button { open(item) } label: { gridCell(item) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: item) }
                    }
                }
                .padding()
            }
        } else {
            List(shown, selection: $selection) { item in
                Button { open(item) } label: { row(item) }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: item) }
                    .swipeActions {
                        Button(role: .destructive) { confirmDelete = item } label: { Label(L("Delete"), systemImage: "trash") }
                        Button { renaming = item; newName = item.name } label: { Label(L("Rename"), systemImage: "pencil") }.tint(.orange)
                    }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
        }
    }

    private func row(_ item: RemoteItem) -> some View {
        HStack(spacing: 12) {
            FileIcon(item: item)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name).lineLimit(1)
                    if item.isFolder && env.store.isProtected(account: accountID, remoteID: item.id) {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(item.isFolder ? Fmt.date(item.modifiedAt) : "\(Fmt.bytes(item.size)) · \(Fmt.date(item.modifiedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isFolder { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }

    private func gridCell(_ item: RemoteItem) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary)
                if let thumb = item.thumbnailURL, item.category == .photo || item.category == .video {
                    AsyncImage(url: thumb) { img in img.resizable().scaledToFill() } placeholder: { FileIcon(item: item, size: 44) }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    FileIcon(item: item, size: 44)
                }
            }
            .frame(height: 88)
            Text(item.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            if !item.isFolder { Text(Fmt.bytes(item.size)).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { importing = true } label: { Label(L("Upload files"), systemImage: "icloud.and.arrow.up") }
                Button { newName = ""; creatingFolder = true } label: { Label(L("New folder"), systemImage: "folder.badge.plus") }
                Divider()
                Picker(L("View"), selection: $settings.fileViewMode) {
                    Label(L("List"), systemImage: "list.bullet").tag(FileViewMode.list)
                    Label(L("Grid"), systemImage: "square.grid.2x2").tag(FileViewMode.grid)
                }
                Picker(L("Sort by"), selection: $settings.sortMode) {
                    ForEach(FileSortMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L("Ascending"), isOn: $settings.sortAscending)
                Picker(L("Filter"), selection: $filter) {
                    Text(L("All types")).tag(FileCategory?.none)
                    ForEach(FileCategory.allCases) { Label($0.title, systemImage: $0.symbol).tag(FileCategory?.some($0)) }
                }
                Divider()
                Button { selecting.toggle(); selection.removeAll() } label: { Label(selecting ? L("Done selecting") : L("Select"), systemImage: "checkmark.circle") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        if selecting && !selection.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { batchDownload() } label: { Label(L("Download"), systemImage: "arrow.down.circle") }
                Spacer()
                Button { Task { await compressSelection() } } label: { Label(L("ZIP"), systemImage: "doc.zipper") }
                Spacer()
                Button(role: .destructive) { Task { await batchDelete() } } label: { Label(L("Delete"), systemImage: "trash") }
            }
        }
    }

    @ViewBuilder private func menu(for item: RemoteItem) -> some View {
        if !item.isFolder {
            Button { Task { await previewItem(item) } } label: { Label(L("Preview"), systemImage: "eye") }
            Button { transfers.enqueueDownload(item, account: accountID) } label: { Label(L("Download"), systemImage: "arrow.down.circle") }
            Button { Task { await shareItem(item) } } label: { Label(L("Share…"), systemImage: "square.and.arrow.up") }
        }
        Button { renaming = item; newName = item.name } label: { Label(L("Rename"), systemImage: "pencil") }
        Button { transferTarget = (item, false); showTransferPicker = true } label: { Label(L("Copy to…"), systemImage: "doc.on.doc") }
        Button { transferTarget = (item, true); showTransferPicker = true } label: { Label(L("Move to…"), systemImage: "folder") }
        if ZipService.isSupportedArchive(item.name) && (item.name as NSString).pathExtension.lowercased() == "zip" {
            Button { Task { await extract(item) } } label: { Label(L("Extract here"), systemImage: "archivebox") }
        }
        if item.isFolder {
            let protected = env.store.isProtected(account: accountID, remoteID: item.id)
            Button { Task { await toggleProtection(item, on: !protected) } } label: {
                Label(protected ? L("Remove Face ID lock") : L("Lock with Face ID"), systemImage: protected ? "lock.open" : "lock")
            }
        }
        if provider?.capabilities.contains(.revisions) == true && !item.isFolder {
            Button { versionsItem = item } label: { Label(L("Versions"), systemImage: "clock.arrow.circlepath") }
        }
        Button { infoItem = item } label: { Label(L("Info"), systemImage: "info.circle") }
        Divider()
        Button(role: .destructive) { confirmDelete = item } label: { Label(L("Delete"), systemImage: "trash") }
    }

    // MARK: Actions

    private func load() async {
        guard let provider else { return }
        loading = true
        defer { loading = false }
        do {
            items = try await provider.list(folder: folder)
            env.store.upsertIndex(account: accountID, items: items)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runSearch() async {
        guard let provider, !search.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        loading = true
        defer { loading = false }
        do { searchResults = try await provider.search(search) } catch { self.error = error.localizedDescription }
    }

    private func open(_ item: RemoteItem) {
        if selecting { if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }; return }
        guard item.isFolder else { Task { await previewItem(item) }; return }
        let f = RemoteFolder(id: item.id, name: item.name, path: item.path)
        if env.store.isProtected(account: accountID, remoteID: item.id) {
            Task {
                if await lock.unlockFolder("\(accountID.uuidString)|\(item.id)", name: item.name) { openFolder = f }
            }
        } else {
            openFolder = f
        }
    }

    private func fetchLocal(_ item: RemoteItem) async throws -> URL {
        guard let provider else { throw AppError.notAuthenticated }
        let dir = AppPaths.ensure(AppPaths.staging.appendingPathComponent("preview-\(UUID().uuidString)", isDirectory: true))
        busy = LF("Downloading %@…", item.name)
        defer { busy = nil }
        return try await TransferManager.download(item, provider: provider, to: dir, progress: nil)
    }

    private func previewItem(_ item: RemoteItem) async {
        do { preview = LocalFile(url: try await fetchLocal(item)) } catch { self.error = error.localizedDescription }
    }

    private func shareItem(_ item: RemoteItem) async {
        do { share = LocalFile(url: try await fetchLocal(item)) } catch { self.error = error.localizedDescription }
    }

    private func upload(_ urls: [URL]) {
        do {
            for url in urls { try transfers.enqueueUpload(file: url, account: accountID, folder: folder) }
        } catch { self.error = error.localizedDescription }
    }

    private func createFolder(_ name: String) async {
        guard let provider, !name.isEmpty else { return }
        do {
            let made = try await provider.createFolder(name: AppPaths.sanitize(name), in: folder)
            items.append(made)
            env.store.upsertIndex(account: accountID, items: [made])
        } catch { self.error = error.localizedDescription }
    }

    private func rename(_ item: RemoteItem, to name: String) async {
        guard let provider, !name.isEmpty, name != item.name else { return }
        do {
            let updated = try await provider.rename(item, to: name)
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = updated }
            env.store.removeFromIndex(account: accountID, remoteID: item.id)
            env.store.upsertIndex(account: accountID, items: [updated])
            env.store.logActivity(.rename, LF("Renamed to %@", name), detail: item.name, account: accountID)
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ item: RemoteItem) async {
        guard let provider else { return }
        do {
            try await provider.delete(item, permanently: false)
            items.removeAll { $0.id == item.id }
            env.store.removeFromIndex(account: accountID, remoteID: item.id)
            env.store.logActivity(.delete, LF("Moved to trash: %@", item.name), account: accountID)
        } catch { self.error = error.localizedDescription }
    }

    private func batchDelete() async {
        for item in items where selection.contains(item.id) { await delete(item) }
        selection.removeAll()
    }

    private func batchDownload() {
        for item in items where selection.contains(item.id) && !item.isFolder { transfers.enqueueDownload(item, account: accountID) }
        selection.removeAll()
        selecting = false
    }

    private func toggleProtection(_ item: RemoteItem, on: Bool) async {
        let key = "\(accountID.uuidString)|\(item.id)"
        // Changing protection always requires authentication.
        guard await lock.unlockFolder(key, name: item.name) else { return }
        env.store.setProtected(on, account: accountID, remoteID: item.id, name: item.name)
        env.store.logActivity(.security, on ? LF("Locked folder %@", item.name) : LF("Unlocked folder %@", item.name), account: accountID)
        items = items // refresh lock badges
    }

    /// Downloads a .zip, extracts it locally and uploads the content into a new folder next to it.
    private func extract(_ item: RemoteItem) async {
        guard let provider else { return }
        do {
            let local = try await fetchLocal(item)
            busy = L("Extracting…")
            defer { busy = nil }
            let outDir = AppPaths.ensure(AppPaths.staging.appendingPathComponent("unzip-\(UUID().uuidString)", isDirectory: true))
            let files = try ZipService.unzip(local, to: outDir)
            let base = (item.name as NSString).deletingPathExtension
            let target = try await provider.createFolder(name: base, in: folder)
            items.append(target)
            var cache: [String: RemoteFolder] = ["": RemoteFolder(id: target.id, name: target.name, path: target.path)]
            for f in files {
                let rel = String(f.deletingLastPathComponent().path.dropFirst(outDir.standardizedFileURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                var dest = cache[""]!
                if !rel.isEmpty {
                    if let c = cache[rel] { dest = c } else {
                        var current = dest
                        for comp in rel.split(separator: "/").map(String.init) {
                            let made = try await provider.createFolder(name: comp, in: current)
                            current = RemoteFolder(id: made.id, name: made.name, path: made.path)
                        }
                        cache[rel] = current
                        dest = current
                    }
                }
                try transfers.enqueueUpload(file: f, account: accountID, folder: dest, encrypt: false, deleteSourceAfter: true)
            }
            env.store.logActivity(.upload, LF("Extracted %@ (%d files)", item.name, files.count), account: accountID)
        } catch { self.error = error.localizedDescription }
    }

    /// Downloads the selected files, zips them and uploads the archive to this folder.
    private func compressSelection() async {
        guard provider != nil else { return }
        let chosen = items.filter { selection.contains($0.id) && !$0.isFolder }
        guard !chosen.isEmpty else { return }
        do {
            var locals: [URL] = []
            for item in chosen { locals.append(try await fetchLocal(item)) }
            busy = L("Compressing…")
            defer { busy = nil }
            let archive = AppPaths.tempFile("Archive-\(BackupEngine.snapshotName("files", date: Date())).zip")
            try ZipService.zip(locals, into: archive)
            try transfers.enqueueUpload(file: archive, name: archive.lastPathComponent, account: accountID, folder: folder, encrypt: false, deleteSourceAfter: true)
            selection.removeAll()
            selecting = false
        } catch { self.error = error.localizedDescription }
    }
}

extension RemoteFolder {
    init(item: RemoteItem) { self.init(id: item.id, name: item.name, path: item.path) }
}
