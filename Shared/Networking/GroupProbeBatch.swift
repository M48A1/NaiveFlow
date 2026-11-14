import Foundation

/// Shared by every group's loop to cap total background probes.
actor GroupProbeLimiter {
    private let limit: Int
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func run(_ operation: @Sendable () async -> LatencyResult) async -> LatencyResult {
        guard await acquire() else { return .failed }
        defer { release() }
        guard !Task.isCancelled else { return .failed }
        return await operation()
    }

    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < limit { active += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().1.resume(returning: true) }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(returning: false)
    }
}

nonisolated enum GroupProbeBatch {
    typealias Test = @Sendable (ProxyConfiguration, LatencyTarget, Duration) async -> LatencyResult

    static func run(
        probes: [ProxyProbe],
        nodes: [UUID: ProxyConfiguration],
        settings: LatencyTestSettings,
        limiter: GroupProbeLimiter,
        test: @escaping Test = { await LatencyTester.test($0, target: $1, timeout: $2) }
    ) async -> [UUID: Int] {
        await withTaskGroup(of: (UUID, LatencyResult).self) { group in
            var iterator = probes.filter { nodes[$0.memberID] != nil }.makeIterator()
            func enqueue(_ probe: ProxyProbe) {
                guard let node = nodes[probe.memberID] else { return }
                group.addTask {
                    let result = await limiter.run { await test(node, probe.target, settings.timeout) }
                    return (probe.memberID, result)
                }
            }
            for _ in 0..<settings.effective.concurrency {
                guard !Task.isCancelled, let probe = iterator.next() else { break }
                enqueue(probe)
            }
            var results: [UUID: Int] = [:]
            for await (id, result) in group {
                guard !Task.isCancelled else { group.cancelAll(); return [:] }
                if case .success(let ms) = result { results[id] = ms }
                if let probe = iterator.next() { enqueue(probe) }
            }
            return results
        }
    }
}
