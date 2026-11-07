import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background task identifiers must be registered before launch completes.
        BackupScheduler.shared.register()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == AppConfig.backgroundURLSessionID else { completionHandler(); return }
        BackgroundTransferService.shared.systemCompletionHandler = completionHandler
        _ = BackgroundTransferService.shared.session // reconnect to the session so events are delivered
    }
}

@main
struct iCloudIPAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let env = AppEnvironment(inMemory: AppConfig.isRunningTests)
        _env = StateObject(wrappedValue: env)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .environmentObject(env.settings)
                .environmentObject(env.lock)
                .environmentObject(env.accounts)
                .environmentObject(env.transfers)
                .environmentObject(env.backup)
                .environmentObject(env.restore)
                .environmentObject(env.indexer)
                .environmentObject(env.sync)
                .modelContainer(env.store.container)
                .task { if !AppConfig.isRunningTests { env.onLaunch() } }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: env.lock.didEnterBackground()
            case .active:
                env.lock.willEnterForeground()
                env.onBecameActive()
            default: break
            }
        }
    }
}
