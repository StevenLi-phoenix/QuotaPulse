import Foundation

// MARK: - Event model

/// One JSON Lines record. Kept flat (string fields) so it is grep-able and stable across versions.
public struct TelemetryEvent: Codable, Sendable, Hashable {
    public var ts: Date
    public var level: String          // debug | info | notice | error
    public var category: String       // hub | pairing | bg | watch | widget | forecast | app | metric
    public var event: String
    public var fields: [String: String]
    public var device: String
    public var app: String            // app version
    public var platform: String       // iOS | watchOS | macOS

    public init(ts: Date = Date(), level: String, category: String, event: String, fields: [String: String] = [:],
                device: String, app: String, platform: String) {
        self.ts = ts
        self.level = level
        self.category = category
        self.event = event
        self.fields = fields
        self.device = device
        self.app = app
        self.platform = platform
    }

    public var isError: Bool { level == "error" }

    public func encodedLine() -> String {
        guard let data = try? JSON.encoder.encode(self), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    public static func decode(line: Substring) -> TelemetryEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSON.decoder.decode(TelemetryEvent.self, from: data)
    }
}

/// Who is logging — stable per install so the hub can group files per device.
public struct DeviceIdentity: Sendable, Hashable {
    public var name: String
    public var appVersion: String
    public var platform: String

    public init(name: String, appVersion: String, platform: String) {
        self.name = name
        self.appVersion = appVersion
        self.platform = platform
    }

    /// Safe for use as a folder name on the hub.
    public var folderName: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "device" : String(cleaned.prefix(64))
    }
}

// MARK: - File logger

/// JSON Lines file logger: one file per day (`quotapulse-YYYY-MM-DD.log`), total size capped, writes on a
/// serial background queue, with an upload cursor so clients can ship only what the hub hasn't seen.
public final class FileLogger: @unchecked Sendable {
    public let directory: URL
    public let maxTotalBytes: Int
    public let identity: DeviceIdentity
    private let queue = DispatchQueue(label: "app.lishuyu.quotapulse.filelogger", qos: .utility)
    private var handle: FileHandle?
    private var handleDay: String?
    private var cursor: [String: Int]   // fileName → bytes already uploaded
    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public init(directory: URL, identity: DeviceIdentity, maxTotalBytes: Int = 10 * 1024 * 1024) {
        self.directory = directory
        self.identity = identity
        self.maxTotalBytes = maxTotalBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("cursor.json")),
           let c = try? JSONDecoder().decode([String: Int].self, from: data) {
            cursor = c
        } else {
            cursor = [:]
        }
    }

    public static func fileName(for date: Date) -> String { "quotapulse-\(dayFormatter.string(from: date)).log" }

    public func log(_ level: String, _ category: String, _ event: String, _ fields: [String: String] = [:], at date: Date = Date()) {
        let e = TelemetryEvent(ts: date, level: level, category: category, event: event, fields: fields,
                               device: identity.name, app: identity.appVersion, platform: identity.platform)
        queue.async { self.write(e) }
    }

    public func info(_ category: String, _ event: String, _ fields: [String: String] = [:]) { log("info", category, event, fields) }
    public func notice(_ category: String, _ event: String, _ fields: [String: String] = [:]) { log("notice", category, event, fields) }
    public func error(_ category: String, _ event: String, _ fields: [String: String] = [:]) { log("error", category, event, fields) }

    /// Blocks until queued writes are on disk (tests, export).
    public func flush() { queue.sync { try? handle?.synchronize() } }

    private func write(_ e: TelemetryEvent) {
        let day = Self.dayFormatter.string(from: e.ts)
        if handle == nil || handleDay != day {
            try? handle?.close()
            let url = directory.appendingPathComponent(Self.fileName(for: e.ts))
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            handleDay = day
            enforceCap(keeping: url.lastPathComponent)
        }
        try? handle?.write(contentsOf: Data((e.encodedLine() + "\n").utf8))
    }

    /// Deletes the oldest day files until the total is under the cap (the current file is kept).
    func enforceCap(keeping current: String) {
        var files = logFiles()
        var total = files.reduce(0) { $0 + (fileSize($1)) }
        for f in files where total > maxTotalBytes && f.lastPathComponent != current {
            total -= fileSize(f)
            try? FileManager.default.removeItem(at: f)
            cursor[f.lastPathComponent] = nil
            files.removeAll { $0 == f }
        }
        // A single runaway file: truncate to the newest half.
        if total > maxTotalBytes, let f = files.first(where: { $0.lastPathComponent == current }), let data = try? Data(contentsOf: f) {
            let keep = data.suffix(maxTotalBytes / 2)
            if let nl = keep.firstIndex(of: 0x0A) {
                try? keep[(nl + 1)...].write(to: f)
            }
            cursor[current] = 0
            try? handle?.close()
            handle = try? FileHandle(forWritingTo: f)
            _ = try? handle?.seekToEnd()
        }
        saveCursor()
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Day files, oldest first.
    public func logFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("quotapulse-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public var totalBytes: Int { logFiles().reduce(0) { $0 + fileSize($1) } }

    // MARK: Upload cursor

    public struct Pending: Sendable {
        public var lines: [String]
        /// New cursor positions to persist once the upload succeeds.
        public var offsets: [String: Int]
    }

    /// Lines not yet uploaded (oldest first), at most `maxLines`.
    public func pendingUpload(maxLines: Int = 500) -> Pending {
        queue.sync {
            try? handle?.synchronize()
            var lines: [String] = []
            var offsets: [String: Int] = [:]
            for f in logFiles() {
                guard lines.count < maxLines, let data = try? Data(contentsOf: f) else { continue }
                let start = min(cursor[f.lastPathComponent] ?? 0, data.count)
                var consumed = start
                let rest = data[start...]
                for chunk in rest.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    if lines.count >= maxLines { break }
                    if let s = String(data: chunk, encoding: .utf8), !s.isEmpty { lines.append(s) }
                    consumed = chunk.endIndex + 1
                }
                offsets[f.lastPathComponent] = min(consumed, data.count)
            }
            return Pending(lines: lines, offsets: offsets)
        }
    }

    public func markUploaded(_ pending: Pending) {
        queue.sync {
            for (k, v) in pending.offsets { cursor[k] = v }
            saveCursor()
        }
    }

    public var pendingLineCount: Int { pendingUpload(maxLines: 100_000).lines.count }

    private func saveCursor() {
        if let data = try? JSONEncoder().encode(cursor) { try? data.write(to: directory.appendingPathComponent("cursor.json"), options: .atomic) }
    }
}

