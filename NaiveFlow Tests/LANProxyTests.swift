import Foundation
import Testing
@testable import NaiveFlow

struct LANProxyTests {
    @Test func disabledSharingDoesNotConstructAServer() {
        let localOn = LANProxySettings(enabled: true)
        let vetoed = LANProxyServer.makeIfEnabled(settings: localOn, profileAllowed: false) { nil }
        #expect(vetoed == nil)
        let localOff = LANProxyServer.makeIfEnabled(settings: LANProxySettings(), profileAllowed: true) { nil }
        #expect(localOff == nil)
    }

    @Test func profileVetoIsCapturedAndCanBeRolledBackWithoutChangingTheLocalSwitch() {
        let before = ["lanProxyAllowed": RuntimePreferenceValue.boolean(true)]
        let disabled = AWCore.captureRuntimePreferences(base: before) {
            ConfigurationSettingsBindings.write("lan-proxy-enabled", .flag(false))
            #expect(!AWCore.getLANProxyAllowed())
        }
        #expect(disabled["lanProxyAllowed"] == .boolean(false))
        RuntimePreferenceContext.$capture.withValue(RuntimePreferenceCapture(disabled)) {
            #expect(!AWCore.getLANProxyAllowed())
            let server = LANProxyServer.makeIfEnabled(settings: LANProxySettings(enabled: true),
                                                      profileAllowed: AWCore.getLANProxyAllowed()) { nil }
            #expect(server == nil)
        }
        RuntimePreferenceContext.$capture.withValue(RuntimePreferenceCapture(before)) {
            #expect(AWCore.getLANProxyAllowed())
        }
        let oldBundle = RuntimePreferenceCapture(["lanProxyAllowed": .absent])
        RuntimePreferenceContext.$capture.withValue(oldBundle) {
            #expect(AWCore.getLANProxyAllowed())
        }
    }

    @Test func profileLANFlagCompilesAndRejectsInvalidValues() {
        let result = TextConfigurationPipeline.process(text: "[General]\nlan-proxy-enabled = false")
        #expect(result.isActivatable)
        #expect(result.compiled.settings["lan-proxy-enabled"] == .flag(false))
        let invalid = TextConfigurationPipeline.process(text: "[General]\nlan-proxy-enabled = maybe")
        #expect(!invalid.isActivatable)
    }

    @Test func admissionLimitsTotalAndPerDeviceConnections() {
        var slots = LANProxyAdmission()
        func reserve(_ id: UUID, peer: String) -> Bool { slots.reserve(id, peer: peer) }
        var ids: [UUID] = []
        for device in 1...3 {
            for _ in 0..<4 {
                let id = UUID()
                #expect(reserve(id, peer: "192.168.1.\(device)"))
                slots.established(id)
                ids.append(id)
            }
            #expect(!reserve(UUID(), peer: "192.168.1.\(device)"))
        }
        #expect(slots.connectionCount == 12)
        #expect(!reserve(UUID(), peer: "192.168.1.5"))
        slots.release(ids[0])
        #expect(!reserve(UUID(), peer: "192.168.1.5")) // first device is still active
        for id in ids[1..<4] { slots.release(id) }
        #expect(reserve(UUID(), peer: "192.168.1.5"))
        #expect(slots.deviceCount == 3)
    }

    @Test func pendingHandshakesAreBoundedAndReleasedOnSuccessOrFailure() {
        var slots = LANProxyAdmission()
        func reserve(_ id: UUID, peer: String) -> Bool { slots.reserve(id, peer: peer) }
        let ids = (0..<4).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            #expect(reserve(id, peer: "192.168.1.\(index % 3 + 1)"))
        }
        #expect(slots.handshakeCount == 4)
        #expect(!reserve(UUID(), peer: "192.168.1.5"))
        slots.established(ids[0])
        #expect(slots.connectionCount == 4)
        let replacement = UUID()
        #expect(reserve(replacement, peer: "192.168.1.1"))
        slots.release(ids[1])
        #expect(slots.handshakeCount == 3)
        #expect(reserve(UUID(), peer: "192.168.1.2"))
    }

    @Test func lateCallbacksCannotReleaseOtherConnectionSlots() {
        var slots = LANProxyAdmission()
        func reserve(_ id: UUID, peer: String) -> Bool { slots.reserve(id, peer: peer) }
        let old = UUID()
        #expect(reserve(old, peer: "192.168.1.1"))
        slots = LANProxyAdmission() // listener reset
        let current = UUID()
        #expect(reserve(current, peer: "192.168.1.1"))
        slots.release(old)
        slots.established(old)
        slots.release(old)
        #expect(slots.connectionCount == 1)
        #expect(slots.handshakeCount == 1)
        #expect(!reserve(current, peer: "192.168.1.1"))
        slots.release(current)
        #expect(slots.connectionCount == 0)
        #expect(slots.handshakeCount == 0)
    }

    @Test func fourthDeviceIsRejectedEvenWhenConnectionSlotsRemain() {
        var slots = LANProxyAdmission()
        func reserve(_ id: UUID, peer: String) -> Bool { slots.reserve(id, peer: peer) }
        let first = UUID(), second = UUID()
        #expect(reserve(first, peer: "192.168.1.1"))
        slots.established(first)
        #expect(reserve(second, peer: "192.168.1.1"))
        slots.established(second)
        for peer in ["192.168.1.2", "192.168.1.3"] {
            let id = UUID()
            #expect(reserve(id, peer: peer))
            slots.established(id)
        }
        #expect(slots.deviceCount == 3)
        #expect(slots.connectionCount == 4)
        #expect(!reserve(UUID(), peer: "192.168.1.4"))
        slots.release(first)
        #expect(!reserve(UUID(), peer: "192.168.1.4"))
        slots.release(second)
        #expect(reserve(UUID(), peer: "192.168.1.4"))
        #expect(slots.deviceCount == 3)
    }

    @Test func sharingAcceptsOnlyPrivateIPv4Clients() {
        for peer in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.20"] {
            #expect(LANProxyNetwork.isPrivate(peer))
        }
        for peer in ["8.8.8.8", "127.0.0.1", "169.254.1.1", "172.32.0.1", "::1", "client.example"] {
            #expect(!LANProxyNetwork.isPrivate(peer))
            var slots = LANProxyAdmission()
            let accepted = slots.reserve(UUID(), peer: peer)
            #expect(!accepted)
            #expect(slots.deviceCount == 0)
        }
    }

    @Test func oldACLSettingsDecodeWithoutRetainingTheAddressList() throws {
        let legacy = Data(#"{"enabled":true,"port":8080,"allowedClients":["192.168.1.20"]}"#.utf8)
        let settings = try JSONDecoder().decode(LANProxySettings.self, from: legacy)
        #expect(settings.enabled)
        #expect(settings.port == 8080)
        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["allowedClients"] == nil)
    }

}

