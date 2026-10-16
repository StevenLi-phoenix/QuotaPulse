// Prints "windowID<TAB>title" for every on-screen window owned by the given process name.
import AppKit
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "QuotaPulse"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard (w[kCGWindowOwnerName as String] as? String) == owner, let id = w[kCGWindowNumber as String] as? Int else { continue }
    let title = (w[kCGWindowName as String] as? String) ?? ""
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("\(id)\t\(title)\t\(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0)")
}
