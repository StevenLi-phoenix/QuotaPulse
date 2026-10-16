import SwiftUI
import QuotaCore

/// Shared derived state used by every client UI: sparkline values per provider, etc.
public enum Derive {
    /// Sparkline for a provider from its primary window history (≤ `points` values).
    public static func sparkline(samples: [Sample], provider: ProviderSnapshot, points: Int = 48) -> [Double] {
        let windowID = provider.primaryWindow?.id ?? (provider.balance != nil ? Sample.balanceWindowID : nil)
        guard let windowID else { return [] }
        let filtered = samples.filter { $0.provider == provider.id && $0.window == windowID }
        return Downsample.samples(filtered, maxPoints: points).map(\.value)
    }

    public static func sparklines(samples: [Sample], snapshot: QuotaSnapshot) -> [ProviderID: [Double]] {
        var out: [ProviderID: [Double]] = [:]
        for p in snapshot.providers { out[p.id] = sparkline(samples: samples, provider: p) }
        return out
    }
}

/// A ticking clock so countdowns re-render without recomputing data (1 Hz, main actor).
@MainActor @Observable public final class Ticker {
    public private(set) var now = Date()
    @ObservationIgnored private nonisolated(unsafe) var task: Task<Void, Never>?

    public init(interval: Duration = .seconds(30)) {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.now = Date()
            }
        }
    }

    deinit { task?.cancel() }
}
