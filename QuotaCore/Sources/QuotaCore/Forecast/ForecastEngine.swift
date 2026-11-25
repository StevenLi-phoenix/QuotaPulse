import Foundation

/// Burn-rate forecasting over stored samples. Pure functions; everything is testable.
public enum ForecastEngine {
    /// Minimum samples / span before we claim a trend.
    public static let minSamples = 2
    public static let minSpan: TimeInterval = 10 * 60

    // MARK: Windows

    /// Forecast for a percent-used window.
    /// - Parameters:
    ///   - samples: samples of this provider+window (any order, any age).
    ///   - window: the latest state.
    public static func forecast(window: UsageWindow, samples: [Sample], now: Date = Date()) -> Forecast {
        // A rolling window past its reset has nothing to extrapolate: the next window hasn't started.
        if case .awaitingFirstUse = window.phase(now: now) { return .insufficient }
        let cycle = currentCycle(samples: samples, window: window, now: now)
        guard cycle.count >= minSamples, let first = cycle.first, let last = cycle.last,
              last.at.timeIntervalSince(first.at) >= minSpan else {
            return Forecast(confidence: .insufficient, sampleCount: cycle.count,
                            span: cycle.isEmpty ? 0 : (cycle.last!.at.timeIntervalSince(cycle.first!.at)))
        }
        let span = last.at.timeIntervalSince(first.at)
        let slopePerSec = max(0, Regression.slope(cycle.map { ($0.at.timeIntervalSince1970, $0.value) }))
        let perHour = slopePerSec * 3600
        let current = window.currentUtilization(now: now)

        var projected: Double?
        var exhaustion: Date?
        if let resetsAt = window.effectiveResetsAt(now: now), resetsAt > now {
            let remaining = resetsAt.timeIntervalSince(now)
            projected = min(100, current + slopePerSec * remaining)
            if slopePerSec > 0 {
                let secondsToFull = (100 - current) / slopePerSec
                let when = now.addingTimeInterval(secondsToFull)
                if when < resetsAt { exhaustion = when }
            }
        } else if slopePerSec > 0 {
            exhaustion = now.addingTimeInterval((100 - current) / slopePerSec)
        }

        var pace: Double?
        if let start = window.cycleStart(now: now), let duration = window.duration, duration > 0 {
            let elapsed = min(duration, max(0, now.timeIntervalSince(start)))
            let expected = elapsed / duration * 100
            pace = current - expected
        }

        let confidence: Forecast.Confidence = switch (cycle.count, span) {
        case (let n, let s) where n >= 12 && s >= 2 * 3600: .high
        case (let n, let s) where n >= 5 && s >= 45 * 60: .medium
        default: .low
        }
        return Forecast(confidence: confidence, rate: perHour, projectedAtReset: projected, exhaustionAt: exhaustion,
                        paceDelta: pace, hoursRemaining: nil, sampleCount: cycle.count, span: span)
    }

    /// Samples belonging to the current reset cycle: after the window start when known, otherwise
    /// everything since the last visible drop in utilization (a drop = a new window started).
    public static func currentCycle(samples: [Sample], window: UsageWindow, now: Date) -> [Sample] {
        let sorted = samples.filter { $0.at <= now }.sorted { $0.at < $1.at }
        guard !sorted.isEmpty else { return [] }
        var cut: Date = .distantPast
        if let start = window.cycleStart(now: now) { cut = start }
        // Also cut at any reset that happened inside the recorded data (utilization dropped ≥ 5 points,
        // or the server-reported resetsAt moved forward).
        var lastResets: Date?
        var dropIndex: Int?
        for (i, s) in sorted.enumerated() where i > 0 {
            let prev = sorted[i - 1]
            if s.value + 5 < prev.value { dropIndex = i }
            if let r = s.resetsAt, let lr = lastResets, r.timeIntervalSince(lr) > 60 { dropIndex = i }
            lastResets = s.resetsAt ?? lastResets
        }
        var cycle = sorted.filter { $0.at >= cut }
        if let dropIndex, dropIndex < sorted.count {
            let dropAt = sorted[dropIndex].at
            cycle = cycle.filter { $0.at >= dropAt }
        }
        // Ignore the stale tail if the latest sample is far older than the window (hub was asleep).
        if let duration = window.duration, let last = cycle.last, now.timeIntervalSince(last.at) > duration {
            return []
        }
        return cycle
    }

