import Foundation
import Network
import Synchronization

nonisolated private let lanLogger = NaiveFlowLogger(category: "LANProxy")

/// One mixed TCP port: HTTP CONNECT and SOCKS5 CONNECT. UDP ASSOCIATE and
/// unauthenticated peers outside the explicit private-address ACL are rejected.
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
    }
    private let state = Mutex(State())

    init(settings: LANProxySettings, configuration: @escaping ConfigurationSource) {
        self.settings = settings
        source = configuration
    }

    func start() {
        guard settings.enabled, settings.port >= 1024 else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.bind(address: path.status == .satisfied ? LANProxyACL.wifiAddress() : nil)
        }
        monitor.start(queue: queue)
    }

    private func bind(address: String?) {
        let old = state.withLock { state -> (NWListener?, [LANProxySession])? in
            guard !state.stopped, state.address != address else { return nil }
            let old = (state.listener, Array(state.sessions.values))
            state.listener = nil
            state.sessions.removeAll()
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
              LANProxyACL(settings.allowedClients).allows(String(describing: host)),
              let configuration = source() else { connection.cancel(); return }
        let id = UUID()
        let session = LANProxySession(connection: connection, configuration: configuration)
        let accepted = state.withLock { state in
            guard !state.stopped, state.listener != nil, state.sessions.count < 64 else { return false }
            state.sessions[id] = session
            return true
        }
        guard accepted else { connection.cancel(); return }
        session.start(queue: queue) { [weak self] in
            _ = self?.state.withLock { $0.sessions.removeValue(forKey: id) }
        }
    }

    func cancel() {
        monitor.cancel()
        let resources = state.withLock { state in
            state.stopped = true
            let resources = (state.listener, Array(state.sessions.values))
            state.listener = nil
            state.sessions.removeAll()
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

    init(connection: NWConnection, configuration: ProxyConfiguration) {
        self.connection = connection
        client = ProxyClient(configuration: configuration)
    }

    func start(queue: DispatchQueue, finished: @escaping @Sendable () -> Void) {
        let work = Task {
            defer { connection.cancel(); client.cancel(); finished() }
            do {
                let reader = LANProxyReader(connection)
                let upstream = try await withDialDeadline(.seconds(15), onExpiry: { self.cancel() },
                    error: { LANProxyError.timedOut }, discardingLateResult: { $0.cancel() }) {
                    try await self.handshake(reader)
                }
                defer { upstream.cancel() }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while let data = try await reader.chunk() { try await upstream.send(data) }
                    }
                    group.addTask {
                        while let data = try await upstream.receive() { try await self.send(data) }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(3600))
                        throw LANProxyError.timedOut
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
        if first == 5 {
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
        var header = Data([first])
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 8192 else { throw LANProxyError.malformedRequest }
            header.append(try await reader.exact(1))
        }
        let target: (String, UInt16)
        do { target = try LANProxyRequest.connectTarget(header) }
        catch {
            try? await send(Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
            throw error
        }
        let upstream: ProxyConnection
        do { upstream = try await client.connect(to: target.0, port: target.1) }
        catch {
            try? await send(Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
            throw error
        }
        do { try await send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) }
        catch { upstream.cancel(); throw error }
        return upstream
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
    var buffer = Data()
    init(_ connection: NWConnection) { self.connection = connection }

    func exact(_ count: Int) async throws -> Data {
        guard count > 0, count <= 8192 else { throw LANProxyError.malformedRequest }
        while buffer.count < count {
            guard let data = try await receive() else { throw LANProxyError.closed }
            buffer.append(data)
        }
        let result = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return result
    }

    func chunk() async throws -> Data? {
        if !buffer.isEmpty { let result = buffer; buffer = Data(); return result }
        return try await receive()
    }

    private func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data?.isEmpty == false ? data : nil) }
            }
        }
    }
}
