import Foundation
import Network
import Synchronization

nonisolated private let lanLogger = NaiveFlowLogger(category: "LANProxy")

/// Limits apply to LAN ingress only; outbound protocol buffers have their own budgets.
nonisolated enum LANProxyLimits {
    static let devices = 3
    static let connections = devices * connectionsPerPeer
    static let connectionsPerPeer = 4
    static let pendingHandshakes = 4
    static let readBytes = 16 * 1024
    static let idleTimeout: TimeInterval = 120
}

/// Accessed under the server state lock. Pending handshakes consume connection
/// slots too, so slow clients cannot create an unbounded waiting queue.
nonisolated struct LANProxyAdmission {
    private var peers: [UUID: String] = [:]
    private var pending: Set<UUID> = []
    private var peerConnections: [String: Int] = [:]
    var connectionCount: Int { peers.count }
    var deviceCount: Int { peerConnections.count }
    var handshakeCount: Int { pending.count }

    mutating func reserve(_ id: UUID, peer: String) -> Bool {
        let count = peerConnections[peer, default: 0]
        guard LANProxyNetwork.isPrivate(peer), peers[id] == nil,
              peers.count < LANProxyLimits.connections,
              pending.count < LANProxyLimits.pendingHandshakes,
              count < LANProxyLimits.connectionsPerPeer,
              count > 0 || peerConnections.count < LANProxyLimits.devices else { return false }
        peers[id] = peer
        peerConnections[peer] = count + 1
        pending.insert(id)
        return true
    }

    mutating func established(_ id: UUID) { pending.remove(id) }
    mutating func release(_ id: UUID) {
        pending.remove(id)
        guard let peer = peers.removeValue(forKey: id), let count = peerConnections[peer] else { return }
        if count == 1 { peerConnections.removeValue(forKey: peer) }
        else { peerConnections[peer] = count - 1 }
    }

}

/// SOCKS5 CONNECT only. Other commands/protocols and non-private IPv4 peers
/// are rejected before outbound dialing.
nonisolated final class LANProxyServer: Sendable {
    typealias ConfigurationSource = @Sendable () -> ProxyConfiguration?
    private let queue = DispatchQueue(label: "com.argsment.NaiveFlow.lan")
    private let settings: LANProxySettings
    private let source: ConfigurationSource
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private struct State {
        var stopped = false
        var address: String?
        var listener: NWListener?
        var sessions: [UUID: LANProxySession] = [:]
        var admission = LANProxyAdmission()
    }
    private let state = Mutex(State())

    private init(settings: LANProxySettings, configuration: @escaping ConfigurationSource) {
        self.settings = settings
        source = configuration
    }

    /// Gate construction so disabled sharing allocates no monitor or listener.
    static func makeIfEnabled(settings: LANProxySettings, profileAllowed: Bool,
                              configuration: @escaping ConfigurationSource) -> LANProxyServer? {
        guard settings.enabled, profileAllowed else { return nil }
        return LANProxyServer(settings: settings, configuration: configuration)
    }

    func start() {
        guard settings.enabled, settings.port >= 1024 else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.bind(address: path.status == .satisfied ? LANProxyNetwork.wifiAddress() : nil)
        }
        monitor.start(queue: queue)
    }

    private func bind(address: String?) {
        let old = state.withLock { state -> (NWListener?, [LANProxySession])? in
            guard !state.stopped, state.address != address else { return nil }
            let old = (state.listener, Array(state.sessions.values))
            state.listener = nil
            state.sessions.removeAll()
            state.admission = LANProxyAdmission()
            state.address = address
            return old
        }
        guard let old else { return }
        old.0?.cancel()
        old.1.forEach { $0.cancel() }
        guard let address else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .wifi
            parameters.requiredLocalEndpoint = .hostPort(host: .init(address), port: .init(rawValue: settings.port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) ?? connection.cancel() }
            listener.stateUpdateHandler = { status in
                if case .failed(let error) = status { lanLogger.report("LAN listener failed", error: error) }
            }
            let installed = state.withLock { state in
                guard !state.stopped, state.address == address else { return false }
                state.listener = listener
                return true
            }
            if installed { listener.start(queue: queue) } else { listener.cancel() }
        } catch { lanLogger.report("LAN listener could not bind", error: error) }
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
              LANProxyNetwork.isPrivate(String(describing: host)),
              let configuration = source() else { connection.cancel(); return }
        let id = UUID()
        let peer = String(describing: host)
        let session: LANProxySession? = state.withLock { state in
            guard !state.stopped, state.listener != nil,
                  state.admission.reserve(id, peer: peer) else { return nil }
            let session = LANProxySession(connection: connection, configuration: configuration)
            state.sessions[id] = session
            return session
        }
        guard let session else { connection.cancel(); return }
        session.start(queue: queue, established: { [weak self] in
            self?.state.withLock { $0.admission.established(id) }
        }) { [weak self] in
            self?.state.withLock {
                $0.sessions.removeValue(forKey: id)
                $0.admission.release(id)
            }
        }
    }

    func cancel() {
        monitor.cancel()
        let resources = state.withLock { state in
            state.stopped = true
            let resources = (state.listener, Array(state.sessions.values))
            state.listener = nil
            state.sessions.removeAll()
            state.admission = LANProxyAdmission()
            return resources
        }
        resources.0?.cancel()
        resources.1.forEach { $0.cancel() }
    }

    deinit { cancel() }
}

