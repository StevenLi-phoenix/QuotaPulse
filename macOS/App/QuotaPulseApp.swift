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

/// Menu bar glyph: a tiny ring for the most constrained window plus its percentage.
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

struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        let focus = model.snapshot.mostConstrained
        let percent = focus?.window.currentUtilization(now: model.ticker.now)
        HStack(spacing: 4) {
            if model.settings.menuBarStyle != "percent" {
                Image(nsImage: MenuBarIcon.ring(percent: percent ?? 0, hasData: percent != nil, refreshing: model.isRefreshing))
            }
            if model.settings.menuBarStyle != "icon", let percent {
                Text(QuotaFormat.percent(percent)).monospacedDigit()
            } else if model.settings.menuBarStyle == "percent" {
                Text("—")
            }
        }
        .accessibilityLabel(Text(focus.map { "\($0.provider.localizedName) \(QuotaFormat.percent($0.window.currentUtilization()))" } ?? "QuotaPulse"))
    }
}

enum MenuBarIcon {
    /// Template image so it adapts to light/dark menu bars.
    static func ring(percent: Double, hasData: Bool, refreshing: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6.5
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(hasData ? 0.28 : 0.5).setStroke()
            track.stroke()
            if hasData {
                let sweep = max(2, 360 * CGFloat(min(1, percent / 100)))
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                arc.lineWidth = 2.6
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            if refreshing {
                let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
                NSColor.black.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
