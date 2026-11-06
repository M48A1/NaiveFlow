import Foundation
import Testing
@testable import NaiveFlow

struct DNSInterceptionTests {
    @Test func validatesSingleInternetQuestionAndAnswerLength() throws {
        let query = try #require(DNSMessage.makeQuery(domain: "example.com", type: 1, id: 42))
        #expect(query.withUnsafeBytes { DNSPacket.parseQuery($0.bindMemory(to: UInt8.self))?.domain } != nil)
        for count in 0..<query.count {
            let partial = Data(query.prefix(count))
            #expect(partial.withUnsafeBytes { DNSPacket.parseQuery($0.bindMemory(to: UInt8.self))?.domain } == nil)
        }
        var invalid = query
        invalid[5] = 2
        #expect(invalid.withUnsafeBytes { DNSPacket.parseQuery($0.bindMemory(to: UInt8.self))?.domain } == nil)
        invalid = query
        invalid[invalid.count - 1] = 3
        #expect(invalid.withUnsafeBytes { DNSPacket.parseQuery($0.bindMemory(to: UInt8.self))?.domain } == nil)
        #expect(query.withUnsafeBytes { DNSPacket.generateResponse(query: $0.bindMemory(to: UInt8.self), answerIP: [1], qtype: 1) } == nil)
    }

    @Test func preservesRecursionFlagWithoutClaimingAuthority() throws {
        var query = try #require(DNSMessage.makeQuery(domain: "example.com", type: 1, id: 42))
        query[2] = 0
        let response = try #require(DNSPacket.errorResponse(query, code: 2))
        #expect(response[2] == 0x80)
        #expect(response[3] == 0x82)
        let truncated = try #require(DNSPacket.truncatedResponse(query))
        #expect(truncated[2] & 0x02 != 0)
        #expect(truncated[6] == 0 && truncated[7] == 0)
    }

    @Test func responseMustMatchTransactionAndQuestion() throws {
        let query = try #require(DNSMessage.makeQuery(domain: "example.com", type: 1, id: 42))
        var reply = query
        reply[2] = 0x81
        reply[3] = 0x80
        #expect(DNSUpstreamClient.matchesReply(reply, query: query))
        reply[1] = 43
        #expect(!DNSUpstreamClient.matchesReply(reply, query: query))
        reply[1] = 42
        reply[13] ^= 1
        #expect(!DNSUpstreamClient.matchesReply(reply, query: query))
    }

    @Test func rejectsQueriesAndIncompleteQuestionsAsResponses() throws {
        let query = try #require(DNSMessage.makeQuery(domain: "example.com", type: 1, id: 42))
        #expect(!DNSUpstreamClient.matchesReply(query, query: query))
        for count in 0..<query.count {
            #expect(!DNSUpstreamClient.matchesReply(Data(query.prefix(count)), query: query))
        }
    }

    @Test func permitsChangedAdditionalSectionsAndTruncationForTCPRetry() throws {
        let query = try #require(DNSMessage.makeQuery(domain: "example.com", type: 1, id: 42, udpPayloadSize: 1232))
        var reply = try #require(DNSMessage.makeQuery(domain: "example.com", type: 1, id: 42))
        reply[2] = 0x83
        reply[3] = 0x80
        #expect(DNSUpstreamClient.matchesReply(reply, query: query))
        reply[5] = 2
        #expect(!DNSUpstreamClient.matchesReply(reply, query: query))
    }
}