nonisolated final class LANProxySession: Sendable {
    private let connection: NWConnection
    private let client: ProxyClient
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let activity = LANProxyActivity()
    private let idleTimeout: TimeInterval

    init(connection: NWConnection, configuration: ProxyConfiguration, idleTimeout: TimeInterval = LANProxyLimits.idleTimeout) {
        self.connection = connection
        client = ProxyClient(configuration: configuration)
        self.idleTimeout = max(0.01, idleTimeout)
    }

    func start(queue: DispatchQueue, established: @escaping @Sendable () -> Void = {},
               finished: @escaping @Sendable () -> Void) {
        let work = Task {
            defer { connection.cancel(); client.cancel(); finished() }
            do {
                let reader = LANProxyReader(connection)
                let upstream = try await withDialDeadline(.seconds(15), onExpiry: { self.cancel() },
                    error: { LANProxyError.timedOut }, discardingLateResult: { $0.cancel() }) {
                    try await self.handshake(reader)
                }
                defer { upstream.cancel() }
                established()
                activity.touch()
                let sessionDeadline = MonotonicClock.now + 3600
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while let data = try await reader.chunk() {
                            try await upstream.send(data)
                            self.activity.touch()
                        }
                    }
                    group.addTask {
                        while let data = try await upstream.receive() {
                            try await self.send(data)
                            self.activity.touch()
                        }
                    }
                    group.addTask {
                        while true {
                            let remaining = min(sessionDeadline - MonotonicClock.now,
                                                self.activity.remaining(timeout: self.idleTimeout))
                            guard remaining > 0 else { throw LANProxyError.timedOut }
                            try await Task.sleep(for: .seconds(remaining))
                        }
                    }
                    defer { group.cancelAll(); self.connection.cancel(); upstream.cancel() }
                    _ = try await group.next()
                }
            } catch {
                if !Task.isCancelled { lanLogger.report("LAN client closed", error: error) }
            }
        }
        task.withLock { $0 = work }
        connection.start(queue: queue)
    }

    private func handshake(_ reader: LANProxyReader) async throws -> ProxyConnection {
        let first = try await reader.exact(1)[0]
        guard first == 5 else { throw LANProxyError.unsupportedCommand }
        do {
            let count = Int(try await reader.exact(1)[0])
            let methods = try await reader.exact(count)
            guard methods.contains(0) else {
                try await send(Data([5, 255])); throw LANProxyError.unsupportedCommand
            }
            try await send(Data([5, 0]))
            let header = try await reader.exact(4)
            guard header[0] == 5, header[2] == 0 else { throw LANProxyError.malformedRequest }
            guard header[1] == 1 else {
                try await socksReply(7); throw LANProxyError.unsupportedCommand
            }
            let host: String
            switch header[3] {
            case 1:
                host = try await reader.exact(4).map(String.init).joined(separator: ".")
            case 3:
                let length = Int(try await reader.exact(1)[0])
                guard let value = String(data: try await reader.exact(length), encoding: .utf8) else {
                    throw LANProxyError.malformedRequest
                }
                host = value
            default:
                try await socksReply(8); throw LANProxyError.unsupportedCommand
            }
            try LANProxyRequest.validateHost(host)
            let bytes = try await reader.exact(2)
            let port = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            guard port > 0 else { throw LANProxyError.malformedRequest }
            let upstream: ProxyConnection
            do { upstream = try await client.connect(to: host, port: port) }
            catch { try? await socksReply(5); throw error }
            do { try await socksReply(0) } catch { upstream.cancel(); throw error }
            return upstream
        }
    }

    private func socksReply(_ code: UInt8) async throws {
        try await send(Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]))
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func cancel() {
        connection.cancel()
        client.cancel()
        task.withLock { $0?.cancel() }
    }
}

private actor LANProxyReader {
    let connection: NWConnection
    var buffer = LANProxyReadBuffer()
    init(_ connection: NWConnection) { self.connection = connection }

    func exact(_ count: Int) async throws -> Data {
        guard count > 0, count <= 255 else { throw LANProxyError.malformedRequest }
        while buffer.availableBytes < count {
            guard let data = try await receive() else { throw LANProxyError.closed }
            buffer.append(data)
        }
        return buffer.take(count)
    }

    func chunk() async throws -> Data? {
        if buffer.availableBytes > 0 { return buffer.take(buffer.availableBytes) }
        return try await receive()
    }

    private func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: LANProxyLimits.readBytes) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data?.isEmpty == false ? data : nil) }
            }
        }
    }
}

/// Consuming handshake bytes moves a cursor instead of copying the remaining
/// receive buffer once per byte. Consumed backing storage is released on drain.
nonisolated struct LANProxyReadBuffer {
    private var data = Data()
    private var offset = 0
    var availableBytes: Int { data.count - offset }

    mutating func append(_ bytes: Data) {
        if offset > 0 {
            data = Data(data.dropFirst(offset))
            offset = 0
        }
        data.append(bytes)
    }

    mutating func take(_ count: Int) -> Data {
        precondition(count >= 0 && count <= availableBytes)
        if offset == 0, count == data.count {
            let result = data
            data = Data()
            return result
        }
        let result = Data(data[offset..<(offset + count)])
        offset += count
        if offset == data.count { data = Data(); offset = 0 }
        return result
    }
}

nonisolated final class LANProxyActivity: Sendable {
    private let lastActivity = Mutex(MonotonicClock.now)
    func touch(now: TimeInterval = MonotonicClock.now) { lastActivity.withLock { $0 = now } }
    func remaining(timeout: TimeInterval, now: TimeInterval = MonotonicClock.now) -> TimeInterval {
        lastActivity.withLock { max(0, timeout - max(0, now - $0)) }
    }
}
