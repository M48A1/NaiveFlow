//
//  DNSUpstreamClient.swift
//  NaiveFlow
//
//  Created by NodePassProject on 7/24/26.
//

import Foundation
import Synchronization

nonisolated private let logger = NaiveFlowLogger(category: "DNSUpstreamClient")

nonisolated enum DNSUpstreamClient {
    static let queryTimeout: Duration = .seconds(4)

    /// A transport for proxy-side DoH that routes through the tunnel's outbound
    /// connector (rules + selected proxy) instead of dialing the resolver
    /// directly. The Network Extension installs one while a routing context is
    /// available; the host app leaves it nil and keeps the direct bootstrap path.
    typealias ProxyDoHTransport = @Sendable (URL, Data) async throws -> Data

    private static let proxyDoHTransport = Mutex<ProxyDoHTransport?>(nil)

    static func setProxyDoHTransport(_ transport: ProxyDoHTransport?) {
        proxyDoHTransport.withLock { $0 = transport }
    }

    static func activeProxyDoHTransport() -> ProxyDoHTransport? {
        proxyDoHTransport.withLock { $0 }
    }

    private static let recordUDPPayloadSize: UInt16 = 1232

    // MARK: - Public API
    
    static func resolve(
        _ host: String,
        via upstream: DNSUpstream,
        family: DNSAddressFamily = .ipv4,
        bootstrap: DNSBootstrapPolicy? = nil,
        viaProxy: Bool = false
    ) async throws -> [String] {
        try IPv4Only.requireHost(host)
        let policy = bootstrap ?? AWCore.getBootstrapDNS()
        let addresses: [String]
        do {
            switch upstream {
            case .system:
                throw NaiveFlowError.dns(.resolutionFailed(host: host, detail: "no upstream configured"))
            case .plain(let server, let port):
                addresses = try await queryAll(host, family: family) { name, type in
                    try await queryPlain(name, type: type, server: server, port: port)
                }
            case .doh(let url):
                addresses = try await queryAll(host, family: family) { name, type in
                    try await queryDoH(name, type: type, url: url, bootstrap: policy, viaProxy: viaProxy)
                }
            }
        } catch {
            logger.report("[DNS] \(host) via \(describe(upstream))", error: error)
            throw error
        }

        guard !addresses.isEmpty else {
            throw NaiveFlowError.dns(.noAddresses(host: host))
        }
        return addresses
    }
    
    static func queryRecord(
        _ host: String,
        type: UInt16,
        via upstream: DNSUpstream,
        bootstrap: DNSBootstrapPolicy? = nil,
        accept: @escaping @Sendable (Data) -> Data?
    ) async throws -> (payload: Data, ttl: UInt32)? {
        try IPv4Only.requireHost(host)
        guard type != 28 else { throw NaiveFlowError.dns(.malformedResponse) }
        do {
            switch upstream {
            case .system:
                throw NaiveFlowError.dns(.resolutionFailed(host: host, detail: "no upstream configured"))
            case .plain(let server, let port):
                return try await queryRecordPlain(host, type: type, server: server, port: port, accept: accept)
            case .doh(let url):
                return try await queryRecordDoH(host, type: type, url: url, bootstrap: bootstrap ?? AWCore.getBootstrapDNS(), accept: accept)
            }
        } catch {
            logger.report("[DNS] \(host) type \(type) via \(describe(upstream))", error: error)
            throw error
        }
    }

    /// Forward one complete message, retaining transaction and question identity.
    static func exchange(_ query: Data, via upstream: DNSUpstream, preferTCP: Bool = false) async throws -> Data {
        guard query.count >= 12, query.count <= 65535 else { throw NaiveFlowError.dns(.malformedResponse) }
        switch upstream {
        case .plain(let host, let port):
            if preferTCP { return try await exchangeTCP(query, host: host, port: port) }
            let transport = UDPTransport(host: host, port: port)
            defer { transport.cancel() }
            let reply = try await withDialDeadline(queryTimeout) {
                transport.cancel()
            } error: {
                NaiveFlowError.dns(.timedOut(host: host))
            } operation: {
                try await transport.connect()
                try await transport.send(query)
                while true {
                    let reply = try await transport.receive()
                    if matchesReply(reply, query: query) { return reply }
                }
            }
            if reply[2] & 0x02 != 0 { return try await exchangeTCP(query, host: host, port: port) }
            return reply
        case .doh(let url):
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = query
            request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
            request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
            let reply = try await sendDoH(request, bootstrap: AWCore.getBootstrapDNS())
            guard matchesReply(reply, query: query), reply[2] & 0x02 == 0 else {
                throw NaiveFlowError.dns(.malformedResponse)
            }
            return reply
        case .system:
            return try await exchange(query, via: .defaultPlain, preferTCP: preferTCP)
        }
    }

    static func matchesReply(_ reply: Data, query: Data) -> Bool {
        guard query.count >= 12, reply.count >= 12, reply[0] == query[0], reply[1] == query[1],
              reply[2] & 0xF8 == 0x80, reply[4] == 0, reply[5] == 1 else { return false }
        var end = 12
        while end < query.count {
            let size = Int(query[end])
            end += 1
            if size == 0 { break }
            guard size <= 63, end + size <= query.count else { return false }
            end += size
        }
        end += 4
        return end <= query.count && end <= reply.count && reply[12..<end] == query[12..<end]
    }

    private static func exchangeTCP(_ query: Data, host: String, port: UInt16) async throws -> Data {
        let transport = TCPTransport(host: host, port: port)
        let connection = DirectProxyConnection(transport: transport)
        defer { transport.cancel() }
        return try await withDialDeadline(queryTimeout) {
            transport.cancel()
        } error: {
            NaiveFlowError.dns(.timedOut(host: host))
        } operation: {
            try await transport.connect()
            var request = Data([UInt8(query.count >> 8), UInt8(query.count & 255)])
            request.append(query)
            try await connection.send(request)
            var buffer = Data()
            while let chunk = try await connection.receive() {
                guard buffer.count + chunk.count <= 131_074 else { throw NaiveFlowError.dns(.malformedResponse) }
                buffer.append(chunk)
                if buffer.count >= 2 {
                    let length = Int(buffer[0]) << 8 | Int(buffer[1])
                    guard length >= 12 else { throw NaiveFlowError.dns(.malformedResponse) }
                    if buffer.count >= length + 2 {
                        let reply = Data(buffer[2..<(length + 2)])
                        guard matchesReply(reply, query: query), reply[2] & 0x02 == 0 else {
                            throw NaiveFlowError.dns(.malformedResponse)
                        }
                        return reply
                    }
                }
            }
            throw NaiveFlowError.dns(.malformedResponse)
        }
    }

    // MARK: - Internal
    
    private static func queryAll(
        _ host: String,
        family: DNSAddressFamily,
        query: @escaping @Sendable (String, UInt16) async throws -> [String]
    ) async throws -> [String] {
        try await query(host, DNSMessage.typeA)
    }

    // MARK: - Plain

    private static func queryPlain(
        _ name: String,
        type: UInt16,
        server: String,
        port: UInt16
    ) async throws -> [String] {
        let id = UInt16.random(in: UInt16.min...UInt16.max)
        guard let query = DNSMessage.makeQuery(domain: name, type: type, id: id) else {
            throw NaiveFlowError.dns(.resolutionFailed(host: name, detail: "name not encodable"))
        }

        let transport = UDPTransport(host: server, port: port)
        defer { transport.cancel() }
        
        return try await withDialDeadline(queryTimeout) {
            transport.cancel()
        } error: {
            NaiveFlowError.dns(.timedOut(host: name))
        } operation: {
            try await transport.connect()
            try await transport.send(query)
            while true {
                let datagram = try await transport.receive()
                if let addresses = try decode(datagram, id: id) { return addresses }
            }
        }
    }

    private static func queryRecordPlain(
        _ name: String,
        type: UInt16,
        server: String,
        port: UInt16,
        accept: @escaping @Sendable (Data) -> Data?
    ) async throws -> (payload: Data, ttl: UInt32)? {
        let id = UInt16.random(in: UInt16.min...UInt16.max)
        guard let query = DNSMessage.makeQuery(
            domain: name,
            type: type,
            id: id,
            udpPayloadSize: recordUDPPayloadSize
        ) else {
            throw NaiveFlowError.dns(.resolutionFailed(host: name, detail: "name not encodable"))
        }

        let transport = UDPTransport(host: server, port: port)
        defer { transport.cancel() }

        return try await withDialDeadline(queryTimeout) {
            transport.cancel()
        } error: {
            NaiveFlowError.dns(.timedOut(host: name))
        } operation: {
            try await transport.connect()
            try await transport.send(query)
            while true {
                let datagram = try await transport.receive()
                if let records = try decodeRecords(datagram, id: id, type: type) {
                    return firstAccepted(records, accept: accept)
                }
            }
        }
    }

    // MARK: - DoH

    private static func queryDoH(_ name: String, type: UInt16, url: URL, bootstrap: DNSBootstrapPolicy, viaProxy: Bool = false) async throws -> [String] {
        let id: UInt16 = 0
        guard let query = DNSMessage.makeQuery(domain: name, type: type, id: id) else {
            throw NaiveFlowError.dns(.resolutionFailed(host: name, detail: "name not encodable"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = query
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.setValue(ProxyUserAgent.default, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = TimeInterval(queryTimeout.components.seconds)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data = try await sendDoH(request, bootstrap: bootstrap, viaProxy: viaProxy)
        guard let addresses = try decode(data, id: id) else {
            throw NaiveFlowError.dns(.malformedResponse)
        }
        return addresses
    }

    private static func queryRecordDoH(
        _ name: String,
        type: UInt16,
        url: URL,
        bootstrap: DNSBootstrapPolicy,
        accept: @escaping @Sendable (Data) -> Data?
    ) async throws -> (payload: Data, ttl: UInt32)? {
        let id: UInt16 = 0
        guard let query = DNSMessage.makeQuery(domain: name, type: type, id: id) else {
            throw NaiveFlowError.dns(.resolutionFailed(host: name, detail: "name not encodable"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = query
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.setValue(ProxyUserAgent.default, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = TimeInterval(queryTimeout.components.seconds)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data = try await sendDoH(request, bootstrap: bootstrap)
        guard let records = try decodeRecords(data, id: id, type: type) else {
            throw NaiveFlowError.dns(.malformedResponse)
        }
        return firstAccepted(records, accept: accept)
    }

    private static func sendDoH(_ request: URLRequest, bootstrap: DNSBootstrapPolicy, viaProxy: Bool = false) async throws -> Data {
        guard let url = request.url, let host = url.host else { throw NaiveFlowError.dns(.malformedResponse) }
        // All endpoints use a numeric IPv4 dial destination.
        try IPv4Only.requireHost(host)
        // Proxy-side DoH routes through the tunnel when requested; bootstrap and
        // host-app lookups keep the direct path (the proxy cannot carry its own
        // bootstrap without looping).
        if viaProxy, let transport = activeProxyDoHTransport() {
            return try await transport(url, request.httpBody ?? Data())
        }
        let addresses: [String]
        if bootstrap.isSystem {
            addresses = await DNSSyscallConcurrencyBridge.shared.resolveAddresses(host, family: .ipv4)
        } else {
            addresses = try await bootstrap.endpointAddresses(for: host) { name, server in
                try await resolve(name, via: .plain(host: server, port: 53), bootstrap: .system)
            }
        }
        var failure: (any Error)?
        for address in addresses {
            try Task.checkCancellation()
            do { return try await BootstrapDoHClient.request(url: url, address: address, body: request.httpBody ?? Data()) }
            catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        throw failure ?? NaiveFlowError.dns(.noAddresses(host: host))
    }

    // MARK: - Shared decoding

    private static func decode(_ message: Data, id: UInt16) throws -> [String]? {
        do {
            return try DNSMessage.parseAddresses(message, expectedID: id)
        } catch DNSMessage.ParseFailure.identifierMismatch {
            return nil
        } catch DNSMessage.ParseFailure.serverFailure {
            return []
        } catch {
            throw NaiveFlowError.dns(.malformedResponse)
        }
    }

    private static func decodeRecords(
        _ message: Data,
        id: UInt16,
        type: UInt16
    ) throws -> [(rdata: Data, ttl: UInt32)]? {
        do {
            return try DNSMessage.parseRecords(message, expectedID: id, type: type)
        } catch DNSMessage.ParseFailure.identifierMismatch {
            return nil
        } catch DNSMessage.ParseFailure.serverFailure {
            return []
        } catch {
            throw NaiveFlowError.dns(.malformedResponse)
        }
    }

    private static func firstAccepted(
        _ records: [(rdata: Data, ttl: UInt32)],
        accept: (Data) -> Data?
    ) -> (payload: Data, ttl: UInt32)? {
        for record in records {
            if let payload = accept(record.rdata) { return (payload, record.ttl) }
        }
        return nil
    }
    
    private static func describe(_ upstream: DNSUpstream) -> String {
        switch upstream {
        case .system: return "system"
        case .plain(let host, let port): return "\(host):\(port)"
        case .doh(let url): return "DoH \(url.host ?? "?")"
        }
    }
}
