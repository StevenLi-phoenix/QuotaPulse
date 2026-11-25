import SwiftUI
import QuotaCore
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Widget / complication content shared by macOS, iOS and watchOS extensions.
/// Views are family-agnostic; each extension picks the right one for the family.
public enum WidgetViews {
    /// Picks what a single-provider surface should show.
    public static func focus(_ snapshot: QuotaSnapshot, preferred: ProviderID?) -> ProviderSnapshot? {
        if let preferred, let p = snapshot.provider(preferred) { return p }
        return snapshot.mostConstrained?.provider ?? snapshot.providers.first
    }
}

/// Live-ticking countdown for < 24 h, static "Nd Nh" beyond that (a 47:59:59 timer reads badly);
/// "Fresh" for a rolling window whose reset passed.
public struct ResetCountdown: View {
    public var window: UsageWindow
    public init(_ window: UsageWindow) { self.window = window }
    public var body: some View {
        switch window.phase() {
        case let .active(r) where r.timeIntervalSinceNow < 24 * 3600: Text(r, style: .timer)
        case let .active(r): Text(QuotaFormat.countdown(to: r))
        case .awaitingFirstUse: Text(L("Fresh"))
        case .unknown: Text("—")
        }
    }
}

public struct WidgetSmallView: View {
    public var provider: ProviderSnapshot?
    public var generatedAt: Date

    public init(provider: ProviderSnapshot?, generatedAt: Date) {
        self.provider = provider
        self.generatedAt = generatedAt
    }

