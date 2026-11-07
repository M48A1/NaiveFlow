//
//  Shadowsocks2022ReplayTests.swift
//  NaiveFlow Tests
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation
import Synchronization
import Testing
@testable import NaiveFlow

/// SIP022 §3.2.4 / §4.1 require a per-server-session sliding window so a
/// replayed datagram that still authenticates is rejected. These tests cover the
/// window primitive directly and the real ChaCha UDP receive path (the same
/// ciphertext delivered twice).
struct Shadowsocks2022ReplayTests {

    // MARK: - Window primitive

    @Test func slidingWindowAcceptsReorderRejectsReplayAndStale() {
        let filter = Shadowsocks2022ReplayFilter()
        let session: UInt64 = 0xABCD_1234

        #expect(filter.accept(serverSession: session, packetID: 1))   // first
        #expect(filter.accept(serverSession: session, packetID: 3))   // jump ahead
        #expect(filter.accept(serverSession: session, packetID: 2))   // in-window reorder
        #expect(!filter.accept(serverSession: session, packetID: 2))  // duplicate
        #expect(!filter.accept(serverSession: session, packetID: 1))  // duplicate
        #expect(filter.accept(serverSession: session, packetID: 100)) // big jump resets window
        #expect(!filter.accept(serverSession: session, packetID: 3))  // now older than the 64-window

        // A different server session is tracked independently.
        #expect(filter.accept(serverSession: session &+ 1, packetID: 1))
        #expect(filter.accept(serverSession: session &+ 1, packetID: 1) == false)
    }

    // MARK: - ChaCha receive path

    /// Delivers a queue of raw datagrams into a real
    /// `Shadowsocks2022ChaChaUDPConnection`.
    private final class FeedConnection: ProxyConnection {
        private let packets: Mutex<[Data]>
        init(_ packets: [Data]) { self.packets = Mutex(packets) }
        var isConnected: Bool { true }
        func sendRaw(_ data: Data) async throws {}
        func receiveRaw() async throws -> Data? {
            packets.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
        nonisolated func cancel() {}
        nonisolated func abort() {}
    }

    @Test func replayedChaChaDatagramIsRejected() async throws {
        let psk = Data(repeating: 7, count: 32)
        let clientSession: UInt64 = 0x1122_3344_5566_7788

        func bigEndian(_ value: UInt64) -> Data {
            var be = value.bigEndian
            return withUnsafeBytes(of: &be) { Data($0) }
        }
        // Builds a valid server→client datagram for the given server session and
        // packet ID: nonce || XChaCha(body).
        func datagram(serverSession: UInt64, packetID: UInt64, payload: String) throws -> Data {
            var body = Data()
            body.append(bigEndian(serverSession))
            body.append(bigEndian(packetID))
            body.append(1)                                   // headerTypeServer
            body.append(bigEndian(UInt64(Date().timeIntervalSince1970)))
            body.append(bigEndian(clientSession))
            body.append(contentsOf: [0, 0])                  // padding length
            body.append(ShadowsocksProtocol.encodeUDPPacket(host: "1.1.1.1", port: 53, payload: Data(payload.utf8)))
            let nonce = Data((0..<24).map { _ in UInt8.random(in: 0...255) })
            return nonce + (try XChaCha20Poly1305.seal(key: psk, nonce: nonce, plaintext: body))
        }

        let good = try datagram(serverSession: 999, packetID: 1, payload: "reply")
        // Same ciphertext twice: authentic, but the second is a replay.
        let inner = FeedConnection([good, good])
        let connection = Shadowsocks2022ChaChaUDPConnection(
            inner: inner, psk: psk, dstHost: "1.1.1.1", dstPort: 53, sessionID: clientSession
        )

        let first = try await connection.receiveRaw()
        #expect(first == Data("reply".utf8))

        // The replay is dropped and the queue drains, so nothing is returned.
        let second = try await connection.receiveRaw()
        #expect(second == nil)
    }
}
