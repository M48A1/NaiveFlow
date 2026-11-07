import Foundation
import Testing
@testable import NaiveFlow

/// Covers the byte-level edge cases added for the TLS / SOCKS5 fixes:
/// ServerHello split across TLS records, and the SOCKS5 UDP relay address
/// selection.
struct ProtocolEdgeCaseTests {

    // MARK: - Helpers (TLS)

    private func tlsRecord(_ payload: Data) -> Data {
        var record = Data([0x16, 0x03, 0x03, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        record.append(payload)
        return record
    }

    private func serverHelloMessage() -> Data {
        // body = legacyVersion(2) + random(32) + sessionIdLen(1) + cipherSuite(2)
        //        + compression(1) + extLen(2)
        let body: [UInt8] = [0x03, 0x03] + Array(repeating: 0xAA, count: 32) + [0x00, 0x13, 0x01, 0x00, 0x00, 0x00]
        var message = Data([0x02, 0x00, 0x00, UInt8(body.count)]) // type + 3-byte length
        message.append(contentsOf: body)
        return message
    }

    // MARK: - TLS ServerHello reassembly

    @Test func reassemblesServerHelloSplitAcrossRecords() throws {
        let message = serverHelloMessage()
        let split = message.count / 2
        let buffer = tlsRecord(message.prefix(split)) + tlsRecord(message.suffix(message.count - split))

        let result = TLSClient.reassembledServerHello(from: buffer)
        let reassembled = try #require(result)
        #expect(reassembled == message)
    }

    @Test func reassemblesServerHelloInSingleRecord() throws {
        let message = serverHelloMessage()
        let buffer = tlsRecord(message)

        let result = TLSClient.reassembledServerHello(from: buffer)
        let reassembled = try #require(result)
        #expect(reassembled == message)
    }

    @Test func returnsNilWhileServerHelloIncomplete() {
        let message = serverHelloMessage()
        // Only half the handshake message arrived; the reassembler must not
        // report it complete.
        let buffer = tlsRecord(message.prefix(message.count / 2))
        #expect(TLSClient.reassembledServerHello(from: buffer) == nil)
    }

    @Test func skipsNonHandshakeRecordsBeforeServerHello() throws {
        let message = serverHelloMessage()
        // A change-cipher-spec record (0x14) precedes the handshake record.
        let ccs = Data([0x14, 0x03, 0x03, 0x00, 0x01, 0x01])
        let buffer = ccs + tlsRecord(message)

        let result = TLSClient.reassembledServerHello(from: buffer)
        let reassembled = try #require(result)
        #expect(reassembled == message)
    }

    // MARK: - SOCKS5 UDP relay address

    @Test func socks5RelayUsesServerReportedAddress() {
        // The server reported a concrete relay host; it must win over the TCP
        // server address (which is only a fallback for wildcard replies).
        #expect(!SOCKS5Handshake.isWildcardRelayAddress("10.1.2.3"))
        #expect(!SOCKS5Handshake.isWildcardRelayAddress("relay.example.com"))
    }

    @Test func socks5RelayTreatsWildcardAsFallback() {
        #expect(SOCKS5Handshake.isWildcardRelayAddress("0.0.0.0"))
        #expect(SOCKS5Handshake.isWildcardRelayAddress("::"))
        #expect(SOCKS5Handshake.isWildcardRelayAddress("::0"))
        #expect(SOCKS5Handshake.isWildcardRelayAddress(""))
    }

    // MARK: - gRPC DATA-frame padding

    @Test func grpcDataFramePaddingIsStripped() throws {
        // No PADDED flag: payload passes through unchanged.
        let raw = Data([0x01, 0x02, 0x03])
        #expect(try GRPCConnection.dataPayload(strippingPaddingFrom: raw, flags: 0x00) == raw)

        // PADDED flag: [padLen=3][data][3 pad bytes].
        let padded = Data([0x03, 0xAA, 0xBB, 0x00, 0x00, 0x00])
        let stripped = try GRPCConnection.dataPayload(strippingPaddingFrom: padded, flags: 0x08)
        #expect(stripped == Data([0xAA, 0xBB]))
    }

    @Test func grpcDataFramePaddingMalformedThrows() {
        // Pad length exceeds the payload.
        let malformed = Data([0x05, 0xAA])
        #expect(throws: (any Error).self) {
            try GRPCConnection.dataPayload(strippingPaddingFrom: malformed, flags: 0x08)
        }
    }

    // MARK: - gRPC HEADERS-frame padding

    @Test func grpcHeadersFramePaddingIsStripped() throws {
        let block = Data([0x88]) // indexed :status 200

        // No PADDED flag: payload passes through unchanged.
        #expect(try GRPCConnection.headersPayload(strippingPaddingFrom: block, flags: 0x00) == block)

        // PADDED flag: [padLen=2][header block][2 pad bytes].
        let padded = Data([0x02]) + block + Data([0x00, 0x00])
        #expect(try GRPCConnection.headersPayload(strippingPaddingFrom: padded, flags: 0x08) == block)

        // PADDED + PRIORITY: [padLen=1][5-byte priority][header block][1 pad byte].
        let prioritised = Data([0x01]) + Data(repeating: 0x11, count: 5) + block + Data([0x00])
        #expect(try GRPCConnection.headersPayload(strippingPaddingFrom: prioritised, flags: 0x08 | 0x20) == block)
    }

    @Test func grpcHeadersFramePriorityWithoutPaddingIsStripped() throws {
        // PRIORITY alone (no PADDED): [5-byte priority][header block]. The early
        // `!PADDED` return previously left the priority field in front of the
        // block, so a legal :status 200 was misread as an unknown :status header.
        let block = Data([0x88]) // indexed :status 200
        let payload = Data(repeating: 0x11, count: 5) + block
        #expect(try GRPCConnection.headersPayload(strippingPaddingFrom: payload, flags: 0x20) == block)

        // A truncated priority field cannot be stripped.
        #expect(throws: (any Error).self) {
            try GRPCConnection.headersPayload(strippingPaddingFrom: Data([0x11, 0x11]), flags: 0x20)
        }
    }

