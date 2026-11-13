import Foundation
import Synchronization
import Testing
@testable import NaiveFlow

@Suite(.timeLimit(.minutes(1)))
struct DNSLookupCacheTests {
    private nonisolated final class Clock: Sendable {
        let time = Mutex<TimeInterval>(0)
        func now() -> TimeInterval { time.withLock { $0 } }
        func set(_ value: TimeInterval) { time.withLock { $0 = value } }
    }

    private func store(_ key: String, value: Int, ttl: TimeInterval,
                       in cache: DNSLookupCache<String, Int>, fresh: Bool = false) async -> Int {
        await cache.value(for: key, from: .system, forceFresh: fresh) { (value, ttl) }
    }

    @Test func ttlBoundaryExpiresAndRefreshesWithoutSleeping() async {
        let clock = Clock()
        let cache = DNSLookupCache<String, Int>(capacity: 4, missing: -1, now: { clock.now() })
        #expect(await store("a", value: 1, ttl: 10, in: cache) == 1)
        clock.set(9)
        #expect(await store("a", value: 99, ttl: 10, in: cache) == 1)
        clock.set(10)
        #expect(cache.cachedValue(for: "a", from: .system) == nil)
        #expect(await store("a", value: 2, ttl: 20, in: cache) == 2)
        clock.set(29)
        #expect(cache.cachedValue(for: "a", from: .system) == 2)
        clock.set(30)
        #expect(cache.cachedValue(for: "a", from: .system) == nil)
    }

    @Test func cleanupRemovesExpiredEntriesBeforeEvictingLiveOnes() async {
        let clock = Clock()
        let cache = DNSLookupCache<String, Int>(capacity: 2, missing: -1, now: { clock.now() })
        _ = await store("expired", value: 1, ttl: 1, in: cache)
        _ = await store("live", value: 2, ttl: 100, in: cache)
        clock.set(1)
        _ = await store("new", value: 3, ttl: 100, in: cache)
        #expect(cache.cachedValue(for: "expired", from: .system) == nil)
        #expect(cache.cachedValue(for: "live", from: .system) == 2)
        #expect(cache.cachedValue(for: "new", from: .system) == 3)
        #expect(cache.flush() == 2)
    }

    @Test func capacityEvictsSoonestExpiryRatherThanOldestInsertion() async {
        let cache = DNSLookupCache<String, Int>(capacity: 2, missing: -1, now: { 0 })
        _ = await store("long", value: 1, ttl: 100, in: cache)
        _ = await store("short", value: 2, ttl: 10, in: cache)
        _ = await store("medium", value: 3, ttl: 50, in: cache)
        #expect(cache.cachedValue(for: "long", from: .system) == 1)
        #expect(cache.cachedValue(for: "short", from: .system) == nil)
        #expect(cache.cachedValue(for: "medium", from: .system) == 3)
        #expect(cache.flush() == 2)
    }

    @Test func refreshOfEarliestEntryCannotHideAnotherDeadline() async {
        let clock = Clock()
        let cache = DNSLookupCache<String, Int>(capacity: 4, missing: -1, now: { clock.now() })
        _ = await store("a", value: 1, ttl: 10, in: cache)
        _ = await store("b", value: 2, ttl: 20, in: cache)
        _ = await store("a", value: 3, ttl: 100, in: cache, fresh: true)
        clock.set(10)
        _ = await store("c", value: 4, ttl: 100, in: cache)
        #expect(cache.cachedValue(for: "a", from: .system) == 3)
        clock.set(20)
        _ = await store("d", value: 5, ttl: 100, in: cache)
        #expect(cache.flush() == 3) // b was removed, a/c/d remain.
    }

    @Test func earlierRefreshAdvancesCleanupDeadline() async {
        let clock = Clock()
        let cache = DNSLookupCache<String, Int>(capacity: 4, missing: -1, now: { clock.now() })
        _ = await store("a", value: 1, ttl: 100, in: cache)
        _ = await store("a", value: 2, ttl: 5, in: cache, fresh: true)
        clock.set(5)
        _ = await store("b", value: 3, ttl: 100, in: cache)
        #expect(cache.flush() == 1)
    }

