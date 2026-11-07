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
}
