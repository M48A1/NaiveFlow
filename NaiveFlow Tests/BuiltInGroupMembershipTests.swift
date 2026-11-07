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

    /// A parent automatic group selects among *its* probeable members. This
    /// engine models those members as a flat list of node ids, so a member that
    /// names another group would be flattened to every leaf of that group and
    /// the parent could dial a node the child never chose (for a `select` child,
    /// one whose `selected` pointer was ignored). That configuration must be
    /// refused at activation instead of silently expanding.
    @Test func automaticGroupRejectsNestedSelectGroupMember() {
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
        #expect(!result.isActivatable)
        #expect(result.diagnostics.contains {
            $0.severity == .error && $0.message.contains("Choice") && $0.message.lowercased().contains("nested")
        })
    }

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
