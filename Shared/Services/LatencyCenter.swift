//
//  LatencyCenter.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/3/26.
//

import Foundation
import NetworkExtension
import Observation

@MainActor
protocol LatencyTransport: AnyObject, Sendable {
    var isTunnelActive: Bool { get }
    func sendRaw(_ data: Data) async -> Data?
}

@MainActor
@Observable
final class LatencyCenter {
    var latencyResults: [UUID: LatencyResult] = [:]

    @ObservationIgnored private let settingsProvider: @MainActor () -> LatencyTestSettings

    init(settingsProvider: @escaping @MainActor () -> LatencyTestSettings = { LatencyTestSettings.load() }) {
        self.settingsProvider = settingsProvider
        restoreResults()
    }

    // MARK: - Configuration Tests

    @ObservationIgnored private var batchLatencyTask: Task<Void, Never>?
    @ObservationIgnored private var batchLatencyTargetIds: Set<UUID> = []
    @ObservationIgnored private var singleLatencyTasks: [UUID: Task<Void, Never>] = [:]

    func testLatency(
        for configuration: ProxyConfiguration,
        transport: LatencyTransport?,
        isLive: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in true }
    ) {
        let configurationId = configuration.id
        singleLatencyTasks[configurationId]?.cancel()
        latencyResults[configurationId] = .testing
        let settings = settingsProvider().effective
        let send = Self.tunnelSend(transport)
        singleLatencyTasks[configurationId] = Task { [weak self] in
            let result = await Self.runSingleLatencyTest(for: configuration, settings: settings, send: send)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self?.singleLatencyTasks[configurationId] = nil
                self?.recordLatencyResult(result, for: configurationId, isLive: isLive)
            }
        }
    }

    func testLatencies(
        for targets: [ProxyConfiguration],
        transport: LatencyTransport?,
        isLive: @escaping @MainActor @Sendable (UUID) -> Bool = { _ in true }
    ) {
        batchLatencyTask?.cancel()
        let targetIds = Set(targets.map(\.id))
        restoreDisplacedResults(in: \.latencyResults, stored: storedLatencyResults, previousTargets: batchLatencyTargetIds, newTargets: targetIds)
        batchLatencyTargetIds = targetIds
        for config in targets {
            latencyResults[config.id] = .testing
        }
        let settings = settingsProvider().effective
        let send = Self.tunnelSend(transport)
        batchLatencyTask = Task { [weak self] in
            await Self.runLatencyTests(targets, settings: settings, send: send, isStillWanted: isLive) { id, result in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.recordLatencyResult(result, for: id, isLive: isLive)
                }
            }
        }
    }

    private func restoreDisplacedResults(
        in results: ReferenceWritableKeyPath<LatencyCenter, [UUID: LatencyResult]>,
        stored: [UUID: LatencyResult],
        previousTargets: Set<UUID>,
        newTargets: Set<UUID>
    ) {
        for staleId in previousTargets where !newTargets.contains(staleId) {
            if self[keyPath: results][staleId] == .testing {
                self[keyPath: results][staleId] = stored[staleId]
            }
        }
    }

    // MARK: - Persistence

    @ObservationIgnored private var storedLatencyResults: [UUID: LatencyResult] = [:]

    private func restoreResults() {
        storedLatencyResults = Self.decodeLatencyResults(AWCore.getLatencyResultsData())
        latencyResults = storedLatencyResults
    }

    private func recordLatencyResult(
        _ result: LatencyResult,
        for configurationId: UUID,
        isLive: @MainActor (UUID) -> Bool
    ) {
        guard isLive(configurationId) else { return }
        latencyResults[configurationId] = result
        storedLatencyResults[configurationId] = result
        if let data = Self.encodeLatencyResults(storedLatencyResults) {
            AWCore.setLatencyResultsData(data)
        }
    }

    private static func encodeLatencyResults(_ results: [UUID: LatencyResult]) -> Data? {
        try? JSONEncoder().encode(results.mapValues { LatencyTestResponse($0) })
    }

    private static func decodeLatencyResults(_ data: Data?) -> [UUID: LatencyResult] {
        guard let data,
              let responses = try? JSONDecoder().decode([UUID: LatencyTestResponse].self, from: data) else {
            return [:]
        }
        return responses.mapValues { $0.asLatencyResult }
    }

    // MARK: - Execution

    private static func tunnelSend(_ transport: LatencyTransport?) -> (@Sendable (Data) async -> Data?)? {
        guard let transport, transport.isTunnelActive else { return nil }
        return { [weak transport] data in await transport?.sendRaw(data) }
    }

    nonisolated private static func runSingleLatencyTest(
        for configuration: ProxyConfiguration,
        settings: LatencyTestSettings,
        send: (@Sendable (Data) async -> Data?)?
    ) async -> LatencyResult {
        if let send {
            return await sendLatencyTestMessage(for: configuration, settings: settings, send: send)
        }
        return await LatencyTester.test(configuration, target: settings.target, timeout: settings.timeout)
    }

    nonisolated private static func runLatencyTests(
        _ configurations: [ProxyConfiguration],
        settings: LatencyTestSettings,
        send: (@Sendable (Data) async -> Data?)?,
        isStillWanted: (@MainActor @Sendable (UUID) -> Bool)? = nil,
        onResult: @Sendable @escaping (UUID, LatencyResult) async -> Void
    ) async {
        guard !configurations.isEmpty else { return }
        await withTaskGroup(of: (UUID, LatencyResult).self) { group in
            var iterator = configurations.makeIterator()
            for _ in 0..<min(settings.concurrency, configurations.count) {
                if let config = iterator.next() {
                    group.addTask {
                        let r = await runSingleLatencyTest(for: config, settings: settings, send: send)
                        return (config.id, r)
                    }
                }
            }
            for await pair in group {
                await onResult(pair.0, pair.1)
                while let config = iterator.next() {
                    if let isStillWanted, await !isStillWanted(config.id) { continue }
                    group.addTask {
                        let r = await runSingleLatencyTest(for: config, settings: settings, send: send)
                        return (config.id, r)
                    }
                    break
                }
            }
        }
    }

    nonisolated private static func sendLatencyTestMessage(
        for configuration: ProxyConfiguration,
        settings: LatencyTestSettings,
        send: @Sendable (Data) async -> Data?
    ) async -> LatencyResult {
        guard let messageData = try? JSONEncoder().encode(TunnelMessage.testLatencyWithSettings(configuration, settings)) else { return .failed }

        let responseData = await send(messageData)
        return (responseData.flatMap { try? JSONDecoder().decode(LatencyTestResponse.self, from: $0) })?.asLatencyResult ?? .failed
    }
}
