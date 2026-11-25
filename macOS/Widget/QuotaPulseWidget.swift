import AppIntents
import QuotaCore
import QuotaUI
import SwiftUI
import WidgetKit

// MARK: - Shared snapshot access

enum WidgetData {
    static func load() -> QuotaSnapshot {
        SnapshotStore(url: DataLocation.standard().snapshotURL).load() ?? .empty
    }

    static func sparklines(for snapshot: QuotaSnapshot) -> [ProviderID: [Double]] {
        // Cheap read of the sample file; downsampled so the widget stays fast.
        guard let data = try? Data(contentsOf: DataLocation.standard().samplesURL),
              let samples = try? JSON.decoder.decode([Sample].self, from: data) else { return [:] }
        let since = Date().addingTimeInterval(-24 * 3600)
        return Derive.sparklines(samples: samples.filter { $0.at >= since }, snapshot: snapshot)
    }
}

// MARK: - Configuration intent (pick a provider for the small widget)

/// Names come from the shared snapshot, so a provider added after this build can be picked too.
struct ProviderEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
    static let defaultQuery = ProviderQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(id: String, snapshot: QuotaSnapshot) {
        self.id = id
        self.name = snapshot.info(ProviderID(id)).localizedName
    }
}

struct ProviderQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProviderEntity] {
        let snap = WidgetData.load()
        return identifiers.map { ProviderEntity(id: $0, snapshot: snap) }
    }
    func suggestedEntities() async throws -> [ProviderEntity] {
        let snap = WidgetData.load()
        let ids = Set(snap.providers.map(\.id)).union(ProviderID.legacy).sorted(by: ProviderID.displayOrder)
        return ids.map { ProviderEntity(id: $0.rawValue, snapshot: snap) }
    }
    func defaultResult() async -> ProviderEntity? { nil }
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose provider"
    static let description = IntentDescription("Which provider the widget focuses on. Leave empty for the most constrained one.")

    @Parameter(title: "Provider") var provider: ProviderEntity?
}

// MARK: - Timeline

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: QuotaSnapshot
    let preferred: ProviderID?
    let sparklines: [ProviderID: [Double]]
}

struct QuotaTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: .now, snapshot: .placeholder, preferred: nil, sparklines: [:])
    }

    func snapshot(for configuration: SelectProviderIntent, in context: Context) async -> QuotaEntry {
        let snap = WidgetData.load()
        return QuotaEntry(date: .now, snapshot: snap.providers.isEmpty ? .placeholder : snap,
                          preferred: configuration.provider.flatMap { ProviderID(validating: $0.id) }, sparklines: [:])
    }

    func timeline(for configuration: SelectProviderIntent, in context: Context) async -> Timeline<QuotaEntry> {
        let snap = WidgetData.load()
        let spark = context.family == .systemLarge ? WidgetData.sparklines(for: snap) : [:]
        let entry = QuotaEntry(date: .now, snapshot: snap, preferred: configuration.provider.flatMap { ProviderID(validating: $0.id) }, sparklines: spark)
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60)))
    }
}

struct QuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: WidgetSmallView(provider: WidgetViews.focus(entry.snapshot, preferred: entry.preferred), generatedAt: entry.snapshot.generatedAt)
            case .systemLarge, .systemExtraLarge: WidgetLargeView(snapshot: entry.snapshot, sparklines: entry.sparklines)
            default: WidgetMediumView(snapshot: entry.snapshot)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "quotapulse://open"))
    }
}

struct QuotaPulseWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "app.lishuyu.quotapulse.widget", intent: SelectProviderIntent.self, provider: QuotaTimelineProvider()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("QuotaPulse")
        .description("Remaining AI quota and burn-rate forecasts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct QuotaPulseWidgetBundle: WidgetBundle {
    var body: some Widget { QuotaPulseWidget() }
}

extension QuotaSnapshot {
    /// Placeholder content for the widget gallery.
    static var placeholder: QuotaSnapshot {
        let now = Date()
        return QuotaSnapshot(generatedAt: now, hubName: "Mac", providers: [
            ProviderSnapshot(id: .claude, fetchedAt: now, account: AccountInfo(plan: "Max"), windows: [
                UsageWindow(id: "five_hour", title: "5-hour", utilization: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60), duration: 5 * 3600),
                UsageWindow(id: "seven_day", title: "Weekly", utilization: 61, resetsAt: now.addingTimeInterval(3 * 86400), duration: 7 * 86400),
            ], forecasts: ["five_hour": Forecast(confidence: .medium, rate: 9, projectedAtReset: 62, paceDelta: -8, sampleCount: 8, span: 3600)]),
            ProviderSnapshot(id: .codex, fetchedAt: now, account: AccountInfo(plan: "Plus"), windows: [
                UsageWindow(id: "primary", title: "5-hour", utilization: 18, resetsAt: now.addingTimeInterval(4 * 3600), duration: 5 * 3600),
                UsageWindow(id: "secondary", title: "Weekly", utilization: 73, resetsAt: now.addingTimeInterval(2 * 86400), duration: 7 * 86400),
            ]),
            ProviderSnapshot(id: .deepseek, fetchedAt: now, balance: Balance(currency: "CNY", total: 23.45), forecasts: ["balance": Forecast(confidence: .medium, rate: 1.2, daysRemaining: 19.5, ratePerHour: 0.05, hoursRemaining: 468, sampleCount: 10, span: 86400)]),
        ])
    }
}