    @Test func evictedDeadlineDoesNotPreventFutureCleanup() async {
        let clock = Clock()
        let cache = DNSLookupCache<String, Int>(capacity: 1, missing: -1, now: { clock.now() })
        _ = await store("a", value: 1, ttl: 10, in: cache)
        _ = await store("b", value: 2, ttl: 20, in: cache)
        clock.set(10)
        _ = await store("b", value: 3, ttl: 10, in: cache, fresh: true)
        clock.set(20)
        _ = await store("c", value: 4, ttl: 100, in: cache)
        #expect(cache.cachedValue(for: "c", from: .system) == 4)
        #expect(cache.flush() == 1)
    }

    @Test func zeroTTLAndZeroCapacityReturnAnswerWithoutCachingIt() async {
        let cache = DNSLookupCache<String, Int>(capacity: 4, missing: -1, now: { 0 })
        #expect(await store("a", value: 1, ttl: 0, in: cache) == 1)
        #expect(cache.flush() == 0)
        let disabled = DNSLookupCache<String, Int>(capacity: 0, missing: -1, now: { 0 })
        #expect(await store("a", value: 2, ttl: 100, in: disabled) == 2)
        #expect(disabled.cachedValue(for: "a", from: .system) == nil)
        #expect(disabled.flush() == 0)
    }

    @Test func expiredAnswerIsOnlyUsedWhenFailureFallbackIsEnabled() async {
        let clock = Clock()
        for servesStale in [false, true] {
            clock.set(0)
            let cache = DNSLookupCache<String, Int>(capacity: 2, missing: -1,
                servesStaleOnFailure: servesStale, now: { clock.now() })
            _ = await store("a", value: 1, ttl: 10, in: cache)
            clock.set(10)
            #expect(cache.cachedValue(for: "a", from: .system) == nil)
            let failed = await cache.value(for: "a", from: .system) { nil }
            #expect(failed == (servesStale ? 1 : -1))
        }
    }

    @Test func flushResetsDeadlinesForNewEntries() async {
        let clock = Clock()
        let cache = DNSLookupCache<String, Int>(capacity: 2, missing: -1, now: { clock.now() })
        _ = await store("a", value: 1, ttl: 100, in: cache)
        #expect(cache.flush() == 1)
        _ = await store("b", value: 2, ttl: 5, in: cache)
        clock.set(5)
        _ = await store("c", value: 3, ttl: 100, in: cache)
        #expect(cache.flush() == 1)
    }

    @Test func concurrentRequestsShareOneLookup() async {
        let cache = DNSLookupCache<String, Int>(capacity: 2, missing: -1, maxInFlight: 1)
        let calls = Mutex(0)
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await cache.value(for: "shared", from: .system) {
                        calls.withLock { $0 += 1 }
                        for _ in 0..<32 { await Task.yield() }
                        return (42, 100)
                    }
                }
            }
            for await answer in group { #expect(answer == 42) }
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(cache.activeLookupCount == 0)
    }

    @Test func changingUpstreamClearsAnswersAndRecomputesDeadlines() async {
        let clock = Clock()
        let cache = DNSLookupCache<String, Int>(capacity: 2, missing: -1,
            servesStaleOnFailure: true, now: { clock.now() })
        _ = await store("a", value: 1, ttl: 100, in: cache)
        let other = DNSUpstream.plain(host: "192.0.2.1", port: 53)
        #expect(cache.cachedValue(for: "a", from: other) == nil)
        let failure = await cache.value(for: "a", from: other) { nil }
        #expect(failure == -1) // Never reuse an answer from the previous upstream.
        _ = await cache.value(for: "b", from: other) { (2, 5) }
        clock.set(5)
        _ = await cache.value(for: "c", from: other) { (3, 100) }
        #expect(cache.flush() == 1)
    }

    @Test func optionalNilAnswerRemainsCachedUntilItsTTLExpires() async {
        let clock = Clock()
        let cache = DNSLookupCache<String, Int?>(capacity: 2, missing: nil, now: { clock.now() })
        let calls = Mutex(0)
        let lookup: DNSLookupCache<String, Int?>.Lookup = {
            calls.withLock { $0 += 1 }
            return (nil, 30) // ECH uses this shape for an absent configuration.
        }
        #expect(await cache.value(for: "a", from: .system, lookup: lookup) == nil)
        clock.set(29)
        #expect(await cache.value(for: "a", from: .system, lookup: lookup) == nil)
        #expect(calls.withLock { $0 } == 1)
        clock.set(30)
        #expect(await cache.value(for: "a", from: .system, lookup: lookup) == nil)
        #expect(calls.withLock { $0 } == 2)
    }
}