    @Test func grpcHeadersFramePaddingMalformedThrows() {
        #expect(throws: (any Error).self) {
            try GRPCConnection.headersPayload(strippingPaddingFrom: Data([0xFF, 0x88]), flags: 0x08)
        }
    }

    // MARK: - gRPC custom service path

    @Test func grpcCustomServicePathNeverTraps() throws {
        // Regression: "/Tun" and "/" previously built a reversed string range
        // (`start > end`) and trapped inside resolvedPath().
        #expect(try GRPCConfiguration(serviceName: "/Tun").resolvedPath() == "/Tun")
        #expect(try GRPCConfiguration(serviceName: "/svc/method").resolvedPath() == "/svc/method")
        #expect(try GRPCConfiguration(serviceName: "/svc/Tun|TunMulti", multiMode: true).resolvedPath() == "/svc/TunMulti")

        // Plain names still map to /<name>/Tun.
        #expect(try GRPCConfiguration(serviceName: "svc").resolvedPath() == "/svc/Tun")
    }

    @Test func grpcCustomServicePathWithoutStreamIsConfigError() {
        // A custom path that cannot name a stream must surface a configuration
        // error rather than crash.
        #expect(throws: (any Error).self) {
            try GRPCConfiguration(serviceName: "/").resolvedPath()
        }
        #expect(throws: (any Error).self) {
            try GRPCConfiguration(serviceName: "/svc/").resolvedPath()
        }
    }

    // MARK: - WebSocket upgrade response validation

    @Test func webSocketAcceptMatchesRFCExample() {
        // RFC 6455 §1.3 worked example.
        #expect(
            WebSocketConnection.expectedAccept(for: "dGhlIHNhbXBsZSBub25jZQ==")
                == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    @Test func webSocketAcceptsConformingHandshake() {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let accept = WebSocketConnection.expectedAccept(for: key)
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: keep-alive, Upgrade\r
        Sec-WebSocket-Accept: \(accept)
        """
        #expect(WebSocketConnection.upgradeHandshakeFailure(response, key: key) == nil)
    }

    @Test func webSocketRejectsNon101EvenWhenReasonContains101() {
        // The old check used `firstLine.contains("101")`, so this 401 slipped through.
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let accept = WebSocketConnection.expectedAccept(for: key)
        let response = """
        HTTP/1.1 401 error101\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)
        """
        #expect(WebSocketConnection.upgradeHandshakeFailure(response, key: key) != nil)
    }

    @Test func webSocketRejectsMissingHandshakeHeaders() {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="

        // 101 with no Upgrade/Connection/Accept headers.
        #expect(WebSocketConnection.upgradeHandshakeFailure("HTTP/1.1 101 Switching Protocols", key: key) != nil)

        // 101 with headers but a wrong Sec-WebSocket-Accept.
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: not-the-right-value
        """
        #expect(WebSocketConnection.upgradeHandshakeFailure(response, key: key) != nil)
    }

    // MARK: - HTTPUpgrade upgrade response validation

    @Test func httpUpgradeAcceptsConnectionTokenList() {
        // `Connection: keep-alive, Upgrade` is a valid token list; the previous
        // exact-match check (`value == "upgrade"`) rejected it.
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: keep-alive, Upgrade
        """
        #expect(HTTPUpgradeConnection.upgradeHandshakeFailure(response) == nil)
    }

    @Test func httpUpgradeRejectsNon101EvenWhenReasonContains101() {
        // The old check used `statusLine.contains("101")`, so this 401 slipped through.
        let response = """
        HTTP/1.1 401 error101\r
        Upgrade: websocket\r
        Connection: Upgrade
        """
        #expect(HTTPUpgradeConnection.upgradeHandshakeFailure(response) != nil)
    }

    @Test func httpUpgradeRejectsMissingUpgradeHeaders() {
        // 101 with no Upgrade/Connection headers.
        #expect(HTTPUpgradeConnection.upgradeHandshakeFailure("HTTP/1.1 101 Switching Protocols") != nil)

        // 101 where Connection does not include the upgrade token.
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: keep-alive
        """
        #expect(HTTPUpgradeConnection.upgradeHandshakeFailure(response) != nil)
    }

    // MARK: - Subscription request target

    @Test func subscriptionRequestTargetKeepsPercentEncoding() {
        // `url.path` decodes `%2F`/`%20`, so "/sub/a%2Fb%20c" used to be sent as
        // "/sub/a/b c" — a different path plus a raw space.
        let url = URL(string: "https://sub.example.com/sub/a%2Fb%20c?token=a%2Fb%20c")!
        let head = ResolvedHostFetcher.requestHead(
            URLRequest(url: url),
            url: url,
            host: "sub.example.com",
            port: 443,
            secure: true
        )
        let requestLine = String(decoding: head, as: UTF8.self)
            .components(separatedBy: "\r\n")
            .first ?? ""
        #expect(requestLine == "GET /sub/a%2Fb%20c?token=a%2Fb%20c HTTP/1.1")
    }

    @Test func subscriptionRequestTargetDefaultsToRootPath() {
        let url = URL(string: "https://sub.example.com")!
        let head = ResolvedHostFetcher.requestHead(
            URLRequest(url: url),
            url: url,
            host: "sub.example.com",
            port: 443,
            secure: true
        )
        let requestLine = String(decoding: head, as: UTF8.self)
            .components(separatedBy: "\r\n")
            .first ?? ""
        #expect(requestLine == "GET / HTTP/1.1")
    }
}
