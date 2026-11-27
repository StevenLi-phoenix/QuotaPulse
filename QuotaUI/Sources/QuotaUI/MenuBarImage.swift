#if os(macOS)
import AppKit
import QuotaCore

/// Draws the menu-bar item: a row of narrow vertical level meters, one per provider. One visual variable per meaning:
///
/// - **Height = how much is used** in the provider's tightest window, filled from the bottom like the usage bars in the
///   dropdown panel (and the providers' own "% used" pages). A full bar is a used-up window; a calm menu bar is short bars.
/// - **Colour = which provider** (`ProviderInfo.brandHex`). Every bar keeps a short stub of its colour even at 0 % used, so
///   each provider stays identifiable.
/// - The empty part is a neutral grey track with no outline, so an empty bar never looks like a full one.
/// - Out of date: the same bar, faded. No data yet: the track alone, faded.
///
/// No text, dots or dashes: at menu-bar size extra marks read as punctuation, and the tooltip carries the numbers. The image
/// carries its own colours (a template image could not be coloured per provider). The size depends only on how many providers
/// have bars, so values changing never move the neighbouring menu-bar items.
public enum MenuBarImage {
    public static let height: CGFloat = 20
    static let barWidth: CGFloat = 4
    static let gap: CGFloat = 2
    static let pad: CGFloat = 1
    static let barBottom: CGFloat = 2.5
    static let barTop: CGFloat = 17.5
    static let corner: CGFloat = 1.2
    /// Fill shown at 0 % used, so the bar still shows its provider's colour.
    static let minFill: CGFloat = 2
    /// Mid grey at this alpha reads as a quiet track on both a dark and a light menu bar.
    static let track = NSColor(white: 0.5, alpha: 0.45)
    static let fadedAlpha: CGFloat = 0.4

    /// Width for a number of bars (at least one: the empty placeholder).
    public static func width(bars: Int) -> CGFloat {
        let n = CGFloat(max(1, min(bars, MenuBarStatus.maxBars)))
        return pad * 2 + n * barWidth + (n - 1) * gap
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Fill height in points for a used percentage: proportional, never below the colour stub.
    static func fillHeight(used: Double) -> CGFloat {
        let h = (barTop - barBottom) * CGFloat(min(100, max(0, used)) / 100)
        return max(minFill, h)
    }

    public static func image(for status: MenuBarStatus) -> NSImage {
        let bars = status.bars
        let size = NSSize(width: width(bars: bars.count), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            if bars.isEmpty {
                // Nothing to show yet: one faded empty track.
                drawBar(x: pad, used: nil, tint: color(ProviderInfo.neutralHex), alpha: fadedAlpha)
            }
            for (i, bar) in bars.enumerated() {
                drawBar(x: pad + CGFloat(i) * (barWidth + gap), used: bar.used, tint: color(bar.colorHex),
                        alpha: bar.kind == .live ? 1 : fadedAlpha)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = status.accessibilityLabel
        return image
    }

    private static func drawBar(x: CGFloat, used: Double?, tint: NSColor, alpha: CGFloat) {
        let frame = NSRect(x: x, y: barBottom, width: barWidth, height: barTop - barBottom)
        let shape = NSBezierPath(roundedRect: frame, xRadius: corner, yRadius: corner)
        track.withAlphaComponent(track.alphaComponent * alpha).setFill()
        shape.fill()
        guard let used else { return }
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        tint.withAlphaComponent(alpha).setFill()
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: fillHeight(used: used)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
