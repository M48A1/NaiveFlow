import Foundation
import Testing
@testable import NaiveFlow

struct GroupProbeSettingsTests {
    private func nodes() -> [ProxyConfiguration] {
        (0..<4).map { ProxyConfiguration(name: "Node \($0)", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration())) }
    }

    @Test func groupsInheritSettingsButKeepURLOverridesAndIntervals() throws {
        let node = nodes()[0]
        let settings = LatencyTestSettings(url: "https://default.example/probe?x=1", timeoutSeconds: 4, concurrency: 2)
        let groups = [
            RuntimeProxyGroup(name: "Default", kind: .urlTest, memberIDs: [node.id], interval: 15),
            RuntimeProxyGroup(name: "Override", kind: .fallback, memberIDs: [node.id], interval: 60, url: "http://custom.example/check")
        ]
        let plans = ProxyProbePlan.groupProbes(groups: groups, nodes: [node.id: node], settings: settings)
        #expect(plans.count == 2)
        #expect(plans[0].probes.first?.target == settings.target)
        #expect(plans[0].group.interval == 15)
        #expect(plans[1].probes.first?.target.host == "custom.example")
        #expect(plans[1].group.interval == 60)
    }

    @Test func concurrentGroupsShareOneLimitAndUseConfiguredTimeout() async throws {
        let nodes = nodes()
        let map = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let settings = LatencyTestSettings(url: "https://default.example/probe", timeoutSeconds: 4, concurrency: 2)
        let groups = [
            RuntimeProxyGroup(name: "A", kind: .urlTest, memberIDs: nodes.map(\.id)),
            RuntimeProxyGroup(name: "B", kind: .fallback, memberIDs: nodes.map(\.id), url: "https://override.example/probe")
        ]
        let plans = ProxyProbePlan.groupProbes(groups: groups, nodes: map, settings: settings)
        let limiter = GroupProbeLimiter(limit: settings.concurrency)
        let recorder = ProbeRecorder()
        let tasks = plans.map { plan in
            Task {
                await GroupProbeBatch.run(probes: plan.probes, nodes: map, settings: settings, limiter: limiter) { _, target, timeout in
                    await recorder.test(target: target, timeout: timeout)
                }
            }
        }
        try await waitForTwo(recorder)
        #expect(await recorder.peak == 2)
        await recorder.release()
        for task in tasks { #expect(await task.value.count == 4) }
        #expect(await recorder.peak == 2)
        #expect(await recorder.targets.count == 8)
        #expect(await recorder.timeouts.allSatisfy { $0 == .seconds(4) })
        #expect(await recorder.targets.filter { $0.host == "default.example" }.count == 4)
        #expect(await recorder.targets.filter { $0.host == "override.example" }.count == 4)
    }

    @Test func cancelledBatchDoesNotPublishPartialResultsOrStartQueuedProbes() async throws {
        let nodes = nodes()
        let map = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let settings = LatencyTestSettings(concurrency: 2)
        let group = RuntimeProxyGroup(name: "A", kind: .urlTest, memberIDs: nodes.map(\.id))
        let plan = try #require(ProxyProbePlan.groupProbes(groups: [group], nodes: map, settings: settings).first)
        let recorder = ProbeRecorder()
        let limiter = GroupProbeLimiter(limit: 1)
        let task = Task {
            await GroupProbeBatch.run(probes: plan.probes, nodes: map, settings: settings, limiter: limiter) { _, target, timeout in
                await recorder.test(target: target, timeout: timeout)
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while await recorder.targets.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await recorder.release()
        #expect(await task.value.isEmpty)
        #expect(await recorder.targets.count == 1)
        // Cancellation released the permit, so a new batch can still run.
        let next = await limiter.run { .success(9) }
        #expect(next == .success(9))
    }

    private func waitForTwo(_ recorder: ProbeRecorder) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await recorder.targets.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await recorder.targets.count == 2)
    }

    private actor ProbeRecorder {
        var peak = 0
        var targets: [LatencyTarget] = []
        var timeouts: [Duration] = []
        private var active = 0
        private var gated = true
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func test(target: LatencyTarget, timeout: Duration) async -> LatencyResult {
            active += 1
            peak = max(peak, active)
            targets.append(target)
            timeouts.append(timeout)
            if gated { await withCheckedContinuation { waiting.append($0) } }
            active -= 1
            return .success(20)
        }

        func release() {
            gated = false
            let pending = waiting
            waiting = []
            for continuation in pending { continuation.resume() }
        }
    }
}
