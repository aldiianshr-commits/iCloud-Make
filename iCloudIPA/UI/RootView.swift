import SwiftUI

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home, files, backup, accounts, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L("Home")
        case .files: return L("Files")
        case .backup: return L("Backup")
        case .accounts: return L("Cloud Accounts")
        case .settings: return L("Settings")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .files: return "folder"
        case .backup: return "arrow.triangle.2.circlepath.icloud"
        case .accounts: return "person.crop.circle.badge.checkmark"
        case .settings: return "gearshape"
        }
    }
}

/// Shared navigation state so Home's quick actions can switch tabs.
final class Router: ObservableObject {
    @Published var tab: AppTab = .home
    @Published var showRestore = false
    @Published var showUpload = false
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var lock: AppLockManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var router = Router()

    var body: some View {
        ZStack {
            Group {
                if sizeClass == .regular {
                    SidebarLayout()
                } else {
                    TabLayout()
                }
            }
            .environmentObject(router)
            .id(settings.language) // rebuild all strings when the in-app language changes
            if lock.isLocked {
                LockScreenView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
        .environment(\.locale, Localizer.shared.locale)
    }
}

struct TabLayout: View {
    @EnvironmentObject var router: Router

    var body: some View {
        TabView(selection: $router.tab) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack { screen(for: tab) }
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
    }
}

/// iPad: sidebar navigation.
struct SidebarLayout: View {
    @EnvironmentObject var router: Router

    var body: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: Binding<AppTab?>(get: { router.tab }, set: { if let t = $0 { router.tab = t } })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationTitle("iCloud IPA")
        } detail: {
            NavigationStack { screen(for: router.tab) }
                .id(router.tab)
        }
    }
}

@MainActor @ViewBuilder
func screen(for tab: AppTab) -> some View {
    switch tab {
    case .home: HomeView()
    case .files: FilesView()
    case .backup: BackupView()
    case .accounts: AccountsView()
    case .settings: SettingsView()
    }
}
