import QuotaCore
import QuotaUI
import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: QuotaSnapshot
}

struct Provider: TimelineProvider {
    func load() -> QuotaSnapshot { SnapshotStore(url: DataLocation.standard().snapshotURL).load() ?? .empty }
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let s = load()
        completion(Entry(date: .now, snapshot: s.providers.isEmpty ? .placeholder : s))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, snapshot: load())], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let focus = WidgetViews.focus(entry.snapshot, preferred: nil)
        Group {
            switch family {
            case .accessoryCircular: AccessoryCircularView(provider: focus)
            case .accessoryCorner: AccessoryCornerView(provider: focus)
            case .accessoryRectangular: AccessoryRectangularView(snapshot: entry.snapshot)
            case .accessoryInline: AccessoryInlineView(provider: focus)
            default: AccessoryCircularView(provider: focus)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct QuotaPulseWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.lishuyu.quotapulse.watch.widget", provider: Provider()) { ComplicationView(entry: $0) }
            .configurationDisplayName("QuotaPulse")
            .description("AI quota at a glance.")
            .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct QuotaPulseWatchWidgetBundle: WidgetBundle {
    var body: some Widget { QuotaPulseWatchWidget() }
}

extension QuotaSnapshot {
    static var placeholder: QuotaSnapshot {
        let now = Date()
        return QuotaSnapshot(generatedAt: now, hubName: "Mac", providers: [
            ProviderSnapshot(id: .claude, fetchedAt: now, windows: [
                UsageWindow(id: "five_hour", title: "5-hour", utilization: 42, resetsAt: now.addingTimeInterval(2 * 3600), duration: 5 * 3600),
            ]),
            ProviderSnapshot(id: .codex, fetchedAt: now, windows: [
                UsageWindow(id: "primary", title: "5-hour", utilization: 18, resetsAt: now.addingTimeInterval(4 * 3600), duration: 5 * 3600),
            ]),
        ])
    }
}
