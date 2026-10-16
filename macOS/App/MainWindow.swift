import SwiftUI
import QuotaCore
import QuotaUI

struct MainWindow: View {
    static let id = "main"
    @Environment(AppModel.self) private var model
    @State private var section: Section = .overview

    enum Section: String, CaseIterable, Identifiable {
        case overview, history, providers, hub, alerts, general
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: L("Overview")
            case .history: L("History")
            case .providers: L("Providers")
            case .hub: L("Hub & Devices")
            case .alerts: L("Alerts")
            case .general: L("General")
            }
        }
        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .history: "chart.xyaxis.line"
            case .providers: "key.horizontal"
            case .hub: "antenna.radiowaves.left.and.right"
            case .alerts: "bell.badge"
            case .general: "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch section {
                case .overview: OverviewPage()
                case .history: HistoryPage()
                case .providers: ProvidersPage()
                case .hub: HubPage()
                case .alerts: AlertsPage()
                case .general: GeneralPage()
                }
            }
            .navigationTitle(section.title)
            .onChange(of: model.requestedSection, initial: true) { _, new in
                if let new, let s = Section(rawValue: new) { section = s }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await model.refreshNow() }
                    } label: { Label(L("Refresh now"), systemImage: "arrow.clockwise") }
                        .disabled(model.isRefreshing)
                }
            }
        }
    }
}

// MARK: - Overview

struct OverviewPage: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 340, maximum: 520), spacing: 14, alignment: .top)]

    var body: some View {
        @Bindable var model = model
        let now = model.ticker.now
        ScrollView {
            if model.showsMenuBarTip {
                MenuBarTip(onDismiss: { model.showsMenuBarTip = false })
                    .padding(.horizontal, 20).padding(.top, 16)
            }
            if model.snapshot.providers.isEmpty {
                EmptyStateView(title: L("Nothing to show yet"), message: L("Enable a provider in Settings or wait for the first refresh."))
                    .padding(40)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(model.snapshot.providers) { p in
                        ProviderCard(snapshot: p, sparkline: model.sparklines[p.id] ?? [], style: .full, now: now)
                    }
                }
                .padding(20)
                .animation(QPDesign.spring, value: model.snapshot.providers.map(\.id))
            }
        }
    }
}

/// "I live in the menu bar" — menu-bar-only apps are easy to lose on first launch.
struct MenuBarTip: View {
    var onDismiss: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: MenuBarIcon.ring(percent: 37, hasData: true, refreshing: false))
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(L("QuotaPulse lives in the menu bar")).font(.headline)
                Text(L("Look for the small ring and percentage at the top right of your screen ↗. Click it for the quick panel; this window has history, settings and pairing. You can also show a Dock icon under General."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(L("Show in Dock"), isOn: Binding(get: { model.showInDock }, set: { model.showInDock = $0 })).toggleStyle(.switch).controlSize(.small)
            Button { onDismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: QPDesign.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: QPDesign.cardRadius, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
    }
}

// MARK: - History

struct HistoryPage: View {
    @Environment(AppModel.self) private var model
    @State private var provider: ProviderID = .claude
    @State private var rangeHours: Double = 24
    @State private var samples: [Sample] = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker(L("Provider"), selection: $provider) {
                    ForEach(model.settings.enabledProviders) { Text($0.displayName).tag($0) }
                }
                .frame(maxWidth: 220)
                Picker(L("Range"), selection: $rangeHours) {
                    Text(L("6 h")).tag(6.0)
                    Text(L("24 h")).tag(24.0)
                    Text(L("7 d")).tag(24.0 * 7)
                    Text(L("30 d")).tag(24.0 * 30)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            HistoryChart(samples: samples, provider: provider,
                         windows: model.snapshot.provider(provider)?.windows ?? [],
                         range: rangeHours * 3600, now: model.ticker.now)
                .padding(16)
                .background(QPDesign.cardBackground, in: RoundedRectangle(cornerRadius: QPDesign.cardRadius, style: .continuous))
            if let p = model.snapshot.provider(provider) {
                ForecastTable(provider: p)
            }
            Spacer()
        }
        .padding(20)
        .task(id: "\(provider.rawValue)-\(rangeHours)-\(model.lastRefreshAt?.timeIntervalSince1970 ?? 0)") {
            loading = true
            samples = await model.history(for: provider, hours: rangeHours)
            loading = false
        }
        .onAppear {
            if !model.settings.isEnabled(provider), let first = model.settings.enabledProviders.first { provider = first }
        }
    }
}

struct ForecastTable: View {
    var provider: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Forecast")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text(L("Window")).foregroundStyle(.secondary)
                    Text(L("Used")).foregroundStyle(.secondary)
                    Text(L("Burn rate")).foregroundStyle(.secondary)
                    Text(L("At reset")).foregroundStyle(.secondary)
                    Text(L("Confidence")).foregroundStyle(.secondary)
                }
                .font(.caption)
                ForEach(provider.displayWindows) { w in
                    let f = provider.forecasts[w.id]
                    GridRow {
                        Text(w.title).foregroundStyle(w.isReported ? .primary : .tertiary)
                        Text(w.isReported ? QuotaFormat.percent(w.utilization) : L("n/a")).monospacedDigit()
                        Text(f.map { QuotaFormat.rate($0.rate) } ?? "—").monospacedDigit()
                        Text(f?.projectedAtReset.map { QuotaFormat.percent($0) } ?? "—").monospacedDigit()
                        Text(confidence(f))
                    }
                    .font(.callout)
                }
                if let b = provider.balance {
                    let f = provider.forecasts[Sample.balanceWindowID]
                    GridRow {
                        Text(L("Balance"))
                        Text(b.formatted).monospacedDigit()
                        Text(f.map { "\(QuotaFormat.money($0.rate, symbol: b.symbol))/d" } ?? "—").monospacedDigit()
                        Text(f?.daysRemaining.map { String(localized: "\(Int($0.rounded())) days") } ?? "—")
                        Text(confidence(f))
                    }
                    .font(.callout)
                }
            }
        }
        .padding(16)
        .background(QPDesign.cardBackground, in: RoundedRectangle(cornerRadius: QPDesign.cardRadius, style: .continuous))
    }

    private func confidence(_ f: Forecast?) -> String {
        switch f?.confidence ?? .insufficient {
        case .insufficient: L("Collecting…")
        case .low: L("Low")
        case .medium: L("Medium")
        case .high: L("High")
        }
    }
}
