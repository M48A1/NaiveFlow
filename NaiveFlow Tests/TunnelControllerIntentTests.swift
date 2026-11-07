//
//  TunnelControllerIntentTests.swift
//  NaiveFlow Tests
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation
import Testing
@testable import NaiveFlow

@MainActor
struct TunnelControllerIntentTests {
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

    @MainActor
    private final class Box { var entered = false }

    private struct Timeout: Error {}

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100_000 {
            if condition() { return }
            await Task.yield()
        }
        throw Timeout()
    }

    private func directNode() -> ProxyConfiguration {
        ProxyConfiguration(name: "Direct", serverAddress: "", serverPort: 0,
                           outbound: .direct(DirectConfiguration()))
    }

    /// Regression: disconnecting while a connect is still preparing must not let
    /// the pending preparation start the tunnel afterwards (no "stop then start").
    @Test func disconnectDuringPreparationDoesNotStart() async throws {
        let provider = ScriptedTunnelProvider()
        let controller = TunnelController(provider: provider)
        controller.start()
        try await waitUntil { controller.isManagerReady }

        let entered = Box()
        let gate = Gate()
        controller.connectPreparationOverride = {
            entered.entered = true
            await gate.wait()
        }

        controller.connect(using: directNode())
        try await waitUntil { entered.entered }

        controller.disconnect()
        gate.open()

        try await waitUntil { provider.stopCount == 1 }
        // Give the stale connect task a chance to (incorrectly) start.
        for _ in 0..<200 { await Task.yield() }
        #expect(provider.startRequests.isEmpty)
    }

    /// Sanity check: an uninterrupted connect still reaches `start`.
    @Test func connectStartsWhenNotInterrupted() async throws {
        let provider = ScriptedTunnelProvider()
        let controller = TunnelController(provider: provider)
        controller.start()
        try await waitUntil { controller.isManagerReady }

        controller.connect(using: directNode())
        try await waitUntil { !provider.startRequests.isEmpty }
        #expect(provider.startRequests.count == 1)
    }
}
