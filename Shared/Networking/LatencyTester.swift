//
//  LatencyTester.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation

nonisolated private let logger = NaiveFlowLogger(category: "LatencyTester")

/// The endpoint an end-to-end latency probe measures against.
///
/// Carrying the full URL - scheme, host, port, path and query - keeps a probe on
/// the target the user configured instead of always issuing a plaintext `HEAD /`.
/// An `https` target is reached through a real TLS session over the tunnel, and
/// any `2xx` response (including the `204` a `/generate_204` endpoint returns)
/// counts as reachable.
nonisolated struct LatencyTarget: Sendable, Hashable {
    enum Scheme: String, Sendable, Hashable {
        case http
        case https

        var defaultPort: UInt16 { self == .https ? 443 : 80 }
    }

    let scheme: Scheme
    let host: String
    let port: UInt16
    /// Origin-form request target, e.g. `/generate_204` or `/probe?x=1`.
    let path: String

    init(scheme: Scheme, host: String, port: UInt16, path: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path.hasPrefix("/") ? path : "/" + path
    }

    /// Parses a configured probe URL. Returns `nil` when it is not a dialable
    /// http(s) target (missing scheme or host), letting the caller fall back to
    /// `captivePortal`.
    init?(url: String) {
        guard let components = URLComponents(string: url),
              let rawScheme = components.scheme?.lowercased(),
              let scheme = Scheme(rawValue: rawScheme),
              let host = components.host, !host.isEmpty else { return nil }

        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            path += "?" + query
        }
        let port = components.port.map { UInt16(clamping: $0) } ?? scheme.defaultPort
        self.init(scheme: scheme, host: host, port: port, path: path)
    }

    var isSecure: Bool { scheme == .https }

    /// `Host` header value, eliding the scheme's default port.
    var authority: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return port == scheme.defaultPort ? hostPart : "\(hostPart):\(port)"
    }

    /// The built-in default: Apple's captive-portal probe, whose `/` returns 200.
    static let captivePortal = LatencyTarget(scheme: .http, host: "captive.apple.com", port: 80, path: "/")
}

nonisolated enum LatencyTester {
    private static let timeout: Duration = .seconds(10)

    nonisolated static func test(
        _ configuration: ProxyConfiguration,
        target: LatencyTarget = .captivePortal
    ) async -> LatencyResult {
        ConnectionMetrics.shared.suspendRecording()
        defer { ConnectionMetrics.shared.resumeRecording() }

        do {
            let latencyMilliseconds = try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    let testConfiguration = await Self.resolvedConfiguration(configuration)
                    return try await Self.performTest(testConfiguration, target: target)
                }
                group.addTask {
                    try await Task.sleep(for: Self.timeout, precision: .relaxed)
                    throw CancellationError()
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            return .success(latencyMilliseconds)
        } catch is CancellationError {
            if !Task.isCancelled {
                logger.error("[Latency] \(configuration.name): Timed out")
            }
            return .failed
        } catch {
            logger.report("[Latency] \(configuration.name)", error: error)
            if case NaiveFlowError.tls(.certificateValidationFailed) = error {
                return .insecure
            }
            return .failed
        }
    }

    // MARK: - Private

    private static func resolvedConfiguration(_ configuration: ProxyConfiguration) async -> ProxyConfiguration {
        guard let chain = configuration.chain, let entry = chain.first else {
            guard !configuration.isDirect else { return configuration }
            return configuration.withResolvedIP(
                await DNSResolver.proxies.resolveHost(configuration.serverAddress, forceFresh: true)
            )
        }
        let resolvedEntry = entry.withResolvedIP(
            await DNSResolver.proxies.resolveHost(entry.serverAddress, forceFresh: true)
        )
        return configuration.withChain([resolvedEntry] + chain.dropFirst())
    }

    private static func performTest(_ configuration: ProxyConfiguration, target: LatencyTarget) async throws -> Int {
        let entry = configuration.chain?.first ?? configuration
        if !entry.isDirect {
            _ = await DNSResolver.proxies.resolveAll(entry.serverAddress)
        }

        let client = ProxyClient(configuration: configuration, useResolvedAddressForDirectDial: true)
        // An HTTPS target needs a TLS session layered over the tunnel. Build the
        // client up front so the cancellation handler and every exit share one.
        let tlsClient = target.isSecure
            ? TLSClient(configuration: TLSConfiguration(serverName: target.host, alpn: ["http/1.1"]))
            : nil

        do {
            let milliseconds = try await withTaskCancellationHandler {
                let tunnel = try await client.connect(to: target.host, port: target.port)

                let connection: ProxyConnection
                if let tlsClient {
                    let record: TLSRecordConnection
                    do {
                        record = try await tlsClient.connect(overTunnel: tunnel)
                    } catch {
                        tunnel.cancel()
                        throw error
                    }
                    connection = TLSProxyConnection(tlsConnection: record)
                } else {
                    connection = tunnel
                }

                // Warm the tunnel so the measured round trip is steady state: the
                // proxy handshake and first response land before the clock starts.
                try await connection.send(Self.wireRequest(target: target, closeAfter: false))
                var responses = LatencyProbeResponseReader()
                try await responses.readSuccess(from: connection)

                let clock = ContinuousClock()
                let start = clock.now
                try await connection.send(Self.wireRequest(target: target, closeAfter: true))
                try await responses.readSuccess(from: connection)
                let elapsed = clock.now - start

                return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            } onCancel: {
                tlsClient?.cancel()
                client.cancel()
            }
            tlsClient?.cancel()
            await client.cancel()
            return milliseconds
        } catch {
            tlsClient?.cancel()
            await client.cancel()
            throw error
        }
    }

    private static func wireRequest(target: LatencyTarget, closeAfter: Bool) -> Data {
        var head = "HEAD \(target.path) HTTP/1.1\r\nHost: \(target.authority)\r\n"
        if closeAfter { head += "Connection: close\r\n" }
        head += "\r\n"
        return Data(head.utf8)
    }

}

/// HEAD responses have no body, so consuming each complete header also drains
/// that response. Keep surplus bytes for the next response and cap header size.
nonisolated struct LatencyProbeResponseReader: Sendable {
    private var buffer = Data()
    private static let maximumHeaderBytes = 65_536
    private static let terminator = Data([13, 10, 13, 10])

    mutating func readSuccess(from connection: any ProxyConnection) async throws {
        while true {
            if let end = buffer.range(of: Self.terminator) {
                let length = buffer.distance(from: buffer.startIndex, to: end.upperBound)
                guard length <= Self.maximumHeaderBytes else { throw failure("response header too large") }
                let header = buffer.prefix(length)
                buffer = Data(buffer.dropFirst(length))
                let line = String(decoding: header, as: UTF8.self)
                    .components(separatedBy: "\r\n")[0]
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(parts[0]),
                      parts[1].count == 3, let status = Int(parts[1]) else {
                    throw failure(line)
                }
                // A server may send informational headers before the final one.
                if (100..<200).contains(status), status != 101 { continue }
                guard (200..<300).contains(status) else { throw failure(line) }
                return
            }
            guard buffer.count < Self.maximumHeaderBytes else { throw failure("response header too large") }
            guard let chunk = try await connection.receive(), !chunk.isEmpty else {
                throw failure("incomplete response header")
            }
            buffer.append(chunk)
        }
    }

    private func failure(_ status: String) -> NaiveFlowError {
        .diagnostics(.latencyProbeFailed(status: status))
    }
}
