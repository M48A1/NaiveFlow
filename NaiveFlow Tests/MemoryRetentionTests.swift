import Foundation
import Synchronization
import Testing
@testable import NaiveFlow

struct MemoryRetentionTests {
    @Test func logByteBudgetEvictsOldEntriesWithoutChangingFields() {
        let sample = RequestLog()
        let host = String(repeating: "测", count: 100)
        sample.record(protocol: .tcp, host: host, port: 443, routeTarget: .direct, now: 0)
        let perEntry = sample.storedBytes
        let log = RequestLog(byteLimit: perEntry * 2)
        for now in 0..<3 {
            log.record(protocol: .tcp, host: host, port: 443, routeTarget: .direct, now: Double(now))
        }
        #expect(log.storedBytes == perEntry * 2)
        #expect(log.snapshot(now: 2).map(\.timestamp) == [1, 2])
        #expect(log.snapshot(now: 2).allSatisfy { $0.host == host })
        #expect(log.snapshot(now: 303).isEmpty)
        #expect(log.storedBytes == 0)
    }

    @Test func oversizedLogRecordDoesNotDisplaceNormalHistory() {
        let log = RequestLog(byteLimit: 4096)
        log.record(protocol: .tcp, host: "normal.test", port: 443, routeTarget: .direct, now: 0)
        let before = log.storedBytes
        log.record(protocol: .tcp, host: String(repeating: "x", count: 8192), port: 443, routeTarget: .direct, now: 1)
        #expect(log.storedBytes == before)
        #expect(log.snapshot(now: 1).map(\.host) == ["normal.test"])
    }

    @Test func byteEvictionDoesNotLeaveDuplicateSuppressionBehind() {
        let sample = RequestLog()
        sample.record(protocol: .tcp, host: "test", port: 443, routeTarget: .reject, deduplicationKey: "flow", now: 0)
        let log = RequestLog(byteLimit: sample.storedBytes)
        log.record(protocol: .tcp, host: "test", port: 443, routeTarget: .reject, deduplicationKey: "flow", now: 0)
        log.record(protocol: .tcp, host: "test", port: 443, routeTarget: .reject, deduplicationKey: "next", now: 1)
        log.record(protocol: .tcp, host: "test", port: 443, routeTarget: .reject, deduplicationKey: "flow", now: 2)
        #expect(log.snapshot(now: 2).map(\.timestamp) == [2])
    }

    @Test func readCursorPreservesFragmentedHandshakeAndInitialPayload() {
        var buffer = LANProxyReadBuffer()
        buffer.append(Data([5, 1, 0, 99]))
        #expect(buffer.take(1) == Data([5]))
        #expect(buffer.take(2) == Data([1, 0]))
        buffer.append(Data([100, 101]))
        #expect(buffer.take(3) == Data([99, 100, 101]))
        #expect(buffer.availableBytes == 0)
        buffer.append(Data([255]))
        #expect(buffer.take(1) == Data([255]))
    }

    @Test func inboundIdleDeadlineExtendsOnTraffic() {
        let activity = LANProxyActivity()
        activity.touch(now: 0)
        #expect(activity.remaining(timeout: 300, now: 299) == 1)
        #expect(activity.remaining(timeout: 300, now: 300) == 0)
        activity.touch(now: 299)
        #expect(activity.remaining(timeout: 300, now: 300) == 299)
    }

    @Test func evictionReleasesClosedSessionsAndPreservesActiveSessions() {
        let pool = MultiplexerPool<MemoryTestMultiplexer, Int>(extra: 0)
        let active = MemoryTestMultiplexer(active: 1)
        let idle = MemoryTestMultiplexer(active: 0)
        let closed = MemoryTestMultiplexer(active: 0)
        closed.close(error: nil)
        pool.state.withLock {
            $0.policy = MultiplexerPolicy(idleTimeout: 30, idleCheckInterval: 5)
            $0.multiplexers["test"] = [active, idle, closed]
            for item in [active, idle, closed] { $0.lastActivity[ObjectIdentifier(item)] = 0 }
        }
        pool.runIdleEviction(now: 31)
        #expect(!active.isClosed)
        #expect(idle.isClosed)
        #expect(pool.state.withLock { $0.multiplexers["test"]?.count } == 1)
        #expect(pool.state.withLock { $0.lastActivity.count } == 1)
        pool.retire()
    }
}

nonisolated private final class MemoryTestMultiplexer: Multiplexer, Sendable {
    let activeStreamCount: Int
    private let closed = Mutex(false)
    var isClosed: Bool { closed.withLock { $0 } }
    init(active: Int) { activeStreamCount = active }
    func close(error: Error?) { closed.withLock { $0 = true } }
}
