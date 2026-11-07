import SwiftUI
import SwiftData
import Charts

struct StorageDashboardView: View {
    @EnvironmentObject var accounts: AccountManager
    @EnvironmentObject var indexer: StorageIndexer
    @EnvironmentObject var env: AppEnvironment
    @Query(sort: \CloudAccount.sortOrder) private var accountList: [CloudAccount]
    @Query(filter: #Predicate<RemoteFileRecord> { $0.trashed == false }) private var records: [RemoteFileRecord]
    @Query(filter: #Predicate<TransferRecord> { $0.kindRaw == "upload" && $0.statusRaw == "completed" }, sort: \TransferRecord.finishedAt, order: .reverse)
    private var uploads: [TransferRecord]

    private var refs: [RemoteItemRef] { records.map { RemoteItemRef(accountID: $0.accountID, item: $0.asRemoteItem) } }

    var body: some View {
        let refs = self.refs
        let dups = StorageAnalyzer.duplicates(refs)
        let large = StorageAnalyzer.largest(refs)
        let usage = StorageAnalyzer.byCategory(refs)
        let trash = accountList.compactMap(\.quotaTrash).reduce(0, +)
        List {
            Section(L("Accounts")) {
                ForEach(accountList) { AccountRow(account: $0) }
                LabeledContent(L("Files indexed"), value: "\(records.filter { !$0.isFolder }.count)")
                LabeledContent(L("Folders indexed"), value: "\(records.filter(\.isFolder).count)")
                Button {
                    Task { await indexer.indexAll() }
                } label: {
                    HStack {
                        Label(L("Update index"), systemImage: "arrow.clockwise")
                        if !indexer.indexing.isEmpty { Spacer(); ProgressView() }
                    }
                }
                .disabled(!indexer.indexing.isEmpty)
                if records.isEmpty {
                    Text(L("Build the index once to see duplicates, large files and usage by type.")).font(.caption).foregroundStyle(.secondary)
                }
            }

            if !usage.isEmpty {
                Section(L("Usage by type")) {
                    Chart(usage) { u in
                        BarMark(x: .value(L("Size"), Double(u.bytes) / 1_048_576), y: .value(L("Type"), u.category.title))
                            .foregroundStyle(by: .value(L("Type"), u.category.title))
                    }
                    .chartLegend(.hidden)
                    .chartXAxisLabel("MB")
                    .frame(height: CGFloat(max(120, usage.count * 28)))
                    ForEach(usage) { u in
                        LabeledContent { Text("\(Fmt.bytes(u.bytes)) · \(u.count)") } label: { Label(u.category.title, systemImage: u.category.symbol) }
                    }
                }
            }

            let suggestions = StorageAnalyzer.suggestions(duplicates: dups, large: large, trashBytes: trash,
                                                          accounts: accountList.map { ($0.email.isEmpty ? $0.displayName : $0.email, $0.usageFraction) })
            if !suggestions.isEmpty {
                Section(L("Storage optimization")) {
                    ForEach(suggestions) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.detail).font(.subheadline)
                            if s.bytes > 0 { Text(LF("Up to %@ can be freed", Fmt.bytes(s.bytes))).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }

            Section(L("Tools")) {
                NavigationLink { DuplicatesView(groups: dups) } label: { LabeledContent(L("Duplicate files"), value: "\(dups.count)") }
                NavigationLink { RefListView(title: L("Large files"), refs: large) } label: { LabeledContent(L("Large files"), value: "\(large.count)") }
                NavigationLink { RefListView(title: L("Recently added"), refs: StorageAnalyzer.recent(refs)) } label: { Text(L("Recently added")) }
                NavigationLink { RecentUploadsView(uploads: Array(uploads.prefix(200))) } label: { LabeledContent(L("Recently uploaded"), value: "\(uploads.count)") }
                NavigationLink { TrashView() } label: { Label(L("Recently deleted (trash)"), systemImage: "trash") }
            }
        }
        .navigationTitle(L("Storage"))
        .errorAlert(Binding(get: { indexer.lastError }, set: { indexer.lastError = $0 }))
    }
}

struct DuplicatesView: View {
    let groups: [DuplicateGroup]
    @EnvironmentObject var accounts: AccountManager
    @EnvironmentObject var env: AppEnvironment
    @State private var removed = Set<String>()
    @State private var error: String?

    var body: some View {
        List {
            ForEach(groups) { g in
                Section {
                    ForEach(Array(g.files.enumerated()), id: \.element.id) { index, ref in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ref.item.name).lineLimit(1).strikethrough(removed.contains(ref.id))
                                Text("\(accounts.store.account(ref.accountID)?.email ?? "") · \(Fmt.date(ref.item.modifiedAt))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if index == 0 { Text(L("Oldest")).font(.caption2).foregroundStyle(.secondary) }
                        }
                        .swipeActions {
                            Button(role: .destructive) { Task { await trash(ref) } } label: { Label(L("Delete"), systemImage: "trash") }
                        }
                    }
                } header: {
                    Text(LF("%@ × %d · %@ reclaimable", Fmt.bytes(g.size), g.files.count, Fmt.bytes(g.reclaimable)))
                } footer: {
                    if g.key.hasPrefix("name:") { Text(L("Matched by name and size (provider gives no checksum) — check before deleting.")) }
                }
            }
        }
        .overlay { if groups.isEmpty { EmptyStateView(title: L("No duplicates found"), systemImage: "checkmark.circle") } }
        .navigationTitle(L("Duplicate files"))
        .errorAlert($error)
    }

    private func trash(_ ref: RemoteItemRef) async {
        do {
            try await accounts.provider(for: ref.accountID).delete(ref.item, permanently: false)
            env.store.removeFromIndex(account: ref.accountID, remoteID: ref.item.id)
            removed.insert(ref.id)
        } catch { self.error = error.localizedDescription }
    }
}

struct RefListView: View {
    let title: String
    let refs: [RemoteItemRef]
    @EnvironmentObject var accounts: AccountManager
    @EnvironmentObject var transfers: TransferManager

    var body: some View {
        List(refs) { ref in
            HStack {
                FileIcon(item: ref.item)
                VStack(alignment: .leading) {
                    Text(ref.item.name).lineLimit(1)
                    Text("\(Fmt.bytes(ref.item.size)) · \(accounts.store.account(ref.accountID)?.provider.title ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                Button { transfers.enqueueDownload(ref.item, account: ref.accountID) } label: { Label(L("Download"), systemImage: "arrow.down.circle") }
            }
        }
        .overlay { if refs.isEmpty { EmptyStateView(title: L("Nothing to show"), systemImage: "tray") } }
        .navigationTitle(title)
    }
}

struct RecentUploadsView: View {
    let uploads: [TransferRecord]
    var body: some View {
        List(uploads) { TransferRow(record: $0) }
            .overlay { if uploads.isEmpty { EmptyStateView(title: L("No uploads yet"), systemImage: "icloud.and.arrow.up") } }
            .navigationTitle(L("Recently uploaded"))
    }
}

/// Provider trash / recycle bin with restore and empty actions.
struct TrashView: View {
    @EnvironmentObject var accounts: AccountManager
    @State private var items: [UUID: [RemoteItem]] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var confirmEmpty: CloudAccount?

    var body: some View {
        List {
            ForEach(accounts.accounts) { acc in
                Section {
                    let list = items[acc.id] ?? []
                    if list.isEmpty { Text(loading ? L("Loading…") : L("Trash is empty")).foregroundStyle(.secondary) }
                    ForEach(list) { item in
                        HStack {
                            FileIcon(item: item)
                            VStack(alignment: .leading) {
                                Text(item.name).lineLimit(1)
                                Text(Fmt.bytes(item.size)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(L("Restore")) { Task { await restore(item, acc) } }.tint(.green)
                        }
                    }
                } header: {
                    HStack {
                        Text(acc.email.isEmpty ? acc.displayName : acc.email)
                        Spacer()
                        if !(items[acc.id] ?? []).isEmpty {
                            Button(L("Empty"), role: .destructive) { confirmEmpty = acc }.font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle(L("Recently deleted"))
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(L("Empty trash permanently?"), isPresented: Binding(get: { confirmEmpty != nil }, set: { if !$0 { confirmEmpty = nil } }), presenting: confirmEmpty) { acc in
            Button(L("Empty trash"), role: .destructive) { Task { await empty(acc) } }
        } message: { _ in Text(L("This cannot be undone.")) }
        .errorAlert($error)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        for acc in accounts.accounts {
            do { items[acc.id] = try await accounts.provider(for: acc.id).trashed() } catch { self.error = error.localizedDescription }
        }
    }

    private func restore(_ item: RemoteItem, _ acc: CloudAccount) async {
        do {
            try await accounts.provider(for: acc.id).restoreFromTrash(item)
            items[acc.id]?.removeAll { $0.id == item.id }
            accounts.store.logActivity(.restore, LF("Restored from trash: %@", item.name), account: acc.id)
        } catch { self.error = error.localizedDescription }
    }

    private func empty(_ acc: CloudAccount) async {
        do {
            try await accounts.provider(for: acc.id).emptyTrash()
            items[acc.id] = []
            accounts.store.logActivity(.delete, L("Trash emptied"), account: acc.id)
            await accounts.refresh(acc)
        } catch { self.error = error.localizedDescription }
    }
}
