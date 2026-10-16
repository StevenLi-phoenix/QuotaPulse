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

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let focus = WidgetViews.focus(entry.snapshot, preferred: nil)
        Group {
            switch family {
            case .systemSmall: WidgetSmallView(provider: focus, generatedAt: entry.snapshot.generatedAt)
            case .systemMedium: WidgetMediumView(snapshot: entry.snapshot)
            case .systemLarge, .systemExtraLarge: WidgetLargeView(snapshot: entry.snapshot)
            case .accessoryCircular: AccessoryCircularView(provider: focus)
            case .accessoryRectangular: AccessoryRectangularView(snapshot: entry.snapshot)
            case .accessoryInline: AccessoryInlineView(provider: focus)
            default: WidgetMediumView(snapshot: entry.snapshot)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "quotapulse://open"))
    }
}

struct QuotaPulseiOSWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.lishuyu.quotapulse.ios.widget", provider: Provider()) { WidgetView(entry: $0) }
            .configurationDisplayName("QuotaPulse")
            .description("Remaining AI quota and burn-rate forecasts from your Mac.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct QuotaPulseiOSWidgetBundle: WidgetBundle {
    var body: some Widget { QuotaPulseiOSWidget() }
}

extension QuotaSnapshot {
    static var placeholder: QuotaSnapshot {
        let now = Date()
        return QuotaSnapshot(generatedAt: now, hubName: "Mac", providers: [
            ProviderSnapshot(id: .claude, fetchedAt: now, account: AccountInfo(plan: "Max"), windows: [
                UsageWindow(id: "five_hour", title: "5-hour", utilization: 42, resetsAt: now.addingTimeInterval(2 * 3600), duration: 5 * 3600),
                UsageWindow(id: "seven_day", title: "Weekly", utilization: 61, resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400),
            ]),
            ProviderSnapshot(id: .codex, fetchedAt: now, account: AccountInfo(plan: "Plus"), windows: [
                UsageWindow(id: "primary", title: "5-hour", utilization: 18, resetsAt: now.addingTimeInterval(4 * 3600), duration: 5 * 3600),
                UsageWindow(id: "secondary", title: "Weekly", utilization: 73, resetsAt: now.addingTimeInterval(2 * 86400), duration: 7 * 86400),
            ]),
        ])
    }
}
