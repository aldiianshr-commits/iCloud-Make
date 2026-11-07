import SwiftUI
import SwiftData

struct RestoreView: View {
    @EnvironmentObject var restore: RestoreEngine
    @EnvironmentObject var backup: BackupEngine
    @EnvironmentObject var accounts: AccountManager
    @Query(sort: \BackupEntry.lastBackedUp, order: .reverse) private var entries: [BackupEntry]
    @State private var category: BackupCategory?
    @State private var selected = Set<String>()
    @State private var search = ""
    @State private var policy: ConflictPolicy = .skipDuplicates
    @State private var showPreview = false
    @State private var report: RestoreReport?
    @State private var error: String?
    @State private var importing = false

    private var counts: [BackupCategory: Int] {
        Dictionary(grouping: entries, by: \.category).mapValues(\.count)
    }

    private var filtered: [BackupEntry] {
        entries.filter { (category == nil || $0.category == category) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    Text(L("No backup catalogue on this device. If you backed up from another device or reinstalled the app, import the catalogue from your cloud account."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    importMenu
                }
            } else {
                Section(L("Categories")) {
                    Button { category = nil } label: { categoryRow(nil, count: entries.count) }
                    ForEach(BackupCategory.allCases.filter { counts[$0] != nil }) { c in
                        Button { category = c } label: { categoryRow(c, count: counts[c] ?? 0) }
                    }
                }
                Section {
                    HStack {
                        Button(L("Select all")) { selected = Set(filtered.map(\.key)) }
                        Spacer()
                        Button(L("Clear")) { selected.removeAll() }
                    }
                    .buttonStyle(.borderless)
                    ForEach(filtered.prefix(500)) { e in
                        Button { toggle(e) } label: { EntryRow(entry: e, selected: selected.contains(e.key)) }.buttonStyle(.plain)
                    }
                    if filtered.count > 500 { Text(LF("Showing 500 of %d — use search or categories to narrow down.", filtered.count)).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text(category?.title ?? L("All items"))
                }
                Section { importMenu }
            }
        }
        .searchable(text: $search)
        .navigationTitle(L("Restore"))
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                Button { showPreview = true } label: {
                    Text(LF("Review %d items", selected.count)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).padding()
                .background(.bar)
            }
        }
        .sheet(isPresented: $showPreview) {
            RestorePreviewSheet(entries: entries.filter { selected.contains($0.key) }, policy: $policy) { chosen in
                Task {
                    report = await restore.restore(chosen, policy: policy)
                    selected.removeAll()
                }
            }
        }
        .alert(L("Restore finished"), isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            if let r = report {
                Text(LF("%d restored, %d duplicates skipped, %d failed.", r.restored, r.skippedDuplicates, r.failed.count)
                     + (r.locations.isEmpty ? "" : "\n" + r.locations.sorted().joined(separator: "\n"))
                     + (r.failed.isEmpty ? "" : "\n\n" + r.failed.prefix(5).joined(separator: "\n")))
            }
        }
        .overlay {
            if restore.isRunning || importing {
                VStack(spacing: 10) {
                    ProgressView(value: restore.total > 0 ? Double(restore.processed) / Double(restore.total) : nil)
                    Text(importing ? L("Importing catalogue…") : LF("Restoring %d of %d", restore.processed + 1, restore.total)).font(.footnote)
                    Text(restore.current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(20).frame(maxWidth: 320).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .errorAlert($error)
    }

    private var importMenu: some View {
        Menu {
            ForEach(accounts.accounts) { a in
                Button("\(a.provider.title) · \(a.email.isEmpty ? a.displayName : a.email)") {
                    Task {
                        importing = true
                        defer { importing = false }
                        do { _ = try await backup.importLatestManifest(accountID: a.id) } catch { self.error = error.localizedDescription }
                    }
                }
            }
        } label: {
            Label(L("Import catalogue from cloud…"), systemImage: "icloud.and.arrow.down")
        }
        .disabled(accounts.accounts.isEmpty)
    }

    private func categoryRow(_ c: BackupCategory?, count: Int) -> some View {
        HStack {
            Label(c?.title ?? L("All items"), systemImage: c?.symbol ?? "square.stack.3d.up")
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
            if category == c { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
    }

    private func toggle(_ e: BackupEntry) {
        if selected.contains(e.key) { selected.remove(e.key) } else { selected.insert(e.key) }
    }
}

struct EntryRow: View {
    let entry: BackupEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
            Image(systemName: entry.category.symbol).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Fmt.bytes(entry.size))
                    Text("·")
                    Text(Fmt.date(entry.lastBackedUp))
                    if entry.encrypted { Image(systemName: "lock.fill") }
                    if entry.deletedAt != nil { Text(L("deleted on device")).foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Preview before restore: shows what will happen, detected conflicts and asks for confirmation.
struct RestorePreviewSheet: View {
    let entries: [BackupEntry]
    @Binding var policy: ConflictPolicy
    let onConfirm: ([BackupEntry]) -> Void
    @EnvironmentObject var restore: RestoreEngine
    @Environment(\.dismiss) private var dismiss
    @State private var conflicts: [BackupEntry] = []
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            List {
                Section(L("Summary")) {
                    let grouped = Dictionary(grouping: entries, by: \.category)
                    ForEach(grouped.keys.sorted { $0.rawValue < $1.rawValue }) { c in
                        LabeledContent { Text("\(grouped[c]?.count ?? 0)") } label: { Label(c.title, systemImage: c.symbol) }
                    }
                    LabeledContent(L("Total size"), value: Fmt.bytes(entries.reduce(0) { $0 + $1.size }))
                }
                Section {
                    Picker(L("If an item already exists"), selection: $policy) {
                        ForEach(ConflictPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    if !conflicts.isEmpty {
                        Label(LF("%d items already exist on this device", conflicts.count), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } header: { Text(L("Conflicts")) } footer: {
                    Text(L("Every file is checked against its stored checksum before it is restored. Encrypted backups are decrypted with this device's key."))
                }
                Section(L("Destination")) {
                    Text(L("Photos & videos → Photos library\nContacts → Contacts\nCalendar → Calendar\nReminders → Reminders\nFiles → Files ▸ On My iPhone ▸ iCloud IPA ▸ Restored")).font(.caption)
                }
            }
            .navigationTitle(L("Review restore"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Restore")) { confirm = true } }
            }
            .confirmationDialog(LF("Restore %d items?", entries.count), isPresented: $confirm) {
                Button(L("Restore")) { onConfirm(entries); dismiss() }
            }
            .task { conflicts = restore.conflicts(in: entries) }
        }
    }
}
