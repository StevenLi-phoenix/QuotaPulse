#if os(macOS)
import AppKit
import QuotaCore

/// Draws the menu-bar item: a row of narrow vertical bars, one per provider, in the provider's colour. A bar's fill height is
/// how much is left. No text, so a glance reads shapes and colours only.
///
/// - Live: tinted track with a solid fill from the bottom.
/// - Out of date: hollow with a dashed edge and a tick where the last known level was.
/// - No data yet: hollow, dashed, empty.
/// - Running low or exhausted: a red dot under the bar (colour means "which provider", so the warning is a separate shape).
///
/// It carries its own colours (a template image could not be coloured per provider). The size depends only on how many
/// providers have bars, so values changing never move the neighbouring menu-bar items.
public enum MenuBarImage {
    public static let height: CGFloat = 20
    static let barWidth: CGFloat = 4
    static let gap: CGFloat = 1.5
    static let pad: CGFloat = 1
    static let barTop: CGFloat = 19
    static let barBottom: CGFloat = 5.5
    static let dot: CGFloat = 3.2

    /// Width for a number of bars (at least one: the empty placeholder).
    public static func width(bars: Int) -> CGFloat {
        let n = CGFloat(max(1, min(bars, MenuBarStatus.maxBars)))
        return pad * 2 + n * barWidth + (n - 1) * gap
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    public static func image(for status: MenuBarStatus) -> NSImage {
        let bars = status.bars
        let size = NSSize(width: width(bars: bars.count), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            if bars.isEmpty {
                // Nothing to show yet: one empty dashed bar in neutral grey.
                drawBar(x: pad, kind: .noData, remaining: nil, tint: color(ProviderInfo.neutralHex), alert: false)
            }
            for (i, bar) in bars.enumerated() {
                drawBar(x: pad + CGFloat(i) * (barWidth + gap), kind: bar.kind, remaining: bar.remaining, tint: color(bar.colorHex), alert: bar.alert)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = status.accessibilityLabel
        return image
    }

    private static func drawBar(x: CGFloat, kind: MenuBarStatus.Kind, remaining: Double?, tint: NSColor, alert: Bool) {
        let frame = NSRect(x: x, y: barBottom, width: barWidth, height: barTop - barBottom)
        let r = barWidth / 2
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.4, dy: 0.4), xRadius: r, yRadius: r)
        outline.lineWidth = 0.8
        switch kind {
        case .live:
            tint.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: frame, xRadius: r, yRadius: r).fill()
            if let left = remaining {
                let h = frame.height * CGFloat(min(100, max(0, left)) / 100)
                if h > 0.5 {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: frame, xRadius: r, yRadius: r).addClip()
                    tint.setFill()
                    NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(h, 1.5)).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            tint.withAlphaComponent(0.85).setStroke()
            outline.stroke()
        case .stale, .noData:
            tint.setStroke()
            outline.setLineDash([1.6, 1.2], count: 2, phase: 0)
            outline.stroke()
            if kind == .stale, let left = remaining {
                // Where the level was when the data was last good.
                let y = frame.minY + frame.height * CGFloat(min(100, max(0, left)) / 100)
                tint.setFill()
                NSRect(x: frame.minX + 0.4, y: min(max(y, frame.minY + 0.8), frame.maxY - 1.6) - 0.6, width: frame.width - 0.8, height: 1.2).fill()
            }
        }
        if alert {
            let d = NSRect(x: frame.midX - dot / 2, y: 0.8, width: dot, height: dot)
            NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1).setFill()
            NSBezierPath(ovalIn: d).fill()
        }
    }
}
#endif
