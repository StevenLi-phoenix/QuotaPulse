import SwiftUI
import QuotaCore
#if canImport(Charts)
import Charts
#endif

/// Utilization history for one provider; one line per window, optional balance axis.
public struct HistoryChart: View {
    public var samples: [Sample]
    public var provider: ProviderInfo
    public var windows: [UsageWindow]
    public var range: TimeInterval
    public var now: Date

    public init(samples: [Sample], provider: ProviderInfo, windows: [UsageWindow], range: TimeInterval, now: Date = Date()) {
        self.samples = samples
        self.provider = provider
        self.windows = windows
        self.range = range
        self.now = now
    }

    private func title(_ id: String) -> String {
        windows.first { $0.id == id }?.title ?? (id == Sample.balanceWindowID ? L("Balance") : id)
    }

    /// Hours for a day or less, weekday + hour beyond — long "Oct 15 at 2…" labels get clipped.
    private var xAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine()
            if range <= 24 * 3600 {
                AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
            } else {
                AxisValueLabel(format: .dateTime.weekday(.abbreviated).hour(.defaultDigits(amPM: .abbreviated)))
            }
        }
    }

    private var windowSamples: [Sample] { samples.filter { $0.window != Sample.balanceWindowID } }
    private var balanceSamples: [Sample] { samples.filter { $0.window == Sample.balanceWindowID } }

    public var body: some View {
        #if canImport(Charts)
        let start = now.addingTimeInterval(-range)
        VStack(alignment: .leading, spacing: 8) {
            if !windowSamples.isEmpty {
                Chart {
                    ForEach(windowSamples, id: \.self) { s in
                        LineMark(x: .value("Time", s.at), y: .value("Used", s.value))
                            .foregroundStyle(by: .value("Window", title(s.window)))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    RuleMark(y: .value("Full", 100)).foregroundStyle(.red.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .chartXScale(domain: start...now)
                .chartXAxis { xAxis }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } } } }
                .chartLegend(position: .top, alignment: .leading)
                .frame(minHeight: 160)
            }
            if !balanceSamples.isEmpty {
                Chart(balanceSamples, id: \.self) { s in
                    AreaMark(x: .value("Time", s.at), y: .value("Balance", s.value))
                        .foregroundStyle(LinearGradient(colors: [provider.color.opacity(0.35), provider.color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.at), y: .value("Balance", s.value))
                        .foregroundStyle(provider.color)
                        .interpolationMethod(.monotone)
                }
                .chartXScale(domain: start...now)
                .chartXAxis { xAxis }
                .frame(minHeight: 120)
            }
            if windowSamples.isEmpty && balanceSamples.isEmpty {
                EmptyStateView(title: L("No history yet"), message: L("Samples are recorded on every refresh. Come back in a little while."), symbol: "clock.arrow.circlepath")
            }
        }
        #else
        EmptyStateView(title: L("Charts unavailable"), message: "")
        #endif
    }
}
