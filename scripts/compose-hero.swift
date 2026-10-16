// Composes docs/screenshots/hero.png from the individual screenshots (no ImageMagick on this Mac).
import AppKit
let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/screenshots")
func load(_ n: String) -> NSImage? { NSImage(contentsOf: dir.appendingPathComponent(n)) }
let W: CGFloat = 1600, H: CGFloat = 900
let canvas = NSImage(size: NSSize(width: W, height: H), flipped: false) { rect in
    let ctx = NSGraphicsContext.current!.cgContext
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1).cgColor,
        NSColor(red: 0.13, green: 0.10, blue: 0.16, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: W, y: H), options: [])
    func place(_ name: String, x: CGFloat, y: CGFloat, w: CGFloat, radius: CGFloat = 18) {
        guard let img = load(name) else { return }
        let h = w * img.size.height / img.size.width
        let r = NSRect(x: x, y: y, width: w, height: h)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()
    }
    place("mac-panel.png", x: 60, y: 120, w: 440, radius: 14)
    place("widget-large.png", x: 540, y: 300, w: 380, radius: 22)
    place("widget-small.png", x: 540, y: 100, w: 180, radius: 22)
    place("ip17-widget-medium.png", x: 740, y: 60, w: 190, radius: 30)
    place("widget-medium.png", x: 950, y: 100, w: 190, radius: 14)
    place("ip17-home.png", x: 1150, y: 90, w: 300, radius: 34)
    place("watch-home.png", x: 960, y: 560, w: 180, radius: 40)
    let title = "QuotaPulse"
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.white]
    (title as NSString).draw(at: NSPoint(x: 60, y: H - 90), withAttributes: attrs)
    let sub = "AI quota, burn rate and forecasts — menu bar · widgets · iPhone · Apple Watch"
    (sub as NSString).draw(at: NSPoint(x: 60, y: H - 125), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.7)])
    return true
}
let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("hero.png"))
print("wrote hero.png")
