import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var lock: AppLockManager
    @State private var lockToggle = false
    @State private var showRecovery = false

    var body: some View {
        Form {
            Section(L("Language")) {
                Picker(L("App language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { settings.appLockEnabled }, set: { on in Task { _ = await lock.setLockEnabled(on) } })) {
                    Label(LF("Lock with %@", lock.authenticator.biometryName), systemImage: "faceid")
                }
                if settings.appLockEnabled {
                    Picker(L("Require after"), selection: $settings.lockGraceSeconds) {
                        Text(L("Immediately")).tag(0)
                        Text(L("1 minute")).tag(60)
                        Text(L("5 minutes")).tag(300)
                        Text(L("15 minutes")).tag(900)
                    }
                }
                Toggle(L("Encrypt uploads by default"), isOn: $settings.encryptUploads)
                Button { showRecovery = true } label: { Label(L("Encryption recovery key"), systemImage: "key") }
            } header: { Text(L("Security & privacy")) } footer: {
                Text(L("Passcode is used automatically when Face ID is unavailable. Sign-in tokens and sessions are stored only in the iOS Keychain on this device; passwords are never stored. Individual folders can be locked from their context menu."))
            }
            if let e = lock.lastError { Section { ErrorBanner(message: e) { lock.lastError = nil } } }

            Section {
                Toggle(L("Use cellular data"), isOn: $settings.allowCellular)
                Stepper(LF("Parallel transfers: %d", settings.maxParallelTransfers), value: $settings.maxParallelTransfers, in: 1...6)
            } header: { Text(L("Transfers")) } footer: {
                Text(L("Each provider also has its own limit (Google Drive 4, TeraBox 2). Changes apply to new transfers after restarting the app."))
            }

            Section(L("Files")) {
                Picker(L("Default view"), selection: $settings.fileViewMode) {
                    Text(L("List")).tag(FileViewMode.list)
                    Text(L("Grid")).tag(FileViewMode.grid)
                }
                Picker(L("Sort by"), selection: $settings.sortMode) {
                    ForEach(FileSortMode.allCases) { Text($0.title).tag($0) }
                }
            }

            Section(L("About")) {
                LabeledContent(L("Version"), value: AppConfig.version)
                NavigationLink { PrivacyInfoView() } label: { Text(L("What iCloud IPA can and cannot back up")) }
                Toggle(L("Show developer information"), isOn: $settings.showDeveloperInfo)
                if settings.showDeveloperInfo {
                    NavigationLink { DeveloperInfoView() } label: { Label(L("Developer diagnostics"), systemImage: "hammer") }
                }
            }
        }
        .navigationTitle(L("Settings"))
        .sheet(isPresented: $showRecovery) { RecoveryKeyView() }
    }
}

struct RecoveryKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key: String?
    @State private var revealed = false
    @State private var importText = ""
    @State private var message: String?
    @EnvironmentObject var lock: AppLockManager

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if revealed, let key {
                        Text(key).font(.callout.monospaced()).textSelection(.enabled)
                        Button(L("Copy")) { UIPasteboard.general.string = key }
                    } else {
                        Button(L("Show recovery key")) {
                            Task {
                                switch await lock.authenticator.authenticate(reason: L("Show encryption recovery key")) {
                                case .success:
                                    do { key = try KeyManager.shared.exportRecoveryKey(); revealed = true } catch { message = error.localizedDescription }
                                case .failure(let e): if e != .cancelled { message = e.localizedDescription }
                                }
                            }
                        }
                    }
                } header: { Text(L("Your key")) } footer: {
                    Text(L("Keep this key somewhere safe. It is needed to open encrypted files on another device or after reinstalling. Without it, encrypted backups cannot be recovered."))
                }
                Section {
                    TextField(L("Paste recovery key"), text: $importText, axis: .vertical).font(.callout.monospaced())
                    Button(L("Use this key")) {
                        do { try KeyManager.shared.importRecoveryKey(importText); message = L("Recovery key imported."); importText = "" }
                        catch { message = error.localizedDescription }
                    }
                    .disabled(importText.isEmpty)
                } header: { Text(L("Import key from another device")) } footer: {
                    Text(L("Replacing the key makes files encrypted with the current key unreadable unless you keep its recovery key."))
                }
                if let message { Section { Text(message) } }
            }
            .navigationTitle(L("Recovery key"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
    }
}

struct PrivacyInfoView: View {
    var body: some View {
        List {
            Section(L("Can back up")) {
                ForEach(BackupCategory.allCases) { c in
                    VStack(alignment: .leading) { Label(c.title, systemImage: c.symbol); Text(c.scopeNote).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section(L("Cannot back up (iOS restrictions)")) {
                Text(L("• A full iPhone/iPad system image (only Apple's iCloud Backup and Finder can do this)"))
                Text(L("• Private data of other apps (messages, app settings, game saves) — iOS sandbox"))
                Text(L("• Apple Music library songs (DRM; apps cannot export them)"))
                Text(L("• Health, Wallet, passwords and Keychain items"))
            }
            Section(L("Background")) {
                Text(L("Background backups use Apple's BackgroundTasks framework. iOS chooses when they run and stops them after a time limit; progress is kept and the next run continues incrementally."))
            }
        }
        .navigationTitle(L("Backup scope"))
    }
}

/// Developer-only diagnostics, kept apart from user settings.
struct DeveloperInfoView: View {
    @EnvironmentObject var env: AppEnvironment
    @Query private var jobs: [BackgroundJobRecord]

    var body: some View {
        List {
            Section("Build") {
                LabeledContent("Version", value: AppConfig.version)
                LabeledContent("Configuration", value: AppConfig.buildFlavor)
                LabeledContent("Bundle ID", value: AppConfig.bundleID)
            }
            Section("Integrations") {
                LabeledContent("Google OAuth client", value: AppConfig.isGoogleConfigured ? "configured" : "missing (Config/Secrets.xcconfig)")
                LabeledContent("Google redirect scheme", value: AppConfig.googleRedirectScheme ?? "—").font(.caption)
                LabeledContent("TeraBox host", value: AppConfig.teraBoxHost)
                LabeledContent("TeraBox adapter", value: "experimental (web endpoints)")
            }
            Section("Storage") {
                LabeledContent("Database", value: env.store.databaseURL?.lastPathComponent ?? "in-memory")
                LabeledContent("Encryption key", value: KeyManager.shared.hasKey ? "present (Keychain)" : "not created yet")
                LabeledContent("Background session", value: AppConfig.backgroundURLSessionID).font(.caption)
            }
            Section("Background tasks") {
                ForEach(jobs) { j in
                    VStack(alignment: .leading) {
                        Text(j.identifier).font(.caption.monospaced())
                        Text("scheduled \(Fmt.date(j.lastScheduledAt)) · earliest \(Fmt.date(j.earliestBeginDate))").font(.caption2)
                        Text("started \(Fmt.date(j.lastStartedAt)) · finished \(Fmt.date(j.lastFinishedAt)) · expired \(j.lastExpired ? "yes" : "no")").font(.caption2)
                        if let r = j.lastResult { Text(r).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }
}
