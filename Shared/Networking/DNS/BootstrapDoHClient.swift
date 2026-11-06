import Foundation
import Network
import Security

/// Numeric dial destination, original HTTPS host for SNI/certificate checking.
/// Uses the system TLS verifier and never inherits the proxy's allow-insecure.
nonisolated enum BootstrapDoHClient {
    static let maximumBodyBytes = 65_535
    static let maximumWireBytes = 131_072

    static func request(url: URL, address: String, body: Data) async throws -> Data {
        guard url.scheme?.lowercased() == "https", let host = url.host,
              DNSName.isIPAddress(DNSName.stripBrackets(address)),
              let portNumber = UInt16(exactly: url.port ?? 443), portNumber > 0,
              let port = NWEndpoint.Port(rawValue: portNumber),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw RuleProxyError.dns(.malformedResponse) }
        let tls = NWProtocolTLS.Options()
        let serverName = DNSName.stripBrackets(host)
        serverName.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let engine = TCPTransportEngine(endpoint: .hostPort(host: NWEndpoint.Host(address), port: port), connectTimeout: 4, tls: tls)
        defer { engine.cancel() }
        let path = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath)
            + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        let authority = host + (url.port.map { $0 == 443 ? "" : ":\($0)" } ?? "")
        var request = Data("POST \(path) HTTP/1.1\r\nHost: \(authority)\r\nContent-Type: application/dns-message\r\nAccept: application/dns-message\r\nAccept-Encoding: identity\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        let wireRequest = request
        return try await withDialDeadline(DNSUpstreamClient.queryTimeout) {
            engine.cancel()
        } error: {
            RuleProxyError.dns(.timedOut(host: serverName))
        } operation: {
            try await engine.send(wireRequest)
            var response = Data()
            while true {
                let next = try await engine.receive(atMost: 16_384)
                response.append(next.content)
                guard response.count <= maximumWireBytes else { throw RuleProxyError.dns(.malformedResponse) }
                if let body = try parseResponse(response, eof: next.endOfStream) { return body }
                if next.endOfStream { throw RuleProxyError.dns(.malformedResponse) }
            }
        }
    }

    /// Incremental, bounded HTTP/1.x framing. Redirects, compression, duplicate
    /// framing fields and ambiguous framing are errors, never extra DNS lookups.
    static func parseResponse(_ wire: Data, eof: Bool) throws -> Data? {
        func invalid() -> RuleProxyError { .dns(.malformedResponse) }
        guard wire.count <= maximumWireBytes else { throw invalid() }
        guard let split = wire.range(of: Data("\r\n\r\n".utf8)) else {
            if wire.count > 16_384 || eof { throw invalid() }
            return nil
        }
        guard split.lowerBound <= 16_384,
              let header = String(data: wire[..<split.lowerBound], encoding: .ascii) else { throw invalid() }
        let lines = header.components(separatedBy: "\r\n")
        let status = (lines.first ?? "").split(separator: " ")
        guard status.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(String(status[0])), status[1] == "200" else { throw invalid() }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw invalid() }
            let key = line[..<colon].lowercased()
            if ["content-length", "transfer-encoding", "content-type", "content-encoding"].contains(key), fields[key] != nil { throw invalid() }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard fields["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/dns-message",
              fields["content-encoding"] == nil || fields["content-encoding"] == "identity" else { throw invalid() }
        let data = Data(wire[split.upperBound...])
        if let transfer = fields["transfer-encoding"] {
            guard transfer == "chunked", fields["content-length"] == nil else { throw invalid() }
            var cursor = 0
            var result = Data()
            let crlf = Data("\r\n".utf8)
            while true {
                guard let end = data.range(of: crlf, in: cursor..<data.count) else { if eof { throw invalid() }; return nil }
                guard end.lowerBound - cursor <= 128,
                      let line = String(data: data[cursor..<end.lowerBound], encoding: .ascii),
                      let size = Int(line.split(separator: ";", maxSplits: 1).first ?? "", radix: 16),
                      size >= 0, size <= maximumBodyBytes - result.count else { throw invalid() }
                cursor = end.upperBound
                if size == 0 {
                    guard data.count >= cursor + 2 else { if eof { throw invalid() }; return nil }
                    if data[cursor..<cursor+2] == crlf { return result }
                    guard data.range(of: Data("\r\n\r\n".utf8), in: cursor..<data.count) != nil else { if eof { throw invalid() }; return nil }
                    return result
                }
                guard data.count >= cursor + size + 2 else { if eof { throw invalid() }; return nil }
                guard data[(cursor+size)..<(cursor+size+2)] == crlf else { throw invalid() }
                result.append(data[cursor..<(cursor+size)])
                cursor += size + 2
            }
        }
        if let raw = fields["content-length"] {
            guard raw.allSatisfy(\.isNumber), let length = Int(raw), (0...maximumBodyBytes).contains(length) else { throw invalid() }
            guard data.count >= length else { if eof { throw invalid() }; return nil }
            return Data(data.prefix(length))
        }
        guard data.count <= maximumBodyBytes else { throw invalid() }
        return eof ? data : nil
    }
}
