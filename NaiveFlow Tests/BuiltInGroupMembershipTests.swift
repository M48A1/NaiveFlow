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
}
