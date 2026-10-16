import Foundation
import MetricKit
import QuotaCore
import UIKit

/// Where iOS keeps its own evidence: `Documents/Logs` (JSON Lines, shipped to the hub) and
/// `Documents/Diagnostics` (MetricKit crash / hang payloads). Both are visible in Files thanks to
/// `UIFileSharingEnabled`, and "Export diagnostics" zips them for the share sheet.
enum DiagnosticsPaths {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var logs: URL { documents.appendingPathComponent("Logs", isDirectory: true) }
    static var diagnostics: URL { documents.appendingPathComponent("Diagnostics", isDirectory: true) }
}

enum DeviceIdentityFactory {
    /// "iPhone-3F2A" style: model + 4 chars of a per-install id (UIDevice.name is generic since iOS 16).
    @MainActor static func current(platform: String) -> DeviceIdentity {
        let defaults = UserDefaults.standard
        var short = defaults.string(forKey: "device.shortID") ?? ""
        if short.isEmpty {
            short = String(UUID().uuidString.prefix(4))
            defaults.set(short, forKey: "device.shortID")
        }
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") + ")"
        let model = UIDevice.current.model.replacingOccurrences(of: " ", with: "")
        return DeviceIdentity(name: "\(model)-\(short)", appVersion: version, platform: "\(platform) \(UIDevice.current.systemVersion)")
    }
}

/// MetricKit subscriber: crash, hang, disk-write and CPU exception diagnostics land as JSON files.
final class DiagnosticsCollector: NSObject, MXMetricManagerSubscriber {
    let logger: FileLogger

    init(logger: FileLogger) {
        self.logger = logger
        super.init()
        try? FileManager.default.createDirectory(at: DiagnosticsPaths.diagnostics, withIntermediateDirectories: true)
        MXMetricManager.shared.add(self)
        logger.info("metric", "subscriber.added")
    }

    deinit { MXMetricManager.shared.remove(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            let name = "diagnostic-\(Self.stamp(p.timeStampEnd)).json"
            let url = DiagnosticsPaths.diagnostics.appendingPathComponent(name)
            try? p.jsonRepresentation().write(to: url, options: .atomic)
            logger.error("metric", "diagnostic.received", [
                "file": name,
                "crashes": "\(p.crashDiagnostics?.count ?? 0)",
                "hangs": "\(p.hangDiagnostics?.count ?? 0)",
                "cpu": "\(p.cpuExceptionDiagnostics?.count ?? 0)",
                "diskWrites": "\(p.diskWriteExceptionDiagnostics?.count ?? 0)",
            ])
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Daily metrics are summarised into the log rather than stored in full.
        for p in payloads {
            var f: [String: String] = ["from": Self.stamp(p.timeStampBegin), "to": Self.stamp(p.timeStampEnd)]
            if let launch = p.applicationLaunchMetrics { f["launchHist"] = "\(launch.histogrammedTimeToFirstDraw.totalBucketCount)" }
            if let mem = p.memoryMetrics { f["peakMemMB"] = String(format: "%.0f", mem.peakMemoryUsage.converted(to: .megabytes).value) }
            logger.info("metric", "daily.metrics", f)
        }
    }

    static func stamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f.string(from: d).replacingOccurrences(of: ":", with: "-")
    }

    static var storedPayloadCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: DiagnosticsPaths.diagnostics.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    /// Zips Logs + Diagnostics into a temp file for the share sheet (NSFileCoordinator does the zipping).
    static func exportZip(logger: FileLogger) throws -> URL {
        logger.flush()
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaPulse-diagnostics", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for src in [DiagnosticsPaths.logs, DiagnosticsPaths.diagnostics] where FileManager.default.fileExists(atPath: src.path) {
            try FileManager.default.copyItem(at: src, to: staging.appendingPathComponent(src.lastPathComponent))
        }
        let info = "QuotaPulse \(logger.identity.appVersion) · \(logger.identity.platform) · \(logger.identity.name) · exported \(Date())\n"
        try info.write(to: staging.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaPulse-diagnostics.zip")
        try? FileManager.default.removeItem(at: dest)
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordError) { zipURL in
            do { try FileManager.default.copyItem(at: zipURL, to: dest) } catch { copyError = error }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        logger.info("app", "diagnostics.exported", ["bytes": "\((try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0)"])
        return dest
    }
}
