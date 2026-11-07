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

    @Test func compilerPreservesGroupKindMembersIntervalAndURL() {
        let compiled = ConfigurationCoordinator().compile(text: """
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            B = socks5://5.6.7.8:1080#B
            [Proxy Group]
            Auto = url-test, A, B, interval = 120, url = http://www.gstatic.com/generate_204
            """).compiled
        #expect(compiled.policyGroups.count == 1)
        let group = compiled.policyGroups[0]
        #expect(group.kind == .urlTest)
        #expect(group.name == "Auto")
        #expect(group.memberIDs.count == 2)
        #expect(group.interval == 120)
        #expect(group.url == "http://www.gstatic.com/generate_204")
    }

    @Test func compilerRejectsNonHTTPProbeURL() {
        let compiled = ConfigurationCoordinator().compile(text: """
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            [Proxy Group]
            Auto = url-test, A, url = ftp://example.com
            """).compiled
        let group = compiled.policyGroups[0]
        #expect(group.url == nil)
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

    // MARK: - Probe Targets

    @Test func latencyTargetPreservesSchemeHostPathAndQuery() {
        let target = LatencyTarget(url: "https://www.gstatic.com/generate_204?edge=1")
        #expect(target?.scheme == .https)
        #expect(target?.host == "www.gstatic.com")
        #expect(target?.port == 443)
        #expect(target?.path == "/generate_204?edge=1")
        #expect(target?.isSecure == true)
        #expect(target?.authority == "www.gstatic.com")
    }

    @Test func latencyTargetDefaultsPortsAndRootPath() {
        #expect(LatencyTarget(url: "http://example.com")?.port == 80)
        #expect(LatencyTarget(url: "http://example.com")?.path == "/")
        #expect(LatencyTarget(url: "https://example.com")?.port == 443)

        let explicit = LatencyTarget(url: "http://example.com:8080/health")
        #expect(explicit?.port == 8080)
        #expect(explicit?.path == "/health")
        #expect(explicit?.authority == "example.com:8080")
    }

    @Test func latencyTargetRejectsUndialableURLs() {
        #expect(LatencyTarget(url: "ftp://example.com") == nil)
        #expect(LatencyTarget(url: "example.com/generate_204") == nil)
        #expect(LatencyTarget(url: "https:///path") == nil)
    }

    @Test func captivePortalTargetMirrorsLegacyDefaults() {
        let target = LatencyTarget.captivePortal
        #expect(target.scheme == .http)
        #expect(target.host == "captive.apple.com")
        #expect(target.port == 80)
        #expect(target.path == "/")
        #expect(target.authority == "captive.apple.com")
    }

    @Test func groupProbeTargetUsesConfiguredURLOrDefault() {
        let withURL = RuntimeProxyGroup(
            name: "Auto", kind: .urlTest, memberIDs: [UUID()],
            url: "https://www.gstatic.com/generate_204"
        )
        #expect(withURL.probeTarget.host == "www.gstatic.com")
        #expect(withURL.probeTarget.scheme == .https)

        let withoutURL = RuntimeProxyGroup(name: "Manual", kind: .fallback, memberIDs: [UUID()])
        #expect(withoutURL.probeTarget.host == LatencyTarget.captivePortal.host)
    }

    @Test func probePlanMeasuresDirectNodesAndFallbackPicksLeadingDirectNode() {
        let compiled = ConfigurationCoordinator().compile(text: """
            [Proxy]
            D = direct
            P = socks5://5.6.7.8:1080#P
            [Proxy Group]
            Fall = fallback, D, P
            """).compiled

        let nodes = Dictionary(uniqueKeysWithValues: compiled.proxies.map { ($0.id, $0) })
        guard let direct = compiled.proxies.first(where: { $0.isDirect }),
              let proxy = compiled.proxies.first(where: { $0.name == "P" }),
              let group = compiled.policyGroups.first else {
            Issue.record("expected a direct node, a proxy node, and one automatic group")
            return
        }

        // The prober must measure the direct node, not skip it.
        let plans = ProxyProbePlan.groupProbes(groups: compiled.policyGroups, nodes: nodes)
        let probedMembers = Set(plans.flatMap { $0.probes.map(\.memberID) })
        #expect(probedMembers.contains(direct.id))
        #expect(probedMembers.contains(proxy.id))

        // A reachable direct member that leads the group wins over a later proxy.
        #expect(group.memberIDs.first == direct.id)
        let chosen = ProxyGroupSelector.select(
            group: group, latencies: [direct.id: 5, proxy.id: 9], roundRobinIndex: 0
        )
        #expect(chosen == direct.id)
    }

    @Test func sharedNodeIsProbedPerGroupAgainstEachGroupsURL() {
        let shared = UUID()
        let a = RuntimeProxyGroup(name: "A", kind: .urlTest, memberIDs: [shared],
                                  url: "https://a.example/probe")
        let b = RuntimeProxyGroup(name: "B", kind: .fallback, memberIDs: [shared],
                                  url: "https://b.example/probe")
        let nodes = [shared: ProxyConfiguration(
            name: "S", serverAddress: "1.2.3.4", serverPort: 443,
            outbound: .direct(DirectConfiguration())
        )]

        let plans = ProxyProbePlan.groupProbes(groups: [a, b], nodes: nodes)
        // The shared node is scheduled once per group, not collapsed to the first.
        #expect(plans.count == 2)
        let planA = plans.first { $0.group.id == a.id }
        let planB = plans.first { $0.group.id == b.id }
        #expect(planA?.probes.map(\.memberID) == [shared])
        #expect(planB?.probes.map(\.memberID) == [shared])
        // Each plan measures the node against that group's own URL.
        #expect(planA?.probes.first?.target.host == "a.example")
        #expect(planB?.probes.first?.target.host == "b.example")
        #expect(planA?.probes.first?.groupID == a.id)
        #expect(planB?.probes.first?.groupID == b.id)
    }
}
