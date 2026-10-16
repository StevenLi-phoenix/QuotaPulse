import AppKit
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let ctx = NSGraphicsContext.current!.cgContext
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2237, yRadius: size * 0.2237)
    path.addClip()
    let colors = [NSColor(red: 0.11, green: 0.12, blue: 0.18, alpha: 1).cgColor, NSColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    let center = CGPoint(x: size / 2, y: size / 2 - size * 0.02)
    let r = size * 0.30
    func arc(from a: CGFloat, to b: CGFloat, color: NSColor, width: CGFloat) {
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: r, startAngle: a, endAngle: b, clockwise: true)
        p.lineWidth = width; p.lineCapStyle = .round
        color.setStroke(); p.stroke()
    }
    arc(from: 215, to: -35, color: NSColor.white.withAlphaComponent(0.12), width: size * 0.09)
    // three brand segments: Claude orange, Codex green, DeepSeek blue
    arc(from: 215, to: 135, color: NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1), width: size * 0.09)
    arc(from: 125, to: 45, color: NSColor(red: 0.06, green: 0.64, blue: 0.50, alpha: 1), width: size * 0.09)
    arc(from: 35, to: -35, color: NSColor(red: 0.30, green: 0.42, blue: 1.0, alpha: 1), width: size * 0.09)
    // needle
    let needle = NSBezierPath()
    needle.move(to: center)
    let ang = 60.0 * .pi / 180
    needle.line(to: CGPoint(x: center.x + cos(ang) * r * 0.78, y: center.y + sin(ang) * r * 0.78))
    needle.lineWidth = size * 0.035; needle.lineCapStyle = .round
    NSColor.white.setStroke(); needle.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - size * 0.04, y: center.y - size * 0.04, width: size * 0.08, height: size * 0.08)).fill()
    return true
}
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
