import SwiftUI
import QuotaCore

// MARK: - Ring

public struct UsageRing: View {
    public var percent: Double
    public var color: Color?
    public var lineWidth: CGFloat
    public var showsLabel: Bool

    public init(percent: Double, color: Color? = nil, lineWidth: CGFloat = 6, showsLabel: Bool = true) {
        self.percent = percent
        self.color = color
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
    }

    public var body: some View {
        let tint = color ?? UsageLevel(percent: percent).color
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, percent / 100)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(QPDesign.spring, value: percent)
            if showsLabel {
                Text(QuotaFormat.percent(percent))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(lineWidth + 2)
                    .contentTransition(.numericText())
                    .animation(QPDesign.quick, value: percent)
            }
        }
        .accessibilityLabel(Text(QuotaFormat.percent(percent)))
    }
}

// MARK: - Bar

public struct UsageBar: View {
    public var percent: Double
    public var color: Color?
    public var height: CGFloat
    /// Optional second marker (e.g. projected-at-reset) drawn as a faint extension.
    public var projected: Double?

    public init(percent: Double, color: Color? = nil, height: CGFloat = 8, projected: Double? = nil) {
        self.percent = percent
        self.color = color
        self.height = height
        self.projected = projected
    }

    public var body: some View {
        let tint = color ?? UsageLevel(percent: percent).color
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                if let projected, projected > percent {
                    Capsule().fill(tint.opacity(0.32))
                        .frame(width: geo.size.width * CGFloat(min(1, projected / 100)))
                        .animation(QPDesign.spring, value: projected)
                }
                Capsule().fill(tint)
                    .frame(width: max(height, geo.size.width * CGFloat(min(1, percent / 100))))
                    .animation(QPDesign.spring, value: percent)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Sparkline

public struct Sparkline: View {
    public var values: [Double]
    public var color: Color
    public var maxValue: Double

    public init(values: [Double], color: Color, maxValue: Double = 100) {
        self.values = values
        self.color = color
        self.maxValue = maxValue
    }

    public var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                let top = max(maxValue, values.max() ?? maxValue)
                let pts = values.enumerated().map { i, v in
                    CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1),
                            y: geo.size.height * (1 - CGFloat(min(1, max(0, v / top)))))
                }
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                Rectangle().fill(.clear)
            }
        }
    }
}

// MARK: - Glyph & badges

public struct ProviderGlyph: View {
    public var provider: ProviderID
    public var size: CGFloat

