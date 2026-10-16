import BackgroundTasks
import QuotaCore
import QuotaUI
import SwiftUI
import WidgetKit

@main
struct QuotaPulseiOSApp: App {
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

struct RootView: View {
    @Environment(ClientModel.self) private var model
    @State private var path = NavigationPath()
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.pairing == nil {
                    PairView()
                } else {
                    HomeView()
                }
            }
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