// Real loopback sockets exercise segmented handshakes and binary relay without
// remote proxy nodes, entitlements, or a developer account.
import Network
import Synchronization

extension LANProxyTests {
    @Test
    func relaysSOCKS5TCP() async throws {
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
            // Exceeds the inbound read limit; SOCKS5 must stream it intact.
            let payload = Data((0..<(48 * 1024)).map { UInt8($0 % 256) })
            // Split greeting; coalesce CONNECT with initial payload.
            try await tcp.send(Data([5]))
            try await tcp.send(Data([1, 0]))
            #expect(try await wire.exact(2) == Data([5, 0]))
            var request = Data([5, 1, 0, 1, 127, 0, 0, 1,
                                UInt8(echoPort >> 8), UInt8(echoPort & 255)])
            request.append(payload)
            try await tcp.send(request)
            #expect(try await wire.exact(10) == Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
            #expect(try await wire.exact(payload.count) == payload)
        }
    }

    @Test func idleClientClosesAndReleasesItsSocket() async throws {
        let echo = try LANTestListener()
        let echoPort = try await echo.start()
        defer { echo.cancel() }
        let proxy = try LANTestListener(proxy: true, idleTimeout: 0.05)
        let port = try await proxy.start()
        defer { proxy.cancel() }
        let tcp = TCPTransport(host: "127.0.0.1", port: port)
        defer { tcp.cancel() }
        try await withDialDeadline(.seconds(3), onExpiry: { tcp.cancel() }, error: { LANProxyError.timedOut }) {
            try await tcp.connect()
            let wire = LANTestReader(tcp)
            try await tcp.send(Data([5, 1, 0]))
            #expect(try await wire.exact(2) == Data([5, 0]))
            try await tcp.send(Data([5, 1, 0, 1, 127, 0, 0, 1,
                                     UInt8(echoPort >> 8), UInt8(echoPort & 255)]))
            #expect(try await wire.exact(10) == Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
            if case .bytes = try await tcp.receive() {
                Issue.record("Idle proxy socket should close without additional data")
            }
        }
    }

    @Test func httpProxyIsRejectedBeforeOutboundDial() async throws {
        let proxy = try LANTestListener(proxy: true)
        let port = try await proxy.start()
        defer { proxy.cancel() }
        let tcp = TCPTransport(host: "127.0.0.1", port: port)
        defer { tcp.cancel() }
        try await withDialDeadline(.seconds(3), onExpiry: { tcp.cancel() }, error: { LANProxyError.timedOut }) {
            try await tcp.connect()
            try await tcp.send(Data("CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n".utf8))
            // Receiving EOF or a reset is valid rejection. A proxy reply would
            // mean the request incorrectly reached the outbound dialing stage.
            let data: Data?
            do {
                switch try await tcp.receive() {
                case .bytes(let bytes): data = bytes
                case .end: data = nil
                }
            } catch { data = nil }
            #expect(data == nil)
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
    let idleTimeout: TimeInterval
    let queue = DispatchQueue(label: "lan.test")
    private struct State {
        var sessions: [LANProxySession] = []
        var connections: [NWConnection] = []
    }
    private let state = Mutex(State())

    init(proxy: Bool = false, idleTimeout: TimeInterval = LANProxyLimits.idleTimeout) throws {
        self.proxy = proxy
        self.idleTimeout = idleTimeout
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
                let session = LANProxySession(connection: connection, configuration: direct, idleTimeout: idleTimeout)
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
