//
//  ProxyDoHClient.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/6/26.
//

import Foundation

/// Sends a DoH query through the tunnel's outbound path — respecting the rules
/// and the selected proxy exactly like any other connection — instead of dialing
/// the resolver directly. This is what makes the proxy-side resolver reach its
/// upstream "through the proxy".
///
/// The wire framing (request bytes and response parsing) is shared with the
/// direct bootstrap client, so only the transport differs: here the connection
/// is `OutboundConnector.dial` + TLS, rather than a raw system dial.
nonisolated enum ProxyDoHClient {

    static func request(url: URL, body: Data) async throws -> Data {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, IPv4Only.supportsHost(host),
              let portNumber = UInt16(exactly: url.port ?? 443), portNumber > 0 else {
            throw NaiveFlowError.dns(.malformedResponse)
        }

        let dialed = try await OutboundConnector.dial(host: host, port: portNumber)
        let tlsClient = TLSClient(configuration: TLSConfiguration(serverName: host, alpn: ["http/1.1"], insecureSkipVerify: false))
        let tlsConnection: TLSRecordConnection
        do {
            tlsConnection = try await tlsClient.connect(overTunnel: dialed.connection)
        } catch {
            dialed.connection.cancel()
            dialed.proxyClient?.cancel()
            throw error
        }
        let connection = TLSProxyConnection(tlsConnection: tlsConnection)
        defer {
            connection.cancel()
            tlsClient.cancel()
            dialed.proxyClient?.cancel()
        }

        let wire = Self.wireRequest(url: url, host: host, body: body)
        return try await withDialDeadline(DNSUpstreamClient.queryTimeout) {
            connection.cancel()
        } error: {
            NaiveFlowError.dns(.timedOut(host: host))
        } operation: {
            try await connection.send(wire)
            var response = Data()
            while true {
                guard let chunk = try await connection.receive() else {
                    if let parsed = try BootstrapDoHClient.parseResponse(response, eof: true) { return parsed }
                    throw NaiveFlowError.dns(.malformedResponse)
                }
                guard !chunk.isEmpty else { continue }
                response.append(chunk)
                guard response.count <= BootstrapDoHClient.maximumWireBytes else {
                    throw NaiveFlowError.dns(.malformedResponse)
                }
                if let parsed = try BootstrapDoHClient.parseResponse(response, eof: false) { return parsed }
            }
        }
    }

    private static func wireRequest(url: URL, host: String, body: Data) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/")
            + (components?.percentEncodedQuery.map { "?" + $0 } ?? "")
        let authority = host + (url.port.map { $0 == 443 ? "" : ":\($0)" } ?? "")
        var request = Data("POST \(path) HTTP/1.1\r\nHost: \(authority)\r\nContent-Type: application/dns-message\r\nAccept: application/dns-message\r\nAccept-Encoding: identity\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        return request
    }
}
