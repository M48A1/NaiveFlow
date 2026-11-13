//
//  DNSLookupCache.swift
//  NaiveFlow
//
//  Created by NodePassProject on 10/9/26.
//

import Foundation
import Synchronization

nonisolated final class DNSLookupCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    typealias Lookup = @Sendable () async -> (value: Value, ttl: TimeInterval)?

    private struct Entry: Sendable {
        let value: Value
        let expiry: TimeInterval
    }

    private enum Outcome: Sendable {
        case resolved(Value)
        case failed
    }

    private struct State: Sendable {
        var entries: [Key: Entry] = [:]
        // A conservative lower bound: refreshing or evicting the earliest entry
        // may leave an earlier deadline, which only causes an extra cleanup.
        var nextExpiry: TimeInterval = .infinity
        var inFlight: [Key: LookupBroadcast<Outcome>] = [:]
        var activeLookups = 0
        var upstream: DNSUpstream?
        var generation: UInt64 = 0
    }

    private enum Join {
        case hit(Value)
        case rejected
        case wait(LookupBroadcast<Outcome>, stale: Value?)
    }

    private let state = Mutex(State())
    private let capacity: Int
    private let maxInFlight: Int
    private let missing: Value
    private let servesStaleOnFailure: Bool
    private let waitLimit: Duration?
    private let now: @Sendable () -> TimeInterval
    
    init(capacity: Int, missing: Value, servesStaleOnFailure: Bool = false, waitLimit: Duration? = nil, maxInFlight: Int = 64,
         now: @escaping @Sendable () -> TimeInterval = { MonotonicClock.now }) {
        self.capacity = max(0, capacity)
        self.maxInFlight = max(0, maxInFlight)
        self.missing = missing
        self.servesStaleOnFailure = servesStaleOnFailure
        self.waitLimit = waitLimit
        self.now = now
    }

    var activeLookupCount: Int { state.withLock { $0.activeLookups } }

    // MARK: - Public API

    func cachedValue(for key: Key, from upstream: DNSUpstream) -> Value? {
        var retired: [LookupBroadcast<Outcome>] = []
        let value: Value? = state.withLock { state in
            retired = adopt(upstream, in: &state)
            guard let entry = state.entries[key], entry.expiry > now() else { return nil }
            return entry.value
        }
        Self.cancel(retired)
        return value
    }

    func value(
        for key: Key,
        from upstream: DNSUpstream,
        forceFresh: Bool = false,
        lookup: @escaping Lookup
    ) async -> Value {
        switch join(key, from: upstream, forceFresh: forceFresh, lookup: lookup) {
        case .hit(let value):
            return value
        case .rejected:
            return missing
        case .wait(let pending, let stale):
            if case .resolved(let value) = await wait(for: pending) { return value }
            return servesStaleOnFailure ? (stale ?? missing) : missing
        }
    }

    func warm(_ key: Key, from upstream: DNSUpstream, lookup: @escaping Lookup) {
        _ = join(key, from: upstream, forceFresh: false, lookup: lookup)
    }

    @discardableResult
    func flush() -> Int {
        var retired: [LookupBroadcast<Outcome>] = []
        let count = state.withLock { state in
            let count = state.entries.count
            retired = Self.reset(&state)
            return count
        }
        Self.cancel(retired)
        return count
    }

    // MARK: - Internal

    private func join(_ key: Key, from upstream: DNSUpstream, forceFresh: Bool, lookup: @escaping Lookup) -> Join {
        var retired: [LookupBroadcast<Outcome>] = []
        let joined: Join = state.withLock { state in
            retired = adopt(upstream, in: &state)
            let entry = state.entries[key]
            if let entry, !forceFresh, entry.expiry > now() { return .hit(entry.value) }
            guard !Task.isCancelled else { return .rejected }
            if let existing = state.inFlight[key] {
                return .wait(existing, stale: entry?.value)
            }

            guard !Task.isCancelled, state.activeLookups < maxInFlight else { return .rejected }
            state.activeLookups += 1
            let pending = LookupBroadcast<Outcome>()
            let scheduledGeneration = state.generation
            state.inFlight[key] = pending
            let task = Task { [self] in
                let result = await lookup()
                store(result, for: key, scheduledGeneration: scheduledGeneration, pending: pending)
                let outcome: Outcome = result.map { .resolved($0.value) } ?? .failed
                pending.publish(outcome)
            }
            pending.setTask(task)
            return .wait(pending, stale: entry?.value)
        }
        Self.cancel(retired)
        return joined
    }

    private func wait(for pending: LookupBroadcast<Outcome>) async -> Outcome {
        guard let waitLimit else { return await pending.value(orOnCancel: .failed) }
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await pending.value(orOnCancel: .failed) }
            group.addTask {
                try? await Task.sleep(for: waitLimit, precision: .relaxed)
                return .failed
            }
            defer { group.cancelAll() }
            return await group.next() ?? .failed
        }
    }

    private func store(
        _ result: (value: Value, ttl: TimeInterval)?,
        for key: Key,
        scheduledGeneration: UInt64,
        pending: LookupBroadcast<Outcome>
    ) {
        state.withLock { state in
            state.activeLookups -= 1
            if state.inFlight[key] === pending { state.inFlight.removeValue(forKey: key) }
            guard scheduledGeneration == state.generation, let result else { return }
            let now = now()
            state.entries[key] = Entry(value: result.value, expiry: now + result.ttl)
            state.nextExpiry = min(state.nextExpiry, now + result.ttl)
            Self.compact(&state, now: now, capacity: capacity)
        }
    }
    
    private func adopt(_ upstream: DNSUpstream, in state: inout State) -> [LookupBroadcast<Outcome>] {
        guard state.upstream != upstream else { return [] }
        state.upstream = upstream
        return Self.reset(&state)
    }

    private static func reset(_ state: inout State) -> [LookupBroadcast<Outcome>] {
        state.generation &+= 1
        state.entries.removeAll(keepingCapacity: false)
        state.nextExpiry = .infinity
        let retired = Array(state.inFlight.values)
        state.inFlight.removeAll(keepingCapacity: false)
        // Keep cancelled work charged until it actually completes.
        return retired
    }

    private static func cancel(_ retired: [LookupBroadcast<Outcome>]) {
        // Cancellation handlers may re-enter the resolver: never call under its lock.
        for pending in retired {
            pending.cancel()
            pending.publish(.failed)
        }
    }

    private static func compact(_ state: inout State, now: TimeInterval, capacity: Int) {
        guard state.nextExpiry <= now || state.entries.count > capacity else { return }
        var expired: [Key] = []
        var earliest: (key: Key, expiry: TimeInterval)?
        for (key, entry) in state.entries {
            if entry.expiry <= now {
                expired.append(key)
            } else if earliest == nil || entry.expiry < earliest!.expiry {
                earliest = (key, entry.expiry)
            }
        }
        for key in expired { state.entries.removeValue(forKey: key) }
        // Each store adds at most one entry, so one eviction restores capacity.
        if state.entries.count > capacity, let earliest {
            state.entries.removeValue(forKey: earliest.key)
        }
        state.nextExpiry = state.entries.isEmpty ? .infinity : (earliest?.expiry ?? .infinity)
    }
}

