#if os(macOS)
import AppKit
import QuotaCore

/// Draws the menu-bar item as one bitmap-independent image with fixed colours.
///
/// Why not a template image: a template takes whatever colour macOS picks for the menu bar. When the system picks wrongly
/// (a transparent menu bar over a bright wallpaper can end up with white items on white), the item vanishes with the rest.
/// This image carries its own background chip, so it reads on light, dark, tinted and transparent menu bars alike.
/// The chip has a fixed size per style, so the neighbours never shift when the number changes.
public enum MenuBarImage {
    public static let height: CGFloat = 20

    /// Chip width for a style (`both`, `icon`, `percent`). Constant for a style: no jitter as values change.
    public static func width(style: String) -> CGFloat {
        switch style {
        case "icon": return 4 + glyphSize + 4 + 13 + 5
        case "percent": return 6 + textWidth + 6
        default: return 4 + glyphSize + 4 + textWidth + 6
        }
    }

    static let glyphSize: CGFloat = 14
    static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold) }
    /// Width of the widest value ("100%", though the item never prints it: 99% is the most that is left once used).
    static var textWidth: CGFloat { ceil(("100%" as NSString).size(withAttributes: [.font: font]).width) }

    struct Palette {
        var fill: NSColor
        var border: NSColor
        var text: NSColor
        var bar: NSColor
        var dashed: Bool
    }

    static func palette(for status: MenuBarStatus) -> Palette {
        let white = NSColor.white
        switch status.kind {
        case .empty:
            return Palette(fill: NSColor(srgbRed: 0.36, green: 0.36, blue: 0.38, alpha: 0.9), border: white.withAlphaComponent(0.7),
                           text: white.withAlphaComponent(0.9), bar: white.withAlphaComponent(0.35), dashed: true)
        case .stale:
            return Palette(fill: NSColor(srgbRed: 0.36, green: 0.36, blue: 0.38, alpha: 0.92), border: white.withAlphaComponent(0.7),
                           text: white.withAlphaComponent(0.92), bar: white.withAlphaComponent(0.55), dashed: true)
        case .live:
            switch status.level ?? .calm {
            case .calm:
                return Palette(fill: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.94), border: white.withAlphaComponent(0.32),
                               text: white, bar: white, dashed: false)
            case .warm:
                return Palette(fill: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.94), border: white.withAlphaComponent(0.32),
                               text: white, bar: NSColor(srgbRed: 1, green: 0.69, blue: 0.13, alpha: 1), dashed: false)
            case .hot:
                return Palette(fill: NSColor(srgbRed: 0.78, green: 0.32, blue: 0.02, alpha: 1), border: white.withAlphaComponent(0.55),
                               text: white, bar: white, dashed: false)
            case .critical:
                return Palette(fill: NSColor(srgbRed: 0.80, green: 0.10, blue: 0.10, alpha: 1), border: white.withAlphaComponent(0.55),
                               text: white, bar: white, dashed: false)
            }
        }
    }

    /// `style` is the saved `menuBarStyle`: `both` (icon + percent), `icon`, `percent`.
    public static func image(for status: MenuBarStatus, style: String, refreshing: Bool = false) -> NSImage {
        let size = NSSize(width: width(style: style), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let pal = palette(for: status)
            let chip = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: chip, xRadius: 5.5, yRadius: 5.5)
            pal.fill.setFill()
            path.fill()
            pal.border.setStroke()
            path.lineWidth = 1
            if pal.dashed { path.setLineDash([2.5, 2], count: 2, phase: 0) }
            path.stroke()

            var x: CGFloat = style == "percent" ? 6 : 4
            if style != "percent" {
                drawGlyph(status, in: NSRect(x: x, y: (rect.height - glyphSize) / 2, width: glyphSize, height: glyphSize))
                x += glyphSize + 4
            }
            switch style {
            case "icon":
                drawRing(status, pal: pal, in: NSRect(x: x, y: (rect.height - 13) / 2, width: 13, height: 13))
            default:
                drawValue(status, pal: pal, in: NSRect(x: x, y: 0, width: textWidth, height: rect.height))
            }
            if status.hasIssues { drawBadge(in: rect) }
            if refreshing {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: 2.5, y: rect.height - 5.5, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = status.accessibilityLabel
        return image
    }

    // MARK: Parts

    private static func drawGlyph(_ status: MenuBarStatus, in rect: NSRect) {
        let info = status.info
        let brand = info.map { NSColor(srgbRed: CGFloat(($0.brandHex >> 16) & 0xFF) / 255, green: CGFloat(($0.brandHex >> 8) & 0xFF) / 255,
                                       blue: CGFloat($0.brandHex & 0xFF) / 255, alpha: 1) } ?? NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
        let plate = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
        brand.setFill()
        plate.fill()
        NSColor.white.withAlphaComponent(status.level.map { $0 >= .hot } == true ? 0.9 : 0.0).setStroke()
        plate.lineWidth = 0.8
        plate.stroke()
        let name = info?.symbol ?? ProviderInfo.neutralSymbol
        let config = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold).applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = symbol.size
        let fit = min(1, (rect.width - 3) / max(s.width, 1), (rect.height - 3) / max(s.height, 1))
        let target = NSRect(x: rect.midX - s.width * fit / 2, y: rect.midY - s.height * fit / 2, width: s.width * fit, height: s.height * fit)
        symbol.draw(in: target)
    }

    /// Percent left over a thin bar that drains as the window is used.
    private static func drawValue(_ status: MenuBarStatus, pal: Palette, in rect: NSRect) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: pal.text, .paragraphStyle: para]
        let text = status.percentText as NSString
        let h = text.size(withAttributes: attrs).height
        text.draw(in: NSRect(x: rect.minX, y: 6.6 + (rect.height - 6.6 - h) / 2 - 0.5, width: rect.width, height: h), withAttributes: attrs)
        let track = NSRect(x: rect.minX + 1, y: 3.6, width: rect.width - 2, height: 2.4)
        pal.text.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.2, yRadius: 1.2).fill()
        if let left = status.remaining, status.kind != .empty {
            let fill = NSRect(x: track.minX, y: track.minY, width: max(2.4, track.width * CGFloat(min(100, left) / 100)), height: track.height)
            pal.bar.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.2, yRadius: 1.2).fill()
        }
    }

    /// Icon-only style: a ring of what is left (full = all left), same colours as the bar.
    private static func drawRing(_ status: MenuBarStatus, pal: Palette, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - 1.5
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2.4
        pal.text.withAlphaComponent(0.28).setStroke()
        track.stroke()
        guard let left = status.remaining, status.kind != .empty, left > 0 else { return }
        let sweep = max(14, 360 * CGFloat(min(100, left) / 100))
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        arc.lineWidth = 2.4
        arc.lineCapStyle = .round
        pal.bar.setStroke()
        arc.stroke()
    }

    /// "Something else needs attention": an amber dot on the chip's corner.
    private static func drawBadge(in rect: NSRect) {
        let dot = NSRect(x: rect.maxX - 6, y: rect.maxY - 6.5, width: 6, height: 6)
        NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1).setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
        NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}
#endif