    public init(_ provider: ProviderID, size: CGFloat = 28) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [provider.color, provider.color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: provider.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public struct StatusBadge: View {
    public var status: ProviderStatus

    public init(_ status: ProviderStatus) { self.status = status }

    private var tint: Color {
        switch status {
        case .ok: Color(hex: 0x34C759)
        case .notConfigured: .secondary
        case .rateLimited, .network: Color(hex: 0xFFB020)
        default: Color(hex: 0xFF3B30)
        }
    }

    public var body: some View {
        if status.isError {
            Text(Present.statusTitle(status))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(tint.opacity(0.16), in: Capsule())
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

public struct PlanBadge: View {
    public var text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.5)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Rows

public struct WindowRow: View {
    public var window: UsageWindow
    public var forecast: Forecast?
    public var color: Color?
    public var compact: Bool
    public var now: Date

    public init(window: UsageWindow, forecast: Forecast?, color: Color? = nil, compact: Bool = false, now: Date = Date()) {
        self.window = window
        self.forecast = forecast
        self.color = color
        self.compact = compact
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(compact ? .caption : .subheadline).fontWeight(.medium)
                Spacer(minLength: 4)
                Text(QuotaFormat.percent(window.utilization))
                    .font(.system(compact ? .caption : .subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(QPDesign.quick, value: window.utilization)
                    .foregroundStyle(UsageLevel(percent: window.utilization).color)
            }
            UsageBar(percent: window.utilization, color: color, height: compact ? 5 : 7, projected: forecast?.projectedAtReset)
            HStack(spacing: 6) {
                Text(Present.resetText(window, now: now))
                if let pace = Present.paceText(forecast) {
                    Text("·").foregroundStyle(.quaternary)
                    Text(pace.text).foregroundStyle(pace.isOver ? UsageLevel.hot.color : .secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if !compact, let text = Present.forecastText(window: window, forecast: forecast, now: now) {
                let alarming = forecast?.willExhaustBeforeReset == true && forecast?.confidence != .low
                Label(text, systemImage: alarming ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis")
                    .font(.caption2)
                    .foregroundStyle(alarming ? UsageLevel.critical.color : (forecast?.willExhaustBeforeReset == true ? UsageLevel.hot.color : .secondary))
                    .lineLimit(2)
            }
        }
    }
}

public struct BalanceRow: View {
    public var balance: Balance
    public var forecast: Forecast?
    public var compact: Bool

    public init(balance: Balance, forecast: Forecast?, compact: Bool = false) {
        self.balance = balance
        self.forecast = forecast
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Balance")).font(compact ? .caption : .subheadline).fontWeight(.medium)
                Spacer()
                Text(QuotaFormat.money(balance.total, symbol: balance.symbol))
                    .font(.system(compact ? .subheadline : .title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(balance.isAvailable && balance.total > 0 ? .primary : UsageLevel.critical.color)
            }
            if !balance.isAvailable {
                Text(L("Balance unavailable for API calls")).font(.caption2).foregroundStyle(UsageLevel.critical.color)
            } else if let t = Present.balanceForecastText(balance: balance, forecast: forecast) {
                Label(t, systemImage: "chart.line.downtrend.xyaxis").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if !compact, let g = balance.granted, let tu = balance.toppedUp, g > 0 {
                Text(String(localized: "Paid \(QuotaFormat.money(tu, symbol: balance.symbol)) · Granted \(QuotaFormat.money(g, symbol: balance.symbol))", bundle: .module))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Provider card

public struct ProviderCard: View {
    public enum Style { case menu, full, compact }

    public var snapshot: ProviderSnapshot
    public var sparkline: [Double]
    public var style: Style
    public var now: Date

    public init(snapshot: ProviderSnapshot, sparkline: [Double] = [], style: Style = .full, now: Date = Date()) {
        self.snapshot = snapshot
        self.sparkline = sparkline
        self.style = style
        self.now = now
    }

    private var compact: Bool { style != .full }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            header
            if snapshot.status.isError && snapshot.windows.isEmpty && snapshot.balance == nil {
                errorBody
            } else {
                ForEach(snapshot.windows) { w in
                    WindowRow(window: w, forecast: snapshot.forecasts[w.id], color: snapshot.id.color, compact: compact, now: now)
                }
                if let b = snapshot.balance {
                    BalanceRow(balance: b, forecast: snapshot.forecasts[Sample.balanceWindowID], compact: compact)
                }
                if let e = snapshot.extraUsage, e.isEnabled, let used = e.usedCredits, let limit = e.monthlyLimit, limit > 0 {
                    HStack {
                        Text(L("Extra usage")).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(QuotaFormat.money(used, symbol: "$")) / \(QuotaFormat.money(limit, symbol: "$"))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if snapshot.status.isError {
                    Label(snapshot.status.message, systemImage: "exclamationmark.circle")
                        .font(.caption2).foregroundStyle(UsageLevel.hot.color).lineLimit(2)
                }
            }
        }
        .padding(compact ? 12 : 16)
        .background(QPDesign.cardBackground, in: RoundedRectangle(cornerRadius: QPDesign.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: QPDesign.cardRadius, style: .continuous).strokeBorder(snapshot.id.color.opacity(0.18), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderGlyph(snapshot.id, size: compact ? 26 : 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(snapshot.id.localizedName).font(compact ? .subheadline.weight(.semibold) : .headline).lineLimit(1).fixedSize()
                    if let plan = snapshot.account?.plan, !plan.isEmpty { PlanBadge(plan) }
                }
                Text(snapshot.lastSuccessAt.map { Present.updatedText($0, now: now) } ?? snapshot.id.subtitle)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if sparkline.count >= 2 {
                // Flexible width so the name never wraps on narrow cards; the sparkline gives way first.
                Sparkline(values: sparkline, color: snapshot.id.color)
                    .frame(maxWidth: compact ? 56 : 80)
                    .frame(height: compact ? 20 : 26)
                    .layoutPriority(-1)
            }
            StatusBadge(snapshot.status)
            if let p = snapshot.headlinePercent {
                UsageRing(percent: p, color: snapshot.id.color, lineWidth: compact ? 4 : 5)
                    .frame(width: compact ? 34 : 44, height: compact ? 34 : 44)
            }
        }
    }

    private var errorBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Present.statusTitle(snapshot.status)).font(.subheadline.weight(.semibold))
            Text(snapshot.status.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Empty state

public struct EmptyStateView: View {
    public var title: String
    public var message: String
    public var symbol: String

    public init(title: String, message: String, symbol: String = "gauge.with.dots.needle.33percent") {
        self.title = title
        self.message = message
        self.symbol = symbol
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
