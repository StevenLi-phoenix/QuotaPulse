// Renders the shared widget / complication views to PNG at real widget sizes (docs + visual checks).
// Usage: swift run WidgetRender <outputDir>
import AppKit
import QuotaCore
import QuotaUI
import SwiftUI

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/screenshots")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let now = Date()
let snapshot = QuotaSnapshot(generatedAt: now.addingTimeInterval(-180), hubName: "Mac mini", providers: [
    ProviderSnapshot(id: .claude, fetchedAt: now, account: AccountInfo(plan: "Max 20x"), windows: [
        UsageWindow(id: "five_hour", title: "5-hour", utilization: 63, resetsAt: now.addingTimeInterval(1 * 3600 + 48 * 60), duration: 5 * 3600),
        UsageWindow(id: "seven_day", title: "Weekly", utilization: 41, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600), duration: 7 * 86400),
    ], forecasts: [
        "five_hour": Forecast(confidence: .high, rate: 22, projectedAtReset: 100, exhaustionAt: now.addingTimeInterval(100 * 60), paceDelta: 9, sampleCount: 20, span: 7200),
        "seven_day": Forecast(confidence: .medium, rate: 1.1, projectedAtReset: 72, paceDelta: -4, sampleCount: 40, span: 86400),
    ]),
    ProviderSnapshot(id: .codex, fetchedAt: now, account: AccountInfo(plan: "Plus"), windows: [
        UsageWindow(id: "primary", title: "5-hour", utilization: 18, resetsAt: now.addingTimeInterval(4 * 3600), duration: 5 * 3600),
        UsageWindow(id: "secondary", title: "Weekly", utilization: 76, resetsAt: now.addingTimeInterval(2 * 86400), duration: 7 * 86400),
    ], forecasts: ["secondary": Forecast(confidence: .medium, rate: 0.6, projectedAtReset: 92, paceDelta: 11, sampleCount: 30, span: 86400)]),
    ProviderSnapshot(id: .deepseek, fetchedAt: now, balance: Balance(currency: "CNY", total: 23.45, granted: 0, toppedUp: 23.45),
                     forecasts: ["balance": Forecast(confidence: .medium, rate: 1.2, daysRemaining: 19.5, ratePerHour: 0.05, hoursRemaining: 468, sampleCount: 12, span: 2 * 86400)]),
])
let sparks: [ProviderID: [Double]] = [
    .claude: [12, 15, 19, 22, 28, 30, 36, 41, 44, 50, 55, 58, 63],
    .codex: [60, 62, 64, 66, 67, 70, 71, 73, 74, 75, 76, 76, 76],
    .deepseek: [30, 29.4, 28.8, 28, 27.2, 26.5, 25.9, 25.1, 24.6, 24, 23.45],
]

@MainActor func render<V: View>(_ view: V, size: CGSize, name: String, scale: CGFloat = 2) {
    let content = view
        .padding(size.width < 200 ? 12 : 16)
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: content)
    renderer.scale = scale
    guard let cg = renderer.cgImage else { print("render failed: \(name)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: outDir.appendingPathComponent(name))
    print("wrote \(name) \(cg.width)x\(cg.height)")
}

let focus = WidgetViews.focus(snapshot, preferred: nil)
MainActor.assumeIsolated {
    render(WidgetSmallView(provider: focus, generatedAt: snapshot.generatedAt), size: CGSize(width: 170, height: 170), name: "widget-small.png")
    render(WidgetMediumView(snapshot: snapshot), size: CGSize(width: 364, height: 170), name: "widget-medium.png")
    render(WidgetLargeView(snapshot: snapshot, sparklines: sparks), size: CGSize(width: 364, height: 382), name: "widget-large.png")
    render(AccessoryCircularView(provider: focus), size: CGSize(width: 76, height: 76), name: "complication-circular.png")
    render(AccessoryRectangularView(snapshot: snapshot), size: CGSize(width: 180, height: 76), name: "complication-rectangular.png")
    render(ProviderCard(snapshot: snapshot.providers[0], sparkline: sparks[.claude]!, style: .full, now: now), size: CGSize(width: 380, height: 250), name: "card-claude.png")
}

// The main window's overview grid (MasonryLayout) at a two-column window width, for layout checks.
// `QP_SNAPSHOT=<path/to/snapshot.json>` draws a real snapshot instead (sparklines from the `samples.json` beside it).
MainActor.assumeIsolated {
    var snap = snapshot, at = now, lines = sparks
    if let path = ProcessInfo.processInfo.environment["QP_SNAPSHOT"] {
        let url = URL(fileURLWithPath: path)
        snap = try! JSON.decoder.decode(QuotaSnapshot.self, from: Data(contentsOf: url))
        at = snap.generatedAt
        let samplesURL = url.deletingLastPathComponent().appendingPathComponent("samples.json")
        let samples = (try? JSON.decoder.decode([Sample].self, from: Data(contentsOf: samplesURL))) ?? []
        lines = Derive.sparklines(samples: samples.filter { $0.at >= at.addingTimeInterval(-86400) }, snapshot: snap)
    }
    let grid = MasonryLayout(minColumnWidth: 340, maxColumnWidth: 520, spacing: 14) {
        ForEach(snap.providers) { p in ProviderCard(snapshot: p, sparkline: lines[p.id] ?? [], style: .full, now: at) }
    }
    .padding(20)
    .frame(width: 900, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.colorScheme, .dark)
    let r = ImageRenderer(content: grid)
    r.scale = 2
    if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
        try! png.write(to: outDir.appendingPathComponent("overview.png"))
        print("wrote overview.png \(cg.width)x\(cg.height)")
    }
}

// The menu-bar dropdown body (opaque background, as in MacOS/App/MenuPanelView.swift) in light and dark, for contrast checks.
MainActor.assumeIsolated {
    let groups = MenuSummary.groups(for: snapshot, now: now)
    for scheme in [ColorScheme.light, .dark] {
        let panel = VStack(alignment: .leading, spacing: 10) { ForEach(groups) { MenuGroupView(group: $0) } }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(width: 340, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let r = ImageRenderer(content: panel)
        r.scale = 2
        if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try! png.write(to: outDir.appendingPathComponent("menu-panel-\(scheme == .light ? "light" : "dark").png"))
            print("wrote menu-panel-\(scheme == .light ? "light" : "dark").png")
        }
    }
}
