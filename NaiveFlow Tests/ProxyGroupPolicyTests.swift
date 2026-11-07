import Foundation
import Testing
@testable import NaiveFlow

struct ProxyGroupPolicyTests {

    // MARK: - Selector

    private func group(
        _ kind: RuntimeProxyGroup.Kind,
        members: [UUID],
        selected: UUID? = nil
    ) -> RuntimeProxyGroup {
        RuntimeProxyGroup(name: "G", kind: kind, memberIDs: members, selectedID: selected)
    }

    @Test func selectPrefersManualSelection() {
        let a = UUID(), b = UUID()
        let g = group(.select, members: [a, b], selected: b)
        #expect(ProxyGroupSelector.select(group: g, latencies: [:], roundRobinIndex: 0) == b)
    }

    @Test func selectFallsBackToFirstMember() {
        let a = UUID(), b = UUID()
        let g = group(.select, members: [a, b])
        #expect(ProxyGroupSelector.select(group: g, latencies: [:], roundRobinIndex: 0) == a)
    }

    @Test func urlTestPicksLowestLatency() {
        let a = UUID(), b = UUID(), c = UUID()
        let g = group(.urlTest, members: [a, b, c])
        #expect(ProxyGroupSelector.select(group: g, latencies: [a: 50, b: 10, c: 80], roundRobinIndex: 0) == b)
    }

    @Test func urlTestRanksUnmeasuredMembersLast() {
        let a = UUID(), b = UUID()
        let g = group(.urlTest, members: [a, b])
        // b 有(很差的)结果,a 未测,所以仍选 b
        #expect(ProxyGroupSelector.select(group: g, latencies: [b: 999], roundRobinIndex: 0) == b)
    }

    @Test func fallbackPicksFirstReachable() {
        let a = UUID(), b = UUID(), c = UUID()
        let g = group(.fallback, members: [a, b, c])
        #expect(ProxyGroupSelector.select(group: g, latencies: [b: 10, c: 20], roundRobinIndex: 0) == b)
    }

    @Test func fallbackKeepsFirstMemberWhenNoneReachable() {
        let a = UUID(), b = UUID()
        let g = group(.fallback, members: [a, b])
        #expect(ProxyGroupSelector.select(group: g, latencies: [:], roundRobinIndex: 0) == a)
    }

    @Test func loadBalanceRoundRobinsOverHealthyMembers() {
        let a = UUID(), b = UUID(), c = UUID()
        let g = group(.loadBalance, members: [a, b, c])
        let latencies: ProxyGroupSelector.Latencies = [a: 1, b: 2, c: 3]
        #expect(ProxyGroupSelector.select(group: g, latencies: latencies, roundRobinIndex: 0) == a)
        #expect(ProxyGroupSelector.select(group: g, latencies: latencies, roundRobinIndex: 1) == b)
        #expect(ProxyGroupSelector.select(group: g, latencies: latencies, roundRobinIndex: 2) == c)
        #expect(ProxyGroupSelector.select(group: g, latencies: latencies, roundRobinIndex: 3) == a)
    }

    @Test func loadBalanceSkipsUnhealthyMembers() {
        let a = UUID(), b = UUID(), c = UUID()
        let g = group(.loadBalance, members: [a, b, c])
        let latencies: ProxyGroupSelector.Latencies = [b: 2, c: 3]
        #expect(ProxyGroupSelector.select(group: g, latencies: latencies, roundRobinIndex: 0) == b)
        #expect(ProxyGroupSelector.select(group: g, latencies: latencies, roundRobinIndex: 1) == c)
        #expect(ProxyGroupSelector.select(group: g, latencies: latencies, roundRobinIndex: 2) == b)
    }

    @Test func emptyGroupSelectsNothing() {
        let g = group(.select, members: [])
        #expect(ProxyGroupSelector.select(group: g, latencies: [:], roundRobinIndex: 0) == nil)
    }

    // MARK: - Compilation

    @Test func compilerPreservesGroupKindMembersAndInterval() {
        let compiled = ConfigurationCoordinator().compile(text: """
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            B = socks5://5.6.7.8:1080#B
            [Proxy Group]
            Auto = url-test, A, B, interval = 120
            """).compiled
        #expect(compiled.policyGroups.count == 1)
        let group = compiled.policyGroups[0]
        #expect(group.kind == .urlTest)
        #expect(group.name == "Auto")
        #expect(group.memberIDs.count == 2)
        #expect(group.interval == 120)
    }

    @Test func selectGroupFlattensToItsSelectedNode() {
        let compiled = ConfigurationCoordinator().compile(text: """
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            B = socks5://5.6.7.8:1080#B
            [Proxy Group]
            G = select, A, B, selected = B
            [Rule]
            DOMAIN, example.com, G
            """).compiled
        // A `select` group is not modeled as a runtime policy group; it keeps
        // the recursive "selected" semantics and flattens to the chosen node.
        #expect(compiled.policyGroups.isEmpty)
        let nodeB = compiled.proxies.first { $0.name == "B" }?.id
        #expect(compiled.orderedRules.first?.action == nodeB.map { .proxy($0) })
    }

    @Test func smartAndRandomGroupsAreNotCompiled() {
        let compiled = ConfigurationCoordinator().compile(text: """
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            [Proxy Group]
            Auto = smart, A
            """).compiled
        // smart is rejected by the validator, so no policy group is produced.
        #expect(compiled.policyGroups.isEmpty)
    }

    @Test func stableIDIsDeterministic() {
        #expect(RuntimeProxyGroup.stableID(name: "Auto") == RuntimeProxyGroup.stableID(name: "Auto"))
        #expect(RuntimeProxyGroup.stableID(name: "Auto") != RuntimeProxyGroup.stableID(name: "Other"))
    }
}
