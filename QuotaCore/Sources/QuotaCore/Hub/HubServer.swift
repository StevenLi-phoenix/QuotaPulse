import Foundation
import Network

/// Tiny HTTP server on Network.framework serving the hub protocol. One request per connection.
public final class HubServer: @unchecked Sendable {
    public let port: UInt16
    public let exposeOnNetwork: Bool
    private let router: HubRouter
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.lishuyu.quotapulse.hub")
    private let lock = NSLock()
    private var _state: String = "stopped"
    public var state: String { lock.withLock { _state } }

    public init(port: UInt16, exposeOnNetwork: Bool, router: HubRouter) {
        self.port = port
        self.exposeOnNetwork = exposeOnNetwork
        self.router = router
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if !exposeOnNetwork {
            params.requiredInterfaceType = .loopback
        }
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            let text: String = switch st {
            case .ready: "listening on :\(self.port)\(self.exposeOnNetwork ? "" : " (loopback)")"
            case let .failed(e): "failed: \(e.localizedDescription)"
            case .cancelled: "stopped"
            case .waiting(let e): "waiting: \(e.localizedDescription)"
            default: "starting"
            }
            self.lock.withLock { self._state = text }
            QPLog.hub.info("hub \(text, privacy: .public)")
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.withLock { _state = "stopped" }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if buffer.count > 128 * 1024 { conn.cancel(); return }
                if let req = HTTPParser.parse(buffer) {
                    Task {
                        let resp = await self.router.handle(req)
                        QPLog.hub.debug("\(req.method, privacy: .public) \(req.path, privacy: .public) → \(resp.status)")
                        conn.send(content: HTTPParser.serialize(resp), completion: .contentProcessed { _ in conn.cancel() })
                    }
                } else if isComplete || error != nil {
                    conn.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    /// Best-effort list of IPv4 addresses for the pairing UI (Tailscale 100.x first).
    public static func localIPv4Addresses() -> [String] {
        var addrs: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addrs.append(String(cString: host))
            }
        }
        return addrs.sorted { a, b in
            let ta = a.hasPrefix("100."), tb = b.hasPrefix("100.")
            if ta != tb { return ta }
            return a < b
        }
    }
}