    // MARK: Balances

    /// Forecast for a prepaid balance from the last `lookback` of samples.
    public static func forecast(balance: Balance, samples: [Sample], now: Date = Date(),
                                lookback: TimeInterval = 7 * 86400) -> Forecast {
        let recent = samples.filter { $0.at >= now.addingTimeInterval(-lookback) && $0.at <= now }
            .sorted { $0.at < $1.at }
        // A top-up (balance jumps up) starts a new segment.
        var segment: [Sample] = []
        for s in recent {
            if let last = segment.last, s.value > last.value + 0.01 { segment.removeAll() }
            segment.append(s)
        }
        guard segment.count >= minSamples, let first = segment.first, let last = segment.last,
              last.at.timeIntervalSince(first.at) >= minSpan else {
            return Forecast(confidence: .insufficient, sampleCount: segment.count)
        }
        let span = last.at.timeIntervalSince(first.at)
        let slopePerSec = Regression.slope(segment.map { ($0.at.timeIntervalSince1970, $0.value) })
        // A flat series still yields a rounding-noise slope (~1e-26/s); count it as spend only when the
        // fitted line falls by more than the top-up tolerance over the observed span.
        let burnPerHour = -slopePerSec * span > 0.01 ? -slopePerSec * 3600 : 0
        let hours: Double? = burnPerHour > 0 ? balance.total / burnPerHour : nil
        let exhaustion = hours.map { now.addingTimeInterval($0 * 3600) }
        let confidence: Forecast.Confidence = span >= 2 * 86400 && segment.count >= 10 ? .high
            : (span >= 6 * 3600 && segment.count >= 4 ? .medium : .low)
        return Forecast(confidence: confidence, rate: burnPerHour, projectedAtReset: nil, exhaustionAt: exhaustion,
                        paceDelta: nil, hoursRemaining: hours, sampleCount: segment.count, span: span)
    }
}

public enum Regression {
    /// Ordinary least squares slope (dy/dx). Returns 0 for degenerate input.
    public static func slope(_ points: [(x: Double, y: Double)]) -> Double {
        guard points.count >= 2 else { return 0 }
        let n = Double(points.count)
        let mx = points.reduce(0) { $0 + $1.x } / n
        let my = points.reduce(0) { $0 + $1.y } / n
        var sxy = 0.0, sxx = 0.0
        for p in points {
            sxy += (p.x - mx) * (p.y - my)
            sxx += (p.x - mx) * (p.x - mx)
        }
        guard sxx > 0 else { return 0 }
        return sxy / sxx
    }
}

/// Downsampling for charts: keeps at most `maxPoints` using bucket averages so the UI never
/// draws thousands of marks.
public enum Downsample {
    public static func samples(_ input: [Sample], maxPoints: Int) -> [Sample] {
        guard input.count > maxPoints, maxPoints > 1 else { return input }
        let sorted = input.sorted { $0.at < $1.at }
        let bucket = Double(sorted.count) / Double(maxPoints)
        var out: [Sample] = []
        out.reserveCapacity(maxPoints)
        var i = 0
        while i < sorted.count {
            let end = min(sorted.count, Int((Double(out.count + 1) * bucket).rounded()))
            let slice = sorted[i..<max(end, i + 1)]
            let t = slice.reduce(0.0) { $0 + $1.at.timeIntervalSince1970 } / Double(slice.count)
            let v = slice.reduce(0.0) { $0 + $1.value } / Double(slice.count)
            var s = slice.last!
            s.at = Date(timeIntervalSince1970: t)
            s.value = v
            out.append(s)
            i = max(end, i + 1)
        }
        return out
    }
}
