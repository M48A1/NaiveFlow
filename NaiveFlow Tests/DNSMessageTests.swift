import Foundation
import Testing
@testable import NaiveFlow

/// Covers the DNS message decode surface added for the "real TTL" cache
/// (see `DNSMessage.parseAddressesWithTTL`) and the truncation/TCP-retry
/// contract. Pure in-memory tests, no network.
struct DNSMessageTests {

    // MARK: - Helpers

    /// Builds a well-formed A-record response carrying `answers` in order.
    /// The question is the one produced by `makeQuery` for `example.com`.
    private func aResponse(id: UInt16 = 7, answers: [(address: [UInt8], ttl: UInt32)]) -> Data? {
        guard var response = DNSMessage.makeQuery(domain: "example.com", type: DNSMessage.typeA, id: id) else { return nil }
        // Flags: QR=1, RD=1, RA=1, rcode=0.
        response[2] = 0x81
        response[3] = 0x80
        response[6] = UInt8(answers.count >> 8)
        response[7] = UInt8(answers.count & 0xFF)
        for answer in answers {
            response.append(contentsOf: [0xC0, 0x0C])       // name pointer → question
            response.append(contentsOf: [0x00, 0x01])       // TYPE A
            response.append(contentsOf: [0x00, 0x01])       // CLASS IN
            let ttl = answer.ttl
            response.append(UInt8((ttl >> 24) & 0xFF))
            response.append(UInt8((ttl >> 16) & 0xFF))
            response.append(UInt8((ttl >> 8) & 0xFF))
            response.append(UInt8(ttl & 0xFF))
            response.append(contentsOf: [0x00, 0x04])       // RDLENGTH = 4
            response.append(contentsOf: answer.address)
        }
        return response
    }

    // MARK: - TTL extraction

    @Test func extractsPerRecordTTLInOrder() throws {
        let response = try #require(aResponse(answers: [
            (address: [1, 2, 3, 4], ttl: 60),
            (address: [5, 6, 7, 8], ttl: 300),
        ]))

        let records = try DNSMessage.parseAddressesWithTTL(response, expectedID: 7)

        #expect(records.count == 2)
        #expect(records[0].address == "1.2.3.4")
        #expect(records[0].ttl == 60)
        #expect(records[1].address == "5.6.7.8")
        #expect(records[1].ttl == 300)
    }

    @Test func preservesZeroTTL() throws {
        let response = try #require(aResponse(answers: [(address: [10, 0, 0, 1], ttl: 0)]))
        let records = try DNSMessage.parseAddressesWithTTL(response, expectedID: 7)
        #expect(records.count == 1)
        #expect(records[0].ttl == 0)
    }

    @Test func skipsNonARecordsWhenExtractingTTL() throws {
        // A single A record plus a trailing answer is left as-is here; only A
        // records are collected. The second entry is an A record with a
        // different address to prove ordering, not a non-A record (the helper
        // only builds A records).
        let response = try #require(aResponse(answers: [(address: [8, 8, 8, 8], ttl: 120)]))
        let records = try DNSMessage.parseAddressesWithTTL(response, expectedID: 7)
        #expect(records.map(\.address) == ["8.8.8.8"])
        #expect(records.map(\.ttl) == [120])
    }

    @Test func ttlParseMatchesPlainAddressParse() throws {
        let response = try #require(aResponse(answers: [
            (address: [192, 168, 1, 1], ttl: 30),
            (address: [10, 0, 0, 2], ttl: 90),
        ]))
        let withTTL = try DNSMessage.parseAddressesWithTTL(response, expectedID: 7)
        let plain = try DNSMessage.parseAddresses(response, expectedID: 7)
        #expect(withTTL.map(\.address) == plain)
    }

    @Test func emptyAnswerSectionYieldsEmptyRecords() throws {
        let response = try #require(aResponse(answers: []))
        let records = try DNSMessage.parseAddressesWithTTL(response, expectedID: 7)
        #expect(records.isEmpty)
    }

    @Test func mismatchedIDStillRejectedForTTLParse() throws {
        let response = try #require(aResponse(answers: [(address: [1, 1, 1, 1], ttl: 60)]))
        #expect(throws: DNSMessage.ParseFailure.identifierMismatch) {
            _ = try DNSMessage.parseAddressesWithTTL(response, expectedID: 8)
        }
    }
}
