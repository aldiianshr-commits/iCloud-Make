import SwiftUI
import SwiftData

struct AccountsView: View {
    @EnvironmentObject var accounts: AccountManager
    @Query(sort: \CloudAccount.sortOrder) private var accountList: [CloudAccount]
    @State private var error: String?
    @State private var addingTeraBox: UUID?
    @State private var connecting = false
    @State private var confirmRemove: CloudAccount?

    var body: some View {
        List {
            if accountList.isEmpty {
                Section {
                    Text(L("Connect Google Drive and/or TeraBox. You can add as many accounts as each provider allows.")).foregroundStyle(.secondary)
                }
            }
            ForEach(ProviderKind.allCases) { kind in
                let list = accountList.filter { $0.provider == kind }
                if !list.isEmpty {
                    Section(kind.title) {
                        ForEach(list) { acc in
                            NavigationLink { AccountDetailView(account: acc) } label: { AccountRow(account: acc) }
                                .swipeActions {
                                    Button(role: .destructive) { confirmRemove = acc } label: { Label(L("Remove"), systemImage: "trash") }
                                    if !acc.isActive { Button(L("Make active")) { accounts.setActive(acc) }.tint(.accentColor) }
                                }
                        }
                    }
                }
            }
            Section {
                Button { Task { await addGoogle() } } label: { Label(L("Add Google Drive account"), systemImage: "plus.circle.fill") }
                    .disabled(!AppConfig.isGoogleConfigured || connecting)
                if !AppConfig.isGoogleConfigured {
                    Text(L("Google Drive is not configured in this build: an iOS OAuth client ID must be set by the developer (see README ▸ Google Drive setup)."))
                        .font(.caption).foregroundStyle(.orange)
                }
                Button { addingTeraBox = UUID() } label: { Label(L("Add TeraBox account"), systemImage: "plus.circle") }
                    .disabled(connecting)
                Text(L("TeraBox has no public developer API. iCloud IPA uses TeraBox's own website session after you sign in there (experimental — may stop working if TeraBox changes its site)."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text(L("Add account")) }

            if accountList.count > 1 {
                Section(L("Between accounts")) {
                    NavigationLink { SyncPairsView() } label: { Label(L("Sync folders between accounts"), systemImage: "arrow.triangle.2.circlepath") }
                }
            }
        }
        .navigationTitle(L("Cloud Accounts"))
        .refreshable { await accounts.refreshAll() }
        .overlay { if connecting { ProgressView(L("Connecting…")).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .sheet(item: Binding(get: { addingTeraBox.map(IdentifiedUUID.init) }, set: { addingTeraBox = $0?.id })) { wrapped in
            TeraBoxLoginView(accountID: wrapped.id) { result in
                switch result {
                case .success(let session): Task { await addTeraBox(id: wrapped.id, session: session) }
                case .failure(let e):
                    if e != .cancelled { error = e.localizedDescription }
                    Task { await TeraBoxWebStore.removeData(for: wrapped.id) }
                }
            }
        }
        .confirmationDialog(L("Remove account?"), isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), presenting: confirmRemove) { acc in
            Button(L("Remove and sign out"), role: .destructive) { Task { await accounts.remove(acc) } }
        } message: { acc in
            Text(LF("Signs out of %@, revokes this app's access and deletes its saved session and local index. Files in the cloud are not touched.", acc.email.isEmpty ? acc.displayName : acc.email))
        }
        .errorAlert($error)
    }

    private func addGoogle() async {
        connecting = true
        defer { connecting = false }
        do { _ = try await accounts.addGoogleAccount() } catch {
            if (error as? AppError) != .cancelled { self.error = error.localizedDescription }
        }
    }

    private func addTeraBox(id: UUID, session: TeraBoxSession) async {
        connecting = true
        defer { connecting = false }
        do { _ = try await accounts.addTeraBoxAccount(id: id, session: session) } catch { self.error = error.localizedDescription }
    }
}

struct IdentifiedUUID: Identifiable { let id: UUID }

struct AccountDetailView: View {
    @Bindable var account: CloudAccount
    @EnvironmentObject var accounts: AccountManager
    @EnvironmentObject var indexer: StorageIndexer
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @State private var refreshing = false

    var body: some View {
        List {
            Section {
                AccountRow(account: account)
                LabeledContent(L("Name"), value: account.displayName)
                if !account.email.isEmpty { LabeledContent(L("Email / ID"), value: account.email) }
                LabeledContent(L("Status"), value: account.status.title)
                if let e = account.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                LabeledContent(L("Last activity"), value: Fmt.relative(account.lastActivity))
                LabeledContent(L("Index updated"), value: Fmt.relative(account.lastSync))
            }
            Section(L("Storage")) {
                LabeledContent(L("Total"), value: account.quotaTotal.map { Fmt.bytes($0) } ?? L("Not reported"))
                LabeledContent(L("Used"), value: account.quotaUsed.map { Fmt.bytes($0) } ?? "—")
                LabeledContent(L("Free"), value: account.quotaFree.map { Fmt.bytes($0) } ?? "—")
                if let t = account.quotaTrash, t > 0 { LabeledContent(L("In trash"), value: Fmt.bytes(t)) }
                LabeledContent(L("Refreshed"), value: Fmt.relative(account.quotaUpdatedAt))
            }
            Section {
                Picker(L("Role"), selection: Binding(get: { account.role }, set: { accounts.setRole($0, for: account) })) {
                    ForEach(AccountRole.allCases) { Text($0.title).tag($0) }
                }
                if !account.isActive { Button(L("Make active account")) { accounts.setActive(account) } }
            } header: { Text(L("Usage")) } footer: {
                Text(L("New uploads and backups go to the Primary account while it has room, then to Backup (fallback) accounts, then to the account with the most free space."))
            }
            Section {
                Button {
                    Task { refreshing = true; await accounts.refresh(account); refreshing = false }
                } label: { HStack { Label(L("Refresh status & storage"), systemImage: "arrow.clockwise"); if refreshing { Spacer(); ProgressView() } } }
                Button { Task { await indexer.index(account, full: true) } } label: {
                    HStack { Label(L("Rebuild file index"), systemImage: "list.bullet.indent"); if indexer.indexing.contains(account.id) { Spacer(); ProgressView() } }
                }
            }
            if account.provider == .teraBox {
                Section(L("Integration status")) {
                    Label(L("Experimental: uses TeraBox web endpoints with your signed-in session. Uploads are verified by size; TeraBox does not offer file versions."), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                Button(L("Remove account"), role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(account.provider.title)
        .confirmationDialog(L("Remove account?"), isPresented: $confirmRemove) {
            Button(L("Remove and sign out"), role: .destructive) {
                Task { await accounts.remove(account); dismiss() }
            }
        }
    }
}

/// One-way folder sync between accounts.
struct SyncPairsView: View {
    @EnvironmentObject var sync: SyncEngine
    @EnvironmentObject var env: AppEnvironment
    @Query private var pairs: [SyncPair]
    @State private var pickingSource = false
    @State private var pendingSource: (UUID, RemoteFolder)?
    @State private var pickingTarget = false

    var body: some View {
        List {
            Section {
                ForEach(pairs) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(p.sourceFolderName) → \(p.targetFolderName)").font(.headline)
                        Text("\(env.store.account(p.sourceAccountID)?.email ?? "") → \(env.store.account(p.targetAccountID)?.email ?? "")").font(.caption).foregroundStyle(.secondary)
                        if let r = p.lastResult { Text("\(Fmt.relative(p.lastRun)): \(r)").font(.caption2).foregroundStyle(.secondary) }
                        HStack {
                            Button(L("Sync now")) { Task { _ = await sync.run(p) } }.buttonStyle(.bordered).disabled(sync.running.contains(p.id))
                            if sync.running.contains(p.id) { ProgressView() }
                        }
                    }
                }
                .onDelete { idx in for i in idx { env.store.context.delete(pairs[i]) }; env.store.save() }
                Button { pickingSource = true } label: { Label(L("New sync pair"), systemImage: "plus") }
            } footer: {
                Text(L("Copies new or changed files from the source folder to the target folder (one way). Nothing is deleted in either account."))
            }
        }
        .navigationTitle(L("Sync between accounts"))
        .sheet(isPresented: $pickingSource) {
            FolderPickerView(title: L("Source folder")) { acc, folder in
                pendingSource = (acc, folder)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { pickingTarget = true }
            }
        }
        .sheet(isPresented: $pickingTarget) {
            FolderPickerView(title: L("Target folder")) { acc, folder in
                guard let s = pendingSource else { return }
                env.store.context.insert(SyncPair(source: (s.0, s.1.id, s.1.name), target: (acc, folder.id, folder.name)))
                env.store.save()
                pendingSource = nil
            }
        }
    }
}
