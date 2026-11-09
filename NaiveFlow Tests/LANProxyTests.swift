import Foundation
import Testing
@testable import NaiveFlow

struct LANProxyTests {
    @Test func aclDeniesByDefaultAndRejectsPublicPeers() {
        #expect(!LANProxyACL([]).allows("192.168.1.20"))
        let acl = LANProxyACL(["0.0.0.0/0"])
        #expect(acl.allows("192.168.1.20"))
        #expect(!acl.allows("8.8.8.8"))
        #expect(!acl.allows("127.0.0.1"))
        #expect(!acl.allows("169.254.1.1"))
        #expect(!acl.allows("::1"))
        #expect(!acl.allows("client.example"))
    }

    @Test func aclMatchesAddressesAndCIDRBoundaries() {
        let acl = LANProxyACL(["192.168.1.20", "10.20.0.0/16", "172.16.0.0/12"])
        #expect(acl.allows("192.168.1.20"))
        #expect(!acl.allows("192.168.1.21"))
        #expect(acl.allows("10.20.255.254"))
        #expect(!acl.allows("10.21.0.1"))
        #expect(acl.allows("172.31.255.254"))
        #expect(!acl.allows("172.32.0.1"))
    }

    @Test func invalidACLEntryFailsClosed() {
        #expect(!LANProxyACL(["192.168.1.20", "bad"]).allows("192.168.1.20"))
        #expect(!LANProxyACL(["192.168.1.0/33"]).allows("192.168.1.20"))
        #expect(!LANProxyACL(["192.168.1.0/-1"]).allows("192.168.1.20"))
    }

    @Test func connectParsesDomainAndIPv4Targets() throws {
        let domain = try LANProxyRequest.connectTarget(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8))
        #expect(domain.0 == "example.com")
        #expect(domain.1 == 443)
        let ip = try LANProxyRequest.connectTarget(Data("CONNECT 192.0.2.1:8443 HTTP/1.0\r\n\r\n".utf8))
        #expect(ip.0 == "192.0.2.1")
        #expect(ip.1 == 8443)
    }

    @Test(arguments: [
        "GET http://example.com/ HTTP/1.1\r\n\r\n",
        "CONNECT example.com:0 HTTP/1.1\r\n\r\n",
        "CONNECT example.com:65536 HTTP/1.1\r\n\r\n",
        "CONNECT user@example.com:443 HTTP/1.1\r\n\r\n",
        "CONNECT [::1]:443 HTTP/1.1\r\n\r\n",
        "CONNECT example.com:443 HTTP/9\r\n\r\n",
        "CONNECT :443 HTTP/1.1\r\n\r\n"
    ]) func connectRejectsMalformedOrUnsupportedTargets(_ request: String) {
        #expect(throws: (any Error).self) { try LANProxyRequest.connectTarget(Data(request.utf8)) }
    }
}

// Real loopback sockets exercise segmented handshakes and binary relay without
// remote proxy nodes, entitlements, or a developer account.
import Network
import Synchronization

extension LANProxyTests {
    @Test(arguments: [false, true])
    func relaysTCPThroughBothInboundProtocols(socks: Bool) async throws {
        let echo = try LANTestListener()
        let echoPort = try await echo.start()
        defer { echo.cancel() }
        let proxy = try LANTestListener(proxy: true)
        let proxyPort = try await proxy.start()
        defer { proxy.cancel() }
        let tcp = TCPTransport(host: "127.0.0.1", port: proxyPort)
        defer { tcp.cancel() }
        try await withDialDeadline(.seconds(10), onExpiry: { tcp.cancel() },
                                  error: { LANProxyError.timedOut }) {
            try await tcp.connect()
            let wire = LANTestReader(tcp)
            let payload = Data([0, 1, 2, 255, 13, 10])
            if socks {
                // Split greeting; coalesce CONNECT with initial payload.
                try await tcp.send(Data([5]))
                try await tcp.send(Data([1, 0]))
                #expect(try await wire.exact(2) == Data([5, 0]))
                var request = Data([5, 1, 0, 1, 127, 0, 0, 1,
                                    UInt8(echoPort >> 8), UInt8(echoPort & 255)])
                request.append(payload)
                try await tcp.send(request)
                #expect(try await wire.exact(10) == Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
            } else {
                try await tcp.send(Data("CON".utf8))
                var request = Data("NECT 127.0.0.1:\(echoPort) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
                request.append(payload)
                try await tcp.send(request)
                let reply = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                #expect(try await wire.exact(reply.count) == reply)
            }
            #expect(try await wire.exact(payload.count) == payload)
        }
    }

    @Test func socksRejectsUDPAssociate() async throws {
        let proxy = try LANTestListener(proxy: true)
        let port = try await proxy.start()
        defer { proxy.cancel() }
        let tcp = TCPTransport(host: "127.0.0.1", port: port)
        defer { tcp.cancel() }
        try await withDialDeadline(.seconds(10), onExpiry: { tcp.cancel() }, error: { LANProxyError.timedOut }) {
            try await tcp.connect()
            let wire = LANTestReader(tcp)
            try await tcp.send(Data([5, 1, 0]))
            #expect(try await wire.exact(2) == Data([5, 0]))
            try await tcp.send(Data([5, 3, 0, 1]))
            #expect(try await wire.exact(10) == Data([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]))
        }
    }
}

private actor LANTestReader {
    let tcp: TCPTransport
    var buffer = Data()
    init(_ tcp: TCPTransport) { self.tcp = tcp }
    func exact(_ count: Int) async throws -> Data {
        while buffer.count < count {
            guard case .bytes(let chunk) = try await tcp.receive() else { throw LANProxyError.closed }
            buffer.append(chunk)
        }
        let result = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return result
    }
}

nonisolated private final class LANTestListener: Sendable {
    let listener: NWListener
    let proxy: Bool
    let queue = DispatchQueue(label: "lan.test")
    private struct State {
        var sessions: [LANProxySession] = []
        var connections: [NWConnection] = []
    }
    private let state = Mutex(State())

    init(proxy: Bool = false) throws {
        self.proxy = proxy
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        let (stream, signal) = AsyncThrowingStream<UInt16, Error>.makeStream()
        listener.stateUpdateHandler = { [listener] value in
            switch value {
            case .ready:
                if let port = listener.port { signal.yield(port.rawValue); signal.finish() }
            case .failed(let error): signal.finish(throwing: error)
            case .cancelled: signal.finish(throwing: LANProxyError.closed)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            if proxy {
                let direct = ProxyConfiguration(name: "test", serverAddress: "", serverPort: 0,
                                                outbound: .direct(DirectConfiguration()))
                let session = LANProxySession(connection: connection, configuration: direct)
                state.withLock { $0.sessions.append(session) }
                session.start(queue: queue, finished: {})
            } else {
                state.withLock { $0.connections.append(connection) }
                connection.start(queue: queue)
                Self.echo(connection)
            }
        }
        listener.start(queue: queue)
        for try await port in stream { return port }
        throw LANProxyError.closed
    }
    private static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, complete, error in
            guard let data, !data.isEmpty, error == nil else { connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed { error in
                if error == nil, !complete { echo(connection) } else { connection.cancel() }
            })
        }
    }
    func cancel() {
        listener.stateUpdateHandler = nil
        listener.cancel()
        state.withLock {
            $0.sessions.forEach { $0.cancel() }
            $0.connections.forEach { $0.cancel() }
            $0.sessions = []; $0.connections = []
        }
    }
}
