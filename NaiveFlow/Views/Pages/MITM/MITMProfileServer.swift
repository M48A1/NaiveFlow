import Foundation
import Network
import Synchronization

/// A temporary, loopback-only endpoint for Settings/Safari to install the CA.
actor MITMProfileServer {
    static let shared = MITMProfileServer()
    private var listener: MITMProfileListener?
    private var shutdownTask: Task<Void, Never>?
    private init() {}

    func start(payload: Data) async throws -> URL {
        stop()
        let created = try MITMProfileListener(payload: payload)
        listener = created
        do {
            let port = try await created.start()
            // start() suspends; another request or stop may have replaced us.
            guard listener === created else {
                created.cancel()
                throw NaiveFlowError.mitm(.profileServerBindFailed)
            }
            shutdownTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                await self?.expire(created)
            }
            return URL(string: "http://127.0.0.1:\(port.rawValue)/NaiveFlowMITMRoot.mobileconfig")!
        } catch {
            created.cancel()
            if listener === created { stop() }
            throw NaiveFlowError.mitm(.profileServerBindFailed)
        }
    }

    func stop() {
        shutdownTask?.cancel()
        shutdownTask = nil
        listener?.cancel()
        listener = nil
    }

    private func expire(_ expected: MITMProfileListener) {
        guard listener === expected else { return }
        stop()
    }
}

/// Incremental request parsing keeps the same bounds on all supported OSes.
nonisolated struct MITMProfileRequest: Sendable {
    static let maximumHeaderBytes = 16_384
    enum Progress: Equatable { case incomplete, respond(headOnly: Bool), reject }
    private var buffer = Data()

    mutating func append(_ data: Data) -> Progress {
        guard data.count <= Self.maximumHeaderBytes - buffer.count else { return .reject }
        buffer.append(data)
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let text = String(data: buffer[..<end.lowerBound], encoding: .ascii),
              let first = text.components(separatedBy: "\r\n").first else { return .reject }
        let fields = first.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD",
              fields[1] == "/NaiveFlowMITMRoot.mobileconfig",
              fields[2] == "HTTP/1.0" || fields[2] == "HTTP/1.1" else { return .reject }
        return .respond(headOnly: fields[0] == "HEAD")
    }
}

nonisolated final class MITMProfileListener: Sendable {
    static let maximumConnections = 4
    private let listener: NWListener
    private let payload: Data
    private let requestTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.argsment.NaiveFlow.MITMProfileServer")

    private struct Client {
        let connection: NWConnection
        let timeout: Task<Void, Never>
    }
    private struct State {
        var clients: [ObjectIdentifier: Client] = [:]
        var cancelled = false
    }
    private let state = Mutex(State())

    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return parameters
    }

    init(payload: Data, requestTimeout: TimeInterval = 5) throws {
        self.payload = payload
        self.requestTimeout = requestTimeout
        listener = try NWListener(using: Self.parameters())
    }

    deinit { cancel() }
    var activeConnectionCount: Int { state.withLock { $0.clients.count } }

    func start() async throws -> NWEndpoint.Port {
        let (ports, signal) = AsyncThrowingStream.makeStream(of: NWEndpoint.Port.self)
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port { signal.yield(port); signal.finish() }
                else { signal.finish(throwing: NaiveFlowError.mitm(.profileServerBindFailed)) }
            case .failed(let error): signal.finish(throwing: error)
            case .cancelled: signal.finish(throwing: NaiveFlowError.mitm(.profileServerBindFailed))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.adopt(connection)
        }
        listener.start(queue: queue)
        return try await withTaskCancellationHandler {
            for try await port in ports { return port }
            throw NaiveFlowError.mitm(.profileServerBindFailed)
        } onCancel: { self.cancel() }
    }

    func cancel() {
        let clients = state.withLock { state in
            state.cancelled = true
            let clients = Array(state.clients.values)
            state.clients.removeAll()
            return clients
        }
        listener.cancel()
        for client in clients { client.timeout.cancel(); client.connection.cancel() }
    }

    private func adopt(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let delay = requestTimeout
        let accepted = state.withLock { state in
            guard !state.cancelled, state.clients.count < Self.maximumConnections else { return false }
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.close(id)
            }
            state.clients[id] = Client(connection: connection, timeout: timeout)
            return true
        }
        guard accepted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(id)
            default: break
            }
        }
        connection.start(queue: queue)
        serve(connection, request: MITMProfileRequest())
    }

    private func serve(_ connection: NWConnection, request: MITMProfileRequest) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, complete, error in
            guard let self else { connection.cancel(); return }
            let id = ObjectIdentifier(connection)
            guard error == nil else { self.close(id); return }
            var request = request
            switch request.append(content ?? Data()) {
            case .incomplete:
                if complete { self.close(id) }
                else { self.serve(connection, request: request) }
            case .reject: self.close(id)
            case .respond(let headOnly):
                let response = self.httpResponse(headOnly: headOnly)
                connection.send(content: response, contentContext: .finalMessage, completion: .contentProcessed { [weak self] _ in
                    self?.close(id)
                })
            }
        }
    }

    private func httpResponse(headOnly: Bool) -> Data {
        var response = Data(("HTTP/1.1 200 OK\r\n" +
            "Content-Type: application/x-apple-aspen-config\r\n" +
            "Content-Disposition: attachment; filename=\"NaiveFlowMITMRoot.mobileconfig\"\r\n" +
            "Content-Length: \(payload.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n").utf8)
        if !headOnly { response.append(payload) }
        return response
    }

    private func close(_ id: ObjectIdentifier) {
        guard let client = state.withLock({ $0.clients.removeValue(forKey: id) }) else { return }
        client.timeout.cancel()
        client.connection.cancel()
    }
}
