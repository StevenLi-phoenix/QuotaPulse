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

    var body: some View {
        NavigationStack {
            Group {
                if model.pairing == nil {
                    PairView()
                } else {
                    HomeView()
                }
            }
        }
        .tint(Color(hex: 0xD97757))
    }
}
