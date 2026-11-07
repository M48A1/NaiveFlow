//
//  ResourceRefreshRaceTests.swift
//  NaiveFlow Tests
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation
import Testing
@testable import NaiveFlow

@MainActor
struct ResourceRefreshRaceTests {
    /// One-shot latch the injected fetch parks on until the test opens it.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            if let continuation {
                self.continuation = nil
                continuation.resume()
            } else {
                opened = true
            }
        }
    }

    private struct Timeout: Error {}

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100_000 {
            if condition() { return }
            await Task.yield()
        }
        throw Timeout()
    }

    private func moduleStore(sync: SyncStore) -> (ModuleStore, RoutingExportScheduler, MITMExportScheduler) {
        let moduleStore = ModuleStore(syncStore: sync)
        let routingScheduler = RoutingExportScheduler(
            debouncer: Debouncer(interval: .seconds(3600)),
            ruleSetStore: RoutingRuleSetStore(syncStore: sync),
            moduleStore: moduleStore,
            configurationStore: ConfigurationStore(syncStore: sync),
            chainStore: ChainStore(syncStore: sync)
        )
        let mitmScheduler = MITMExportScheduler(
            debouncer: Debouncer(interval: .seconds(3600)),
            ruleSetStore: MITMRuleSetStore(syncStore: sync),
            moduleStore: moduleStore
        )
        return (moduleStore, routingScheduler, mitmScheduler)
    }

    // MARK: - Coordinator

    @Test func coordinatorSupersedesAndScopesPerKey() {
        let coordinator = RefreshTicketCoordinator<UUID>()
        let a = UUID(), b = UUID()
        let stale = coordinator.begin(a)
        let fresh = coordinator.begin(a)
        #expect(!coordinator.isCurrent(a, ticket: stale))
        #expect(coordinator.isCurrent(a, ticket: fresh))
        let other = coordinator.begin(b)
        #expect(coordinator.isCurrent(b, ticket: other))
        #expect(coordinator.isCurrent(a, ticket: fresh))
        coordinator.end(a, ticket: stale)
        #expect(coordinator.isCurrent(a, ticket: fresh))
        coordinator.end(a, ticket: fresh)
        #expect(!coordinator.isCurrent(a, ticket: fresh))
    }

    // MARK: - Module refresh ordering

    /// A slow, older module refresh must not overwrite content a newer refresh
    /// already committed (e.g. "Update All" racing a detail-page refresh).
    @Test func moduleRefreshKeepsNewestContent() async throws {
        let sync = SyncStore.ephemeral()
        let (store, routingScheduler, mitmScheduler) = moduleStore(sync: sync)
        let url = URL(string: "https://example.com/feed")!
        let seed = ModuleParser.parse("[Module]\nname=Feed\n").makeModule(name: "Feed", subscriptionURL: url)
        store.add(seed)
        let id = seed.id

        let fresh = "[Module]\nname=Feed\n[Routing]\nname=SetBeta\n"
        let stale = "[Module]\nname=Feed\n[Routing]\nname=SetAlpha\n"
        let gates = [Gate(), Gate()]
        var callIndex = 0

        var operations = ModuleOperations(
            moduleStore: store,
            routingExportScheduler: routingScheduler,
            mitmExportScheduler: mitmScheduler
        )
        operations.fetchBodyOverride = { _ in
            let index = callIndex
            callIndex += 1
            await gates[index].wait()
            return index == 1 ? fresh : stale
        }

        let older = Task { @MainActor in try await operations.refresh(id: id) }
        try await waitUntil { callIndex == 1 }

        let newer = Task { @MainActor in try await operations.refresh(id: id) }
        try await waitUntil { callIndex == 2 }

        // The newer response returns first and commits its content.
        gates[1].open()
        _ = try await newer.value
        #expect(store.module(id: id)?.routingRuleSets.map(\.name) == ["SetBeta"])

        // The stale response finally lands; it must be discarded, not committed.
        gates[0].open()
        _ = try await older.value
        #expect(store.module(id: id)?.routingRuleSets.map(\.name) == ["SetBeta"])
    }
}
