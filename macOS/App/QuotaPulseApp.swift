import SwiftUI
import QuotaCore
import QuotaUI

@main
struct QuotaPulseApp: App {
    @State private var model = AppModel()
    @State private var updater = Updater()
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environment(model)
                .environment(updater)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("QuotaPulse", id: MainWindow.id) {
            MainWindow()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 820, minHeight: 560)
                .onOpenURL { url in handle(url) }
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: ["open", "main", "*"])

        // Same content as the menu-bar dropdown, in a plain window (used for screenshots / docs).
        Window("QuotaPulse Panel", id: "panel") {
            MenuPanelView().environment(model).environment(updater)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["panel"])
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                if Updater.isEnabled {
                    Button(L("Check for Updates…")) { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                }
                Button(L("Refresh now")) { Task { await model.refreshNow() } }.keyboardShortcut("r")
            }
        }
    }
}

/// Opens the main window on first launch (menu-bar-only apps are easy to lose) and applies the Dock setting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        AppModel.applyActivationPolicy(showInDock: defaults.bool(forKey: "showInDock"))
        if !defaults.bool(forKey: "launched.before") {
            defaults.set(true, forKey: "launched.before")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSWorkspace.shared.open(URL(string: "quotapulse://open")!)
            }
        }
    }

    /// Clicking the Dock icon (when shown) or reopening from Finder brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSWorkspace.shared.open(URL(string: "quotapulse://open")!) }
        return true
    }
}

extension QuotaPulseApp {
    /// `quotapulse://open` shows the main window; `quotapulse://panel` the dropdown preview.
    func handle(_ url: URL) {
        guard url.scheme == "quotapulse" else { return }
        if let section = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "section" })?.value {
            model.requestedSection = section
        }
        openWindow(id: url.host == "panel" ? "panel" : MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The menu-bar item: one narrow bar per provider (`MenuBarImage`), no text. What each bar says is decided by `MenuBarStatus`.
struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        let status = MenuBarStatus.make(snapshot: model.snapshot, now: model.ticker.now,
                                        staleAfter: MenuBarStatus.staleAfter(pollInterval: model.settings.pollInterval))
        Image(nsImage: MenuBarImage.image(for: status))
            .help(status.tooltip)
            .accessibilityLabel(Text(status.accessibilityLabel))
            .onChange(of: status, initial: true) { _, new in
                QPLog.ui.debug("menu bar: \(new.logLine, privacy: .public)")
            }
    }
}
