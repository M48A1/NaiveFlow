//
//  BuiltInGroupMembershipTests.swift
//  NaiveFlow Tests
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation
import Testing
@testable import NaiveFlow

/// A built-in `DIRECT` used as an automatic-group member must become a real,
/// probeable node instead of being silently dropped by member expansion. Built-in
/// `REJECT` / `PROXY`, which cannot be probed or dialed, are rejected outright so
/// the accepted configuration does not silently change behavior.
struct BuiltInGroupMembershipTests {

    private func compile(_ text: String) -> TextConfigurationPipeline.Result {
        ConfigurationCoordinator().compile(text: text)
    }

    @Test func automaticGroupRetainsBuiltInDirectAsProbeableNode() {
        let result = compile("""
            [Proxy]
            Node = socks5://1.2.3.4:1080#Node
            [Proxy Group]
            Fallback = fallback, DIRECT, Node
            [Rule]
            FINAL, Fallback
            """)
        #expect(result.isActivatable)

        let compiled = result.compiled
        guard let group = compiled.policyGroups.first(where: { $0.name == "Fallback" }) else {
            Issue.record("expected the Fallback group to compile")
            return
        }
        // DIRECT is retained: a synthesized direct node plus the declared Node.
        #expect(group.memberIDs.count == 2)
        let nodeByID = Dictionary(
            uniqueKeysWithValues: (compiled.proxies + compiled.syntheticProxies).map { ($0.id, $0) }
        )
        let members = group.memberIDs.compactMap { nodeByID[$0] }
        #expect(members.contains { $0.isDirect })
        #expect(members.contains { !$0.isDirect })
    }

    @Test func rejectAsAutomaticGroupMemberIsRejected() {
        let result = compile("""
            [Proxy]
            Node = socks5://1.2.3.4:1080#Node
            [Proxy Group]
            Fallback = fallback, Node, REJECT
            [Rule]
            FINAL, Fallback
            """)
        #expect(!result.isActivatable)
        #expect(result.diagnostics.contains { $0.severity == .error && $0.message.contains("REJECT") })
    }

    // MARK: - Nested groups inside an automatic group

    /// A nested `select` group always routes to exactly one node (its
    /// `selected`, else its first member), so the parent must *delegate* to that
    /// node rather than flattening the child to every leaf. Flattening let a
    /// `url-test` parent dial a node the child's `selected` explicitly skipped.
    /// Here `Auto` must carry only `B` — the node `Choice` selects — even though
    /// `A` has far lower latency in the probe results.
    @Test func automaticGroupDelegatesToNestedSelectGroupSelection() {
        let result = compile("""
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            B = socks5://5.6.7.8:1080#B
            [Proxy Group]
            Choice = select, A, B, selected = B
            Auto = url-test, Choice
            [Rule]
            FINAL, Auto
            """)
        #expect(result.isActivatable)
        #expect(!result.diagnostics.contains { $0.severity == .error })

        let compiled = result.compiled
        guard let group = compiled.policyGroups.first(where: { $0.name == "Auto" }) else {
            Issue.record("expected the Auto group to compile")
            return
        }
        let aID = compiled.proxies.first { $0.name == "A" }?.id
        let bID = compiled.proxies.first { $0.name == "B" }?.id
        #expect(group.memberIDs == [bID])

        // Even with A measured as much faster, the delegated member is B.
        guard let aID, let bID else { Issue.record("expected A and B nodes"); return }
        let chosen = ProxyGroupSelector.select(
            group: group, latencies: [aID: 1, bID: 5_000], roundRobinIndex: 0
        )
        #expect(chosen == bID)
    }

    /// A `select` child with no `selected` defaults to its first member, so the
    /// parent carries that first node.
    @Test func automaticGroupDelegatesToNestedSelectGroupDefaultFirstMember() {
        let result = compile("""
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            B = socks5://5.6.7.8:1080#B
            [Proxy Group]
            Choice = select, A, B
            Auto = fallback, Choice
            [Rule]
            FINAL, Auto
            """)
        #expect(result.isActivatable)
        guard let group = result.compiled.policyGroups.first(where: { $0.name == "Auto" }) else {
            Issue.record("expected the Auto group to compile")
            return
        }
        let aID = result.compiled.proxies.first { $0.name == "A" }?.id
        #expect(group.memberIDs == [aID])
    }

    /// A nested *automatic* group picks its member at dial time (by probing),
    /// which cannot be collapsed into the parent's flat probe list without
    /// losing its strategy — reject it at activation rather than flattening.
    @Test func automaticGroupRejectsNestedFallbackGroupMember() {
        let result = compile("""
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            B = socks5://5.6.7.8:1080#B
            [Proxy Group]
            Inner = fallback, A, B
            Outer = url-test, Inner
            [Rule]
            FINAL, Outer
            """)
        #expect(!result.isActivatable)
        #expect(result.diagnostics.contains {
            $0.severity == .error && $0.message.contains("Inner") && $0.message.lowercased().contains("nested")
        })
    }

    @Test func automaticGroupRejectsNestedUrlTestGroupMember() {
        let result = compile("""
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            B = socks5://5.6.7.8:1080#B
            [Proxy Group]
            Inner = url-test, A, B
            Outer = fallback, Inner
            [Rule]
            FINAL, Outer
            """)
        #expect(!result.isActivatable)
        #expect(result.diagnostics.contains {
            $0.severity == .error && $0.message.contains("Inner") && $0.message.lowercased().contains("nested")
        })
    }

    /// A `select` child resolves to one node only while its `selected`/first
    /// link stays within `select` groups. Once the chain reaches an automatic
    /// group the parent has no single compile-time node to carry (the automatic
    /// group's pick is dial-time), so the document must be rejected — not
    /// silently flattened to that group's leaves.
    @Test func automaticGroupRejectsNestedSelectChainReachingAutomaticGroup() {
        let result = compile("""
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            B = socks5://5.6.7.8:1080#B
            [Proxy Group]
            Inner = url-test, A, B
            Choice = select, Inner, selected = Inner
            Outer = fallback, Choice
            [Rule]
            FINAL, Outer
            """)
        #expect(!result.isActivatable)
        #expect(result.diagnostics.contains {
            $0.severity == .error && $0.message.contains("Choice") && $0.message.lowercased().contains("nested")
        })
    }

    /// A `select` group, unlike an automatic one, *can* point at another group:
    /// its `selected` resolves to that group's stable id and the engine applies
    /// the child's own strategy at dial time. This must keep working so the fix
    /// rejects only the case it cannot represent, not every group-of-groups.
    @Test func selectGroupMayDelegateToAutomaticGroup() {
        let result = compile("""
            [Proxy]
            A = socks5://1.2.3.4:1080#A
            B = socks5://5.6.7.8:1080#B
            [Proxy Group]
            Auto = url-test, A, B
            Choice = select, Auto, selected = Auto
            [Rule]
            FINAL, Choice
            """)
        #expect(result.isActivatable)
        #expect(!result.diagnostics.contains { $0.severity == .error })
        #expect(result.compiled.policyGroups.contains { $0.name == "Auto" })
    }
}
