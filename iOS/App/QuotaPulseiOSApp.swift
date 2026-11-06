import BackgroundTasks
import QuotaCore
import QuotaUI
import SwiftUI
import WidgetKit

@main
struct QuotaPulseiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ClientModel()
    @Environment(\.scenePhase) private var phase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: ClientModel.refreshTaskID, using: nil) { task in
            ClientModel.handleBackgroundRefresh(task as! BGAppRefreshTask)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in model.handle(url: url) }
        }
        .onChange(of: phase) { _, new in
            if new == .active { Task { await model.refresh(reason: "foreground") } }
            if new == .background { model.scheduleBackgroundRefresh() }
        }
    }
}

/// Registers for the silent pushes iCloud sends when the Mac publishes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        ClientModel.current?.logger.info("cloud", "push.registered")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        ClientModel.current?.logger.error("cloud", "push.registration.failed", ["error": error.localizedDescription])
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard CloudKitRecordStore.isChangeNotification(userInfo), let model = ClientModel.current else { return .noData }
        model.logger.info("cloud", "push.received")
        return await model.refresh(reason: "push") ? .newData : .failed
    }
}

struct RootView: View {
    @Environment(ClientModel.self) private var model
    @State private var path = NavigationPath()
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            HomeView()
        }
        .tint(Color(hex: 0xD97757))
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .onAppear {
            // Automation hook (simulator / screenshots): QUOTAPULSE_START_ROUTE=provider/claude | settings
            if let route = ProcessInfo.processInfo.environment["QUOTAPULSE_START_ROUTE"] {
                let parts = route.split(separator: "/")
                if parts.count == 2, parts[0] == "provider", let id = ProviderID(rawValue: String(parts[1])) {
                    path.append(id)
                } else if route == "settings" {
                    showSettings = true
                }
            }
        }
    }
}
