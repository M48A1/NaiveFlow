import Foundation
import Observation

@MainActor
@Observable
final class ClientConnectionDiagnostics {
    struct Step: Identifiable {
        enum State { case pending, running, passed, failed, skipped }
        let id: Int
        let title: String
        var state = State.pending
        var detail = ""
    }
    private(set) var steps: [Step] = []
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func cancel() { task?.cancel() }

    func start(node: ProxyConfiguration, target: LatencyTarget) {
        guard !isRunning else { return }
        isRunning = true
        steps = ["Node DNS", "Node TCP Port", "Node TLS", "Proxy Handshake", "Target TLS", "Target HTTP"].enumerated().map { Step(id: $0.offset, title: $0.element) }
        task = Task {
            defer { isRunning = false; task = nil }
            let entry = node.chain?.first ?? node
            var resolved = node
            do {
                if entry.isDirect { skip(0, "Direct connection has no proxy server.") }
                else {
                    steps[0].state = .running
                    let addresses = await DNSResolver.proxies.resolveAll(entry.serverAddress, forceFresh: true)
                    try Task.checkCancellation()
                    guard let address = addresses.first else {
                        steps[0].state = .failed; steps[0].detail = "The configured proxy DNS returned no usable IPv4 address."
                        throw ClientFailure("DNS failed")
                    }
                    steps[0].state = .passed; steps[0].detail = addresses.joined(separator: ", ")
                    if let chain = node.chain { resolved = node.withChain([entry.withResolvedIP(address)] + chain.dropFirst()) }
                    else { resolved = node.withResolvedIP(address) }
                }
                let resolvedEntry = resolved.chain?.first ?? resolved
                if entry.isDirect { skip(1, "Checked by the target connection.") }
                else if entry.upstreamNetwork(for: .tcp) == .udp { skip(1, "UDP/QUIC transport is checked during the proxy handshake.") }
                else {
                    let tcp = TCPTransport(host: resolvedEntry.connectAddress, port: entry.serverPort)
                    defer { tcp.cancel() }
                    try await stage(1) {
                        try await withDialDeadline(.seconds(10), onExpiry: { tcp.cancel() }, error: { URLError(.timedOut) }) { try await tcp.connect() }
                        return "TCP connection established."
                    }
                }
                let nodeTLS: TLSConfiguration?
                if case .vless(let vless) = entry.outbound { nodeTLS = vless.security.tlsConfiguration }
                else { nodeTLS = entry.genericSecurityLayer.tlsConfiguration }
                if let nodeTLS, entry.upstreamNetwork(for: .tcp) != .udp {
                    let tls = TLSClient(configuration: nodeTLS)
                    defer { tls.cancel() }
                    try await stage(2) {
                        let connection = try await withDialDeadline(.seconds(10), onExpiry: { tls.cancel() }, error: { URLError(.timedOut) }) {
                            try await tls.connect(host: resolvedEntry.connectAddress, port: entry.serverPort)
                        }
                        connection.cancel()
                        return "TLS completed using this node's configured certificate policy."
                    }
                } else { skip(2, "Not independently applicable. Integrated TLS/Reality is checked during the proxy handshake.") }
                let client = ProxyClient(configuration: resolved, useResolvedAddressForDirectDial: true)
                defer { client.cancel() }
                var connection: (any ProxyConnection)?
                try await stage(3) {
                    connection = try await withDialDeadline(.seconds(15), onExpiry: { client.cancel() }, error: { URLError(.timedOut) }) {
                        try await client.connect(to: target.host, port: target.port)
                    }
                    return node.chain == nil ? "Transport and proxy handshake completed to the target." : "The complete configured proxy chain connected to the target."
                }
                guard let tunnel = connection else { throw ClientFailure("No connection returned.") }
                var http: any ProxyConnection = tunnel
                if target.isSecure {
                    let tls = TLSClient(configuration: TLSConfiguration(serverName: target.host, alpn: ["http/1.1"]))
                    defer { tls.cancel() }
                    try await stage(4) {
                        let record = try await withDialDeadline(.seconds(10), onExpiry: { tls.cancel() }, error: { URLError(.timedOut) }) {
                            try await tls.connect(overTunnel: tunnel)
                        }
                        http = TLSProxyConnection(tlsConnection: record)
                        return "Target certificate and TLS handshake verified."
                    }
                    try await checkHTTP(http, target: target)
                } else {
                    skip(4, "The test target uses HTTP.")
                    try await checkHTTP(http, target: target)
                }
            } catch {
                if Task.isCancelled {
                    for index in steps.indices where steps[index].state == .running || steps[index].state == .pending {
                        steps[index].state = .skipped; steps[index].detail = "Cancelled"
                    }
                } else {
                    for index in steps.indices where steps[index].state == .pending {
                        steps[index].state = .skipped; steps[index].detail = "An earlier step failed."
                    }
                }
            }
        }
    }

    private func checkHTTP(_ connection: any ProxyConnection, target: LatencyTarget) async throws {
        try await stage(5) {
            try await withDialDeadline(.seconds(10), onExpiry: { connection.cancel() }, error: { URLError(.timedOut) }) {
                let request = "HEAD \(target.path) HTTP/1.1\r\nHost: \(target.authority)\r\nConnection: close\r\n\r\n"
                try await connection.send(Data(request.utf8))
                var response = LatencyProbeResponseReader()
                try await response.readSuccess(from: connection)
            }
            return "The target returned a successful HTTP response."
        }
    }
    private func skip(_ index: Int, _ reason: String) { steps[index].state = .skipped; steps[index].detail = reason }
    private func stage(_ index: Int, operation: () async throws -> String) async throws {
        try Task.checkCancellation()
        steps[index].state = .running
        let start = ContinuousClock.now
        do {
            let detail = try await operation()
            try Task.checkCancellation()
            let elapsed = ContinuousClock.now - start
            let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            steps[index].detail = "\(milliseconds) ms · " + detail; steps[index].state = .passed
        } catch { steps[index].detail = error.localizedDescription; steps[index].state = .failed; throw error }
    }
}