private nonisolated final class LookupBroadcast<Value: Sendable>: Sendable {
    private enum Enrollment: Sendable {
        case published(Value)
        case enrolled
    }

    private struct State {
        var value: Value?
        var waiters: [UInt64: CheckedContinuation<Value, Never>] = [:]
        var nextWaiterID: UInt64 = 0
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func setTask(_ task: Task<Void, Never>) {
        state.withLock { $0.task = task }
    }

    func cancel() {
        let task = state.withLock { $0.task }
        task?.cancel()
    }

    func publish(_ value: Value) {
        let waiters: [CheckedContinuation<Value, Never>] = state.withLock { state in
            guard state.value == nil else { return [] }
            state.task = nil
            state.value = value
            let drained = Array(state.waiters.values)
            state.waiters.removeAll()
            return drained
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    func value(orOnCancel fallback: Value) async -> Value {
        let waiterID: UInt64 = state.withLock { state in
            state.nextWaiterID &+= 1
            return state.nextWaiterID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                let enrollment: Enrollment = state.withLock { state in
                    if let value = state.value { return .published(value) }
                    guard state.waiters.count < 64 else { return .published(fallback) }
                    state.waiters[waiterID] = continuation
                    return .enrolled
                }
                switch enrollment {
                case .published(let value):
                    continuation.resume(returning: value)
                case .enrolled:
                    if Task.isCancelled { withdraw(waiterID, fallback: fallback) }
                }
            }
        } onCancel: {
            withdraw(waiterID, fallback: fallback)
        }
    }

    private func withdraw(_ waiterID: UInt64, fallback: Value) {
        let waiter = state.withLock { $0.waiters.removeValue(forKey: waiterID) }
        waiter?.resume(returning: fallback)
    }
}
