import SwiftUI
import QuotaCore
import QuotaUI

@main
struct QuotaPulseApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("QuotaPulse", id: MainWindow.id) {
            MainWindow()
                .environment(model)
                .frame(minWidth: 820, minHeight: 560)
                .onOpenURL { url in handle(url) }
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: ["open", "main", "*"])

        // Same content as the menu-bar dropdown, in a plain window (used for screenshots / docs).
        Window("QuotaPulse Panel", id: "panel") {
            MenuPanelView().environment(model)
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["panel"])
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(L("Refresh now")) { Task { await model.refreshNow() } }.keyboardShortcut("r")
            }
        }
    }
}

/// Menu bar glyph: a tiny ring for the most constrained window plus its percentage.
extension QuotaPulseApp {
    /// `quotapulse://open` shows the main window; `quotapulse://panel` the dropdown preview.
    func handle(_ url: URL) {
        guard url.scheme == "quotapulse" else { return }
        openWindow(id: url.host == "panel" ? "panel" : MainWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        let focus = model.snapshot.mostConstrained
        let percent = focus?.window.utilization
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
        .accessibilityLabel(Text(focus.map { "\($0.provider.id.displayName) \(QuotaFormat.percent($0.window.utilization))" } ?? "QuotaPulse"))
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
