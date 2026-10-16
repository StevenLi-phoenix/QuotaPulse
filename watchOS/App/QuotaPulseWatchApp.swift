import QuotaCore
import QuotaUI
import SwiftUI

@main
struct QuotaPulseWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            NavigationStack { WatchHomeView() }
                .environment(model)
        }
        .onChange(of: phase) { _, new in if new == .active { Task { await model.refresh() } } }
    }
}
