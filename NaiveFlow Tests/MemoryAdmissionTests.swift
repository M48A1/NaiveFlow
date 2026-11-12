import Foundation
import Synchronization
import Testing
@testable import NaiveFlow

struct MemoryAdmissionTests {
    private actor LookupGate {
        var waiting: CheckedContinuation<Void, Never>?
        var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func open() {
            opened = true
            waiting?.resume()
            waiting = nil
        }
    }

    @Test func dnsLimitSurvivesTimeoutAndFlushUntilWorkActuallyFinishes() async {
        let gate = LookupGate()
        let cache = DNSLookupCache<String, [String]>(capacity: 2, missing: [], waitLimit: .milliseconds(10), maxInFlight: 1)
        let lookup: DNSLookupCache<String, [String]>.Lookup = {
            await gate.wait() // Deliberately model a blocking resolver ignoring cancellation.
            return (["1.2.3.4"], 60)
        }
        let first = await cache.value(for: "one", from: .system, lookup: lookup)
        #expect(first.isEmpty)
        #expect(cache.activeLookupCount == 1)
        let rejected = await cache.value(for: "two", from: .system, lookup: { Issue.record("Overload started another lookup"); return nil })
        #expect(rejected.isEmpty)
        cache.flush()
        #expect(cache.activeLookupCount == 1)
        let afterFlush = await cache.value(for: "three", from: .system, lookup: { Issue.record("Flush bypassed admission limit"); return nil })
        #expect(afterFlush.isEmpty)
        await gate.open()
        for _ in 0..<200 {
            if cache.activeLookupCount == 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(cache.activeLookupCount == 0)
        #expect(cache.cachedValue(for: "one", from: .system) == nil)
        let next = await cache.value(for: "four", from: .system, lookup: { (["5.6.7.8"], 60) })
        #expect(next == ["5.6.7.8"])
    }

    @Test func cancelledDNSCallerDoesNotStartWork() async {
        let cache = DNSLookupCache<String, [String]>(capacity: 1, missing: [])
        let gate = LookupGate()
        let task = Task {
            await gate.wait()
            return await cache.value(for: "cancelled", from: .system, lookup: {
                Issue.record("Cancelled caller started a DNS lookup")
                return nil
            })
        }
        task.cancel()
        await gate.open()
        #expect(await task.value == [])
        #expect(cache.activeLookupCount == 0)
    }

    @Test func syscallBridgeRejectsOverloadInsteadOfQueuing() async {
        let bridge = DNSSyscallConcurrencyBridge(maxConcurrentCalls: 1)
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let first = Task {
            await bridge.run {
                entered.withLock { $0 = true }
                release.wait()
                return 7
            }
        }
        for _ in 0..<200 {
            if entered.withLock({ $0 }) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(entered.withLock { $0 })
        let overloaded = await bridge.run { Issue.record("Overload was queued"); return 8 }
        #expect(overloaded == nil)
        release.signal()
        #expect(await first.value == 7)
        #expect(await bridge.run { 9 } == 9)
    }

    @Test func packetQueueBoundsBytesAndCountAndCanBeReused() {
        var queue = BoundedPacketQueue<Int>(byteLimit: 2 * 1024 * 1024, packetLimit: 1024)
        for _ in 0..<100 { queue.append(1, byteCount: 64 * 1024) }
        #expect(queue.queuedBytes == 2 * 1024 * 1024)
        #expect(queue.count == 32)
        #expect(queue.droppedPackets == 68)
        var output: [Int] = []
        queue.drain(into: &output)
        #expect(output.count == 32)
        #expect(queue.queuedBytes == 0)
        #expect(queue.isEmpty)
        for _ in 0..<2000 { queue.append(2, byteCount: 1) }
        #expect(queue.count == 1024)
        #expect(queue.queuedBytes == 1024)
        queue.clear()
        #expect(queue.queuedBytes == 0)
        #expect(queue.isEmpty)
    }

    @Test func sharedReservationsCompeteAndReleaseOnTeardown() {
        let budget = TransientMemoryBudget(limit: 100)
        var body: TransientMemoryReservation? = TransientMemoryReservation(budget: budget)
        let script = TransientMemoryReservation(budget: budget)
        #expect(body?.resize(60) == true)
        #expect(!script.resize(50))
        #expect(budget.reservedBytes == 60)
        #expect(script.resize(40))
        #expect(!body!.resize(61))
        #expect(body?.resize(20) == true)
        #expect(script.resize(80))
        body = nil
        #expect(budget.reservedBytes == 80)
        script.resize(0)
        #expect(budget.reservedBytes == 0)
        #expect(!budget.reserve(-1))
        #expect(!budget.reserve(Int.max))
    }
}