    public var body: some View {
        if let p = provider {
            let primary = p.primaryWindow
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProviderGlyph(p, size: 20)
                    // The name wins over the plan badge on narrow (systemSmall) widgets.
                    Text(p.localizedName).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    if let plan = p.account?.plan { PlanBadge(plan).layoutPriority(-1) }
                }
                Spacer(minLength: 2)
                HStack(alignment: .center, spacing: 10) {
                    if let w = primary {
                        UsageRing(percent: w.currentUtilization(), color: p.color, lineWidth: 6, showsLabel: false).frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(QuotaFormat.percent(w.currentUtilization())).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
                            Text(w.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            ResetCountdown(w).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else if let b = p.balance {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.formatted).font(.system(b.isCredits ? .headline : .title2, design: .rounded).weight(.bold)).monospacedDigit().minimumScaleFactor(0.6)
                            Text(L("Balance")).font(.caption2).foregroundStyle(.secondary)
                            if let h = p.forecasts[Sample.balanceWindowID]?.hoursRemaining {
                                Text(h < QuotaFormat.balanceHoursLimit
                                     ? String(localized: "~\(QuotaFormat.wholeHours(h))h left", bundle: .module)
                                     : String(localized: "~\(QuotaFormat.wholeDays(h / 24))d left", bundle: .module))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 2)
                if let w = primary, let f = p.forecasts[w.id], f.willExhaustBeforeReset, let ex = f.exhaustionAt {
                    Label(String(localized: "Out at \(Present.resetClock(ex))", bundle: .module), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(UsageLevel.critical.color).lineLimit(1)
                } else if p.status.isError {
                    Text(Present.statusTitle(p.status)).font(.caption2).foregroundStyle(UsageLevel.hot.color).lineLimit(1)
                } else if let w = primary, let pace = Present.paceText(p.forecasts[w.id]) {
                    Text(pace.text).font(.caption2).foregroundStyle(pace.isOver ? UsageLevel.hot.color : .secondary).lineLimit(1)
                } else {
                    Text(Present.updatedText(generatedAt)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        } else {
            WidgetEmptyView()
        }
    }
}

public struct WidgetMediumView: View {
    public var snapshot: QuotaSnapshot

    public init(snapshot: QuotaSnapshot) { self.snapshot = snapshot }

    public var body: some View {
        let providers = snapshot.providers.filter { !$0.windows.isEmpty || $0.balance != nil }.prefix(4)
        if providers.isEmpty {
            WidgetEmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(providers)) { p in
                    HStack(spacing: 8) {
                        ProviderGlyph(p, size: 18)
                        Text(p.localizedName).font(.caption.weight(.semibold)).frame(width: 64, alignment: .leading).lineLimit(1)
                        if let b = p.balance, p.windows.isEmpty {
                            Text(b.formatted).font(.caption.monospacedDigit().weight(.semibold))
                            Spacer()
                            if let h = p.forecasts[Sample.balanceWindowID]?.hoursRemaining {
                                Text(h < QuotaFormat.balanceHoursLimit
                                     ? String(localized: "~\(QuotaFormat.wholeHours(h))h", bundle: .module)
                                     : String(localized: "~\(QuotaFormat.wholeDays(h / 24))d", bundle: .module))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(p.displayWindows.prefix(2)) { w in
                                VStack(alignment: .leading, spacing: 2) {
                                    if w.isReported {
                                        UsageBar(percent: w.currentUtilization(), color: p.color, height: 5)
                                    } else {
                                        Capsule().fill(.quaternary.opacity(0.5)).frame(height: 5)
                                    }
                                    HStack {
                                        Text(w.title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                        Spacer(minLength: 2)
                                        Text(w.isReported ? QuotaFormat.percent(w.currentUtilization()) : Present.resetShort(w))
                                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(w.isReported ? .primary : .tertiary)
                                    }
                                }
                            }
                        }
                        if p.status.isError { Image(systemName: "exclamationmark.circle.fill").font(.caption2).foregroundStyle(UsageLevel.hot.color) }
                    }
                    if providers.count <= 3, let w = p.primaryWindow {
                        HStack(spacing: 4) {
                            Text(Present.resetText(w))
                            if let pace = Present.paceText(p.forecasts[w.id]) {
                                Text("·").foregroundStyle(.quaternary)
                                Text(pace.text).foregroundStyle(pace.isOver ? UsageLevel.hot.color : .secondary)
                            }
                            if let f = p.forecasts[w.id], let ex = f.exhaustionAt {
                                Text("·").foregroundStyle(.quaternary)
                                Text(String(localized: "Out at \(Present.resetClock(ex))", bundle: .module)).foregroundStyle(UsageLevel.critical.color)
                            }
                        }
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.leading, 26)
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text(Present.updatedText(snapshot.generatedAt)).font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }
}

public struct WidgetLargeView: View {
    public var snapshot: QuotaSnapshot
    public var sparklines: [ProviderID: [Double]]

    public init(snapshot: QuotaSnapshot, sparklines: [ProviderID: [Double]] = [:]) {
        self.snapshot = snapshot
        self.sparklines = sparklines
    }

    public var body: some View {
        let providers = snapshot.providers.filter { !$0.windows.isEmpty || $0.balance != nil }.prefix(4)
        if providers.isEmpty {
            WidgetEmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(providers)) { p in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProviderGlyph(p, size: 20)
                            Text(p.localizedName).font(.subheadline.weight(.semibold))
                            if let plan = p.account?.plan { PlanBadge(plan) }
                            Spacer()
                            if let s = sparklines[p.id], s.count >= 2 { Sparkline(values: s, color: p.color).frame(width: 70, height: 18) }
                            StatusBadge(p.status)
                        }
                        ForEach(p.displayWindows.prefix(2)) { w in
                            WindowRow(window: w, forecast: p.forecasts[w.id], color: p.color, compact: true)
                        }
                        if let b = p.balance, p.windows.isEmpty {
                            BalanceRow(balance: b, forecast: p.forecasts[Sample.balanceWindowID], compact: true)
                        }
                    }
                    if p.id != providers.last?.id { Divider() }
                }
                Spacer(minLength: 0)
                Text(Present.updatedText(snapshot.generatedAt)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

public struct WidgetEmptyView: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.title2).foregroundStyle(.secondary)
            Text(L("Open QuotaPulse to start")).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

// MARK: - Accessory / complications

public struct AccessoryCircularView: View {
    public var provider: ProviderSnapshot?
    public init(provider: ProviderSnapshot?) { self.provider = provider }

    public var body: some View {
        if let p = provider, let w = p.primaryWindow {
            Gauge(value: min(1, w.currentUtilization() / 100)) {
                Image(systemName: p.symbol)
            } currentValueLabel: {
                Text("\(Int(w.currentUtilization().rounded()))").font(.system(.body, design: .rounded).weight(.semibold))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(Gradient(colors: [UsageLevel.calm.color, UsageLevel.warm.color, UsageLevel.critical.color]))
        } else if let p = provider, let b = p.balance {
            Gauge(value: 1) { Image(systemName: p.symbol) } currentValueLabel: {
                Text(b.isCredits ? "\(Int(b.total / 1000))k" : QuotaFormat.money(b.total, symbol: b.symbol)).font(.system(.caption2, design: .rounded).weight(.semibold)).minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(p.color)
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
    }
}

public struct AccessoryRectangularView: View {
    public var snapshot: QuotaSnapshot
    public var preferred: ProviderID?
    public init(snapshot: QuotaSnapshot, preferred: ProviderID? = nil) { self.snapshot = snapshot; self.preferred = preferred }

    public var body: some View {
        let shown = snapshot.providers.filter { !$0.windows.isEmpty || $0.balance != nil }.prefix(3)
        if shown.isEmpty {
            Text(L("Open QuotaPulse to start")).font(.caption2)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown)) { p in
                    HStack(spacing: 4) {
                        Image(systemName: p.symbol).font(.caption2)
                        Text(p.localizedName).font(.caption2.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 2)
                        if let w = p.primaryWindow {
                            Text(QuotaFormat.percent(w.currentUtilization())).font(.caption2.monospacedDigit().weight(.semibold))
                            ResetCountdown(w).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                        } else if let b = p.balance {
                            Text(b.formatted).font(.caption2.monospacedDigit().weight(.semibold)).minimumScaleFactor(0.6)
                        }
                    }
                }
            }
        }
    }
}

public struct AccessoryInlineView: View {
    public var provider: ProviderSnapshot?
    public init(provider: ProviderSnapshot?) { self.provider = provider }

    public var body: some View {
        if let p = provider, let w = p.primaryWindow {
            Text("\(Image(systemName: p.symbol)) \(p.localizedName) \(QuotaFormat.percent(w.currentUtilization())) · \(Present.resetShort(w))")
        } else if let p = provider, let b = p.balance {
            Text("\(Image(systemName: p.symbol)) \(p.localizedName) \(b.formatted)")
        } else {
            Text("QuotaPulse")
        }
    }
}

public struct AccessoryCornerView: View {
    public var provider: ProviderSnapshot?
    public init(provider: ProviderSnapshot?) { self.provider = provider }

    public var body: some View {
        if let p = provider, let w = p.primaryWindow {
            Text("\(Int(w.currentUtilization().rounded()))%")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .widgetCurvedLabel { Text(p.localizedName) }
                .widgetCurvedGauge(value: min(1, w.currentUtilization() / 100))
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
    }
}

private extension View {
    @ViewBuilder func widgetCurvedLabel<L: View>(@ViewBuilder _ label: () -> L) -> some View {
        #if os(watchOS)
        self.widgetLabel(label: label)
        #else
        self
        #endif
    }

    @ViewBuilder func widgetCurvedGauge(value: Double) -> some View {
        #if os(watchOS)
        self.widgetLabel {
            Gauge(value: value) { EmptyView() }.tint(Gradient(colors: [UsageLevel.calm.color, UsageLevel.warm.color, UsageLevel.critical.color]))
        }
        #else
        self
        #endif
    }
}
