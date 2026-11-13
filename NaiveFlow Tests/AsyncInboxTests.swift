import Testing
@testable import NaiveFlow

@Suite(.timeLimit(.minutes(1)))
struct AsyncInboxTests {
    @Test func backlogPreservesOrderAcrossCompactions() async throws {
        let inbox = AsyncInbox<Int>()
        for value in 0..<4096 { inbox.yield(value) }
        inbox.finish()
        for expected in 0..<4096 {
            #expect(try await inbox.next() == expected)
        }
        #expect(try await inbox.next() == nil)
    }

    @Test func capacityCountsOnlyUnreadElements() async throws {
        let inbox = AsyncInbox<Int>(capacity: 3)
        for value in 0..<3 { inbox.yield(value) }
        inbox.yield(99) // Full: drop the new item.
        for expected in 0..<300 {
            #expect(try await inbox.next() == expected)
            inbox.yield(expected + 3)
        }
        inbox.finish()
        #expect(try await inbox.nextBatch() == [300, 301, 302])
        #expect(try await inbox.nextBatch() == nil)
    }

    @Test func batchAfterPartialReadCanBeFollowedByNewItems() async throws {
        let inbox = AsyncInbox<Int>()
        for value in 0..<100 { inbox.yield(value) }
        for expected in 0..<10 {
            #expect(try await inbox.next() == expected)
        }
        #expect(try await inbox.nextBatch() == Array(10..<100))
        inbox.yield(100)
        #expect(try await inbox.next() == 100)
        inbox.yield(101)
        inbox.finish()
        #expect(try await inbox.nextBatch() == [101])
        #expect(try await inbox.next() == nil)
    }

    @Test func compactionThresholdCountsOnlyUnreadElements() async throws {
        let inbox = AsyncInbox<Int>()
        for value in 0..<4 { inbox.yield(value) }
        for expected in 0..<3 { #expect(try await inbox.next() == expected) }
        inbox.yield(4, compactingAbove: 2) { -$0 }
        inbox.yield(5, compactingAbove: 2) { -$0 }
        inbox.finish()
        #expect(try await inbox.nextBatch() == [3, 4, -5])
    }

    @Test func optionalNilIsDeliveredAsAnElement() async throws {
        let inbox = AsyncInbox<Int?>()
        inbox.yield(nil)
        inbox.yield(7)
        inbox.yield(nil)
        inbox.finish()
        let first = try await inbox.next()
        #expect(first != nil)
        #expect(first! == nil)
        #expect(try await inbox.nextBatch() == [7, nil])
        #expect(try await inbox.next() == nil)
    }

    @Test func consumedPayloadIsReleasedBeforeCompaction() async throws {
        let inbox = AsyncInbox<Payload>()
        weak var consumed: Payload?
        do {
            let payload = Payload()
            consumed = payload
            inbox.yield(payload)
        }
        inbox.yield(Payload()) // Keep the queue nonempty after the first read.
        #expect(consumed != nil)
        _ = try await inbox.next()
        #expect(consumed == nil)
        inbox.finish()
    }

    @Test func failureFollowsBufferedDataAndIsDeliveredOnlyOnce() async throws {
        let inbox = AsyncInbox<Int>()
        inbox.yield(1)
        inbox.yield(2)
        inbox.finish(throwing: TestFailure.closed)
        inbox.yield(3)
        #expect(try await inbox.next() == 1)
        #expect(try await inbox.nextBatch() == [2])
        do {
            _ = try await inbox.next()
            Issue.record("Expected the terminal error")
        } catch TestFailure.closed {
        }
        #expect(try await inbox.nextBatch() == nil)
    }

    @Test func cancellationUnparksConsumerAndAllowsReuse() async throws {
        let inbox = AsyncInbox<Int>()
        let consumer = Task { try await inbox.next() }
        consumer.cancel()
        do {
            _ = try await consumer.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        }
        inbox.yield(42)
        inbox.finish()
        #expect(try await inbox.next() == 42)
        #expect(try await inbox.next() == nil)
    }

    private nonisolated final class Payload: Sendable {}
    private enum TestFailure: Error { case closed }
}
