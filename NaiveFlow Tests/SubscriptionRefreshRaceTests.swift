//
//  SubscriptionRefreshRaceTests.swift
//  NaiveFlow Tests
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation
import Testing
@testable import NaiveFlow

@MainActor
struct SubscriptionRefreshRaceTests {

    /// One-shot latch the injected fetch parks on until the test opens it, so a
    /// test can decide which refresh's response returns first.
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

    private func makeReaction(sync: SyncStore, configurationStore: ConfigurationStore) -> StoreMutationReaction {
        let chainStore = ChainStore(syncStore: sync)
        let routingStore = RoutingRuleSetStore(syncStore: sync)
        let moduleStore = ModuleStore(syncStore: sync)
        let mitmStore = MITMRuleSetStore(syncStore: sync)
        // A near-infinite debounce keeps the export work from running inside the test.
        return StoreMutationReaction(
            configurationStore: configurationStore,
            chainStore: chainStore,
            routingRuleSetStore: routingStore,
            moduleStore: moduleStore,
            selection: ProxySelection(),
            latency: LatencyCenter(),
            appState: AppState(),
            routingExportScheduler: RoutingExportScheduler(
                debouncer: Debouncer(interval: .seconds(3600)),
                ruleSetStore: routingStore,
                moduleStore: moduleStore,
                configurationStore: configurationStore,
                chainStore: chainStore
            ),
            mitmExportScheduler: MITMExportScheduler(
                debouncer: Debouncer(interval: .seconds(3600)),
                ruleSetStore: mitmStore,
                moduleStore: moduleStore
            )
        )
    }

    private func node(_ name: String, subscriptionId: UUID) -> ProxyConfiguration {
        ProxyConfiguration(
            id: UUID(), name: name, serverAddress: "1.1.1.1", serverPort: 443,
            subscriptionId: subscriptionId, outbound: .direct(DirectConfiguration())
        )
    }

    private func response(_ configurations: [ProxyConfiguration], name: String) -> SubscriptionFetcher.Result {
        SubscriptionFetcher.Result(
            configurations: configurations, stableKeys: [:], name: name,
            upload: nil, download: nil, total: nil, expire: nil, iconLight: nil, iconDark: nil
        )
    }

    private func committedNames(_ store: ConfigurationStore, _ subscriptions: SubscriptionStore) -> [String] {
        guard let subscription = subscriptions.subscriptions.first else { return [] }
        return store.configurations(for: subscription).map(\.name).sorted()
    }

    // MARK: - Coordinator

    @Test func newerTicketSupersedesOlderOne() {
        let coordinator = SubscriptionRefreshCoordinator()
        let id = UUID()
        let stale = coordinator.begin(id)
        let fresh = coordinator.begin(id)
        #expect(!coordinator.isCurrent(id, ticket: stale))
        #expect(coordinator.isCurrent(id, ticket: fresh))
        coordinator.end(id, ticket: stale)
        #expect(coordinator.isCurrent(id, ticket: fresh))
        coordinator.end(id, ticket: fresh)
        #expect(!coordinator.isCurrent(id, ticket: fresh))
    }

    @Test func ticketsAreScopedPerSubscription() {
        let coordinator = SubscriptionRefreshCoordinator()
        let first = UUID()
        let second = UUID()
        let firstTicket = coordinator.begin(first)
        let secondTicket = coordinator.begin(second)
        #expect(coordinator.isCurrent(first, ticket: firstTicket))
        #expect(coordinator.isCurrent(second, ticket: secondTicket))
    }

    // MARK: - Integration

    /// Regression: refreshing the same subscription twice (for example from the
    /// proxies list and the data page) must not let the earlier request's late
    /// response overwrite the nodes the newer request already committed.
    @Test func staleRefreshCannotOverwriteNewerNodes() async throws {
        let sync = SyncStore.ephemeral()
        let configurationStore = ConfigurationStore(syncStore: sync)
        let subscriptionStore = SubscriptionStore(syncStore: sync)
        let subscription = Subscription(name: "Feed", url: "https://example.com/feed")
        subscriptionStore.add(subscription)
        let reaction = makeReaction(sync: sync, configurationStore: configurationStore)

        let gates = [Gate(), Gate()]
        let responses = [
            response([node("STALE", subscriptionId: subscription.id)], name: "STALE"),
            response([node("FRESH", subscriptionId: subscription.id)], name: "FRESH"),
        ]
        var callIndex = 0
        let operation = SubscriptionOperations(
            store: subscriptionStore,
            configurationStore: configurationStore,
            reaction: reaction,
            coordinator: SubscriptionRefreshCoordinator(),
            fetch: { _ in
                let index = callIndex
                callIndex += 1
                await gates[index].wait()
                return responses[index]
            }
        )

        // The older request starts and parks inside its fetch.
        let older = Task { @MainActor in try await operation.refresh(subscription) }
        try await waitUntil { callIndex == 1 }

        // The newer request starts, supersedes the older ticket, and its response
        // returns first, committing the fresh nodes.
        let newer = Task { @MainActor in try await operation.refresh(subscription) }
        try await waitUntil { callIndex == 2 }
        gates[1].open()
        try await newer.value
        #expect(committedNames(configurationStore, subscriptionStore) == ["FRESH"])

        // The stale response finally lands; it must be discarded, not committed.
        gates[0].open()
        try await older.value
        #expect(committedNames(configurationStore, subscriptionStore) == ["FRESH"])
    }
}
