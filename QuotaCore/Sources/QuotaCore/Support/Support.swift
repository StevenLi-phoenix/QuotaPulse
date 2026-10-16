import Foundation
import os

// MARK: - Logging

public enum QPLog {
    public static let subsystem = "app.lishuyu.quotapulse"
    public static let providers = Logger(subsystem: subsystem, category: "providers")
    public static let credentials = Logger(subsystem: subsystem, category: "credentials")
    public static let forecast = Logger(subsystem: subsystem, category: "forecast")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let hub = Logger(subsystem: subsystem, category: "hub")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Redacts a secret for logs: first 6 chars + length.
    public static func redact(_ secret: String) -> String {
        guard !secret.isEmpty else { return "<empty>" }
        return "\(secret.prefix(6))…(len \(secret.count))"
    }
}

// MARK: - HTTP transport (injectable for tests)

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String] = [:], data: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, data: data)
    }
}

/// Test double: answers requests from a queue or a closure.
public final class StubTransport: HTTPTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) throws -> HTTPResponse
    private let lock = NSLock()
    private var handler: Handler
    public private(set) var requests: [URLRequest] = []

    public init(_ handler: @escaping Handler) { self.handler = handler }

    public convenience init(status: Int, json: String, headers: [String: String] = [:]) {
        self.init { _ in HTTPResponse(statusCode: status, headers: headers, data: Data(json.utf8)) }
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let h = record(request)
        return try h(request)
    }

    private func record(_ request: URLRequest) -> Handler {
        lock.withLock { requests.append(request); return handler }
    }
}

// MARK: - Date helpers

public enum DateParsing {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func iso8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }

    /// Accepts epoch seconds or milliseconds (heuristic: > 10^11 means ms).
    public static func epoch(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 1e11 ? value / 1000 : value)
    }
}

// MARK: - JSON helpers

public enum JSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Lenient number extraction (Double / Int / numeric String).
    public static func number(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d.isFinite ? d : nil
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    public static func first(_ dict: [String: Any], keys: [String]) -> Any? {
        for k in keys { if let v = dict[k], !(v is NSNull) { return v } }
        return nil
    }
}

// MARK: - Atomic file writes

public enum FileIO {
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

// MARK: - Formatting

public enum QuotaFormat {
    public static func percent(_ value: Double) -> String {
        if value >= 99.95 { return "100%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }

    public static func money(_ value: Double, symbol: String) -> String {
        if abs(value) >= 100 { return String(format: "%@%.0f", symbol, value) }
        return String(format: "%@%.2f", symbol, value)
    }

    /// "2h 14m", "38m", "< 1m"
    public static func countdown(to date: Date, from now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        if seconds <= 0 { return "now" }
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "< 1m"
    }

    public static func rate(_ perHour: Double) -> String {
        if perHour < 0.05 { return "flat" }
        if perHour < 1 { return String(format: "%.1f%%/h", perHour) }
        return String(format: "%.0f%%/h", perHour)
    }
}

public extension FileManager {
    /// The user's home on macOS; the app container on iOS/watchOS (where CLI credentials don't exist anyway).
    var qpHomeDirectory: URL {
        #if os(macOS)
        return homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory())
        #endif
    }
}