// MARK: - Hub-side store

/// Where the hub keeps what devices send: `telemetry/<device>/YYYY-MM-DD.log` plus a `devices.json` index.
public struct TelemetryStore: Sendable {
    public struct DeviceRecord: Codable, Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var platform: String
        public var appVersion: String
        public var lastSeen: Date
        public var eventCount: Int
        public var lastError: String?
        public var lastErrorAt: Date?
    }

    public let root: URL
    public init(root: URL) { self.root = root }

    public var indexURL: URL { root.appendingPathComponent("devices.json") }

    public func devices() -> [DeviceRecord] {
        guard let data = try? Data(contentsOf: indexURL), let d = try? JSON.decoder.decode([String: DeviceRecord].self, from: data) else { return [] }
        return d.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Appends the uploaded lines to per-day files and refreshes the device index. Returns accepted line count.
    @discardableResult
    public func ingest(lines: [Substring], identity: DeviceIdentity, now: Date = Date()) throws -> Int {
        let dir = root.appendingPathComponent(identity.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var byDay: [String: [Substring]] = [:]
        var accepted = 0
        var lastError: (String, Date)?
        for line in lines where !line.isEmpty {
            guard let e = TelemetryEvent.decode(line: line) else { continue }
            accepted += 1
            byDay[FileLogger.fileName(for: e.ts), default: []].append(line)
            if e.isError { lastError = ("\(e.event) \(e.fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))", e.ts) }
        }
        for (name, dayLines) in byDay {
            let url = dir.appendingPathComponent(name.replacingOccurrences(of: "quotapulse-", with: ""))
            let payload = Data((dayLines.joined(separator: "\n") + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd(); try? h.write(contentsOf: payload); try? h.close()
            } else {
                try payload.write(to: url)
            }
        }
        var index = (try? Data(contentsOf: indexURL)).flatMap { try? JSON.decoder.decode([String: DeviceRecord].self, from: $0) } ?? [:]
        var rec = index[identity.folderName] ?? DeviceRecord(name: identity.name, platform: identity.platform, appVersion: identity.appVersion, lastSeen: now, eventCount: 0)
        rec.name = identity.name
        rec.platform = identity.platform
        rec.appVersion = identity.appVersion
        rec.lastSeen = now
        rec.eventCount += accepted
        if let (msg, at) = lastError { rec.lastError = msg; rec.lastErrorAt = at }
        index[identity.folderName] = rec
        try FileIO.writeAtomically(try JSON.prettyEncoder.encode(index), to: indexURL)
        return accepted
    }
}

// MARK: - Client upload

public extension HubClient {
    /// Ships pending log lines to the hub (`POST /v1/telemetry`, body = JSON Lines). Returns accepted count.
    @discardableResult
    func uploadTelemetry(_ lines: [String], identity: DeviceIdentity) async throws -> Int {
        guard !lines.isEmpty else { return 0 }
        var request = URLRequest(url: Self.endpoint(base: pairing.baseURL, path: HubProtocol.telemetryPath))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(identity.name, forHTTPHeaderField: HubProtocol.deviceHeader)
        request.setValue(identity.appVersion, forHTTPHeaderField: HubProtocol.appVersionHeader)
        request.setValue(identity.platform, forHTTPHeaderField: HubProtocol.platformHeader)
        request.httpBody = Data((lines.joined(separator: "\n") + "\n").utf8)
        let response: HTTPResponse
        do { response = try await transport.send(request) } catch { throw ClientError.unreachable(error.localizedDescription) }
        switch response.statusCode {
        case 200:
            let obj = (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]) ?? [:]
            return Int(JSON.number(obj["accepted"]) ?? 0)
        case 401, 403: throw ClientError.unauthorized
        default: throw ClientError.badResponse(response.statusCode)
        }
    }

    /// Convenience: upload everything pending in a logger and advance its cursor.
    func syncTelemetry(from logger: FileLogger) async -> (uploaded: Int, error: String?) {
        // The gateway doesn't take telemetry; leave the lines on the device instead of failing on every refresh.
        guard pairing.supportsTelemetry else { return (0, nil) }
        let pending = logger.pendingUpload()
        guard !pending.lines.isEmpty else { return (0, nil) }
        do {
            let n = try await uploadTelemetry(pending.lines, identity: logger.identity)
            logger.markUploaded(pending)
            return (n, nil)
        } catch {
            return (0, error.localizedDescription)
        }
    }
}
