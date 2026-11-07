//
//  DomainRouter.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation
import Synchronization

nonisolated private let logger = NaiveFlowLogger(category: "DomainRouter")

nonisolated final class DomainRouter: Sendable {

    // MARK: - Tier model
    
    fileprivate enum Tier: Int, CaseIterable {
        case adBlock = 0
        case builtIn = 1
        case user = 2
        case neutral = 3
        case bypass = 4
    }

    fileprivate struct RulePayload: Hashable, Sendable {
        var action: RouteTarget
        var entryIndex: UInt16
    }

    struct Match: Sendable {
        let action: RouteTarget
        let ruleSetName: String?
    }

    fileprivate struct RoutingState: Sendable {
        var matcher = TieredRouteMatcher<RulePayload>(tierCount: Tier.allCases.count)
        var ordered: OrderedRouteMatcher?
        var configurationMap: [UUID: ProxyConfiguration] = [:]
        /// Text-configured groups by stable id, resolved to a member at dial time.
        var policyGroups: [UUID: RuntimeProxyGroup] = [:]
        /// Per-group dial counter for `load-balance` round-robin.
        var roundRobin: [UUID: Int] = [:]
        /// Latest probe results keyed by member node id (`ms`). Absent = unknown
        /// or unreachable. Fed by the in-tunnel prober.
        var latencies: [UUID: Int] = [:]
        var ruleSetNames: [String] = []
        var version: UInt64 = 1

        func match(resolving payload: RulePayload?) -> Match? {
            guard let payload else { return nil }
            let index = Int(payload.entryIndex)
            let name = index < ruleSetNames.count ? ruleSetNames[index] : nil
            return Match(action: payload.action, ruleSetName: (name?.isEmpty ?? true) ? nil : name)
        }

        // MARK: Streaming ingestion

        mutating func ingestConfigurations(_ slice: Data) throws(NaiveFlowError) {
            guard let configurations = try? JSONDecoder().decode([String: ProxyConfiguration].self, from: slice) else {
                throw NaiveFlowError.routing(.payloadCorrupted(.malformed))
            }
            for (key, configuration) in configurations {
                guard let configurationId = UUID(uuidString: key) else { continue }
                configurationMap[configurationId] = configuration
            }
        }

        mutating func reserveCIDRv4(tierIndex: Int, additionalPrefixes: Int) {
            matcher.tiers[tierIndex].reserveIPv4(additionalPrefixes: additionalPrefixes)
        }

        mutating func ingestRule(tierIndex: Int, payload: RulePayload, type: RoutingRuleType,
                                 valueStart: Int, length: Int, base: UnsafeBufferPointer<UInt8>) {
            switch type {
            case .domainSuffix:
                matcher.tiers[tierIndex].collectSuffix(offset: valueStart, length: length, payload: payload)
            case .domainKeyword:
                matcher.tiers[tierIndex].insertKeyword(String(decoding: base[valueStart..<valueStart + length], as: UTF8.self), payload: payload)
            case .ipCIDR:
                if let parsed = RouteMatching.parseIPv4CIDR(String(decoding: base[valueStart..<valueStart + length], as: UTF8.self)) {
                    matcher.tiers[tierIndex].insertIPv4(network: parsed.network, prefixLen: parsed.prefixLen, payload: payload)
                }

            }
        }
    }

    private let routingState = Mutex(RoutingState())

    var currentRulesVersion: UInt64 { routingState.withLock { $0.version } }

    // MARK: - Loading

    func reset() {
        _ = replaceRoutingState(with: RoutingState())
    }

    func loadRoutingConfiguration() {
        let newState = Self.makeRoutingState()
        _ = replaceRoutingState(with: newState)
    }
    
    private func replaceRoutingState(with replacement: RoutingState) -> RoutingState {
        routingState.withLock { state in
            var displaced = replacement
            displaced.version = state.version &+ 1
            swap(&state, &displaced)
            return displaced
        }
    }

    struct CompiledRouting: Sendable {
        fileprivate let state: RoutingState
    }

    @concurrent
    func compileRoutingConfiguration() async -> CompiledRouting {
        CompiledRouting(state: Self.makeRoutingState())
    }

    func install(_ compiled: CompiledRouting) {
        _ = replaceRoutingState(with: compiled.state)
    }

    private static func makeRoutingState(data: Data? = AWCore.getRoutingData()) -> RoutingState {
        var state = RoutingState()
        guard let data else { return state }

        do {
            let unresolvedEntries = try data.withUnsafeBytes { raw -> [Int] in
                let base = raw.bindMemory(to: UInt8.self)
                var reader = RoutingBinaryReader(bytes: base, data: data)
                try reader.run(state: &state)
                state.matcher.finalize(base: base)
                return reader.unresolvedEntries
            }
            for index in unresolvedEntries {
                let name = index < state.ruleSetNames.count ? state.ruleSetNames[index] : ""
                logger.warning("[Routing] \(name.isEmpty ? "#\(index)" : name): Proxy not found")
            }
        } catch {
            logger.report(error)
            return RoutingState()
        }
        
        return state
    }

    // MARK: - Payload reader

    private struct RoutingBinaryReader {
        let bytes: UnsafeBufferPointer<UInt8>
        let data: Data
        private var cursor = 0
        private var count: Int { bytes.count }
        
        private var version: RoutingBinaryFormat.Version = .v2
        private var legacyDefaultTargetId: UUID?
        private(set) var unresolvedEntries: [Int] = []

        init(bytes: UnsafeBufferPointer<UInt8>, data: Data) {
            self.bytes = bytes
            self.data = data
        }

        mutating func run(state: inout RoutingState) throws(NaiveFlowError) {
            version = try readMagic()
            if version == .v1 {
                legacyDefaultTargetId = AWCore.getSelectedChainId() ?? AWCore.getSelectedConfigurationId()
            }

            let configLength = Int(try u32())
            let configStart = cursor
            try advance(configLength)
            if configLength > 0 {
                try state.ingestConfigurations(data.subdata(in: (data.startIndex + configStart)..<(data.startIndex + configStart + configLength)))
            }

            let entryCount = try u32()
            for entryIndex in 0..<entryCount {
                try readEntry(state: &state, entryIndex: UInt16(clamping: entryIndex))
            }
            
            if version == .v1 {
                state.ruleSetNames = []
            } else {
                state.ruleSetNames = try readNames(expectedCount: entryCount)
            }
        }

        private mutating func readNames(expectedCount: UInt32) throws(NaiveFlowError) -> [String] {
            let nameCount = try u32()
            guard nameCount == expectedCount else { throw NaiveFlowError.routing(.payloadCorrupted(.malformed)) }
            var names: [String] = []
            names.reserveCapacity(Int(nameCount))
            for _ in 0..<nameCount {
                let length = Int(try u16())
                guard cursor + length <= count else { throw NaiveFlowError.routing(.payloadCorrupted(.truncated)) }
                names.append(String(decoding: bytes[cursor..<cursor + length], as: UTF8.self))
                cursor += length
            }
            return names
        }

        private mutating func readEntry(state: inout RoutingState, entryIndex: UInt16) throws(NaiveFlowError) {
            let tier = try readTier()
            let action = try readAction(configurations: state.configurationMap)
            if case .proxy(let id) = action, state.configurationMap[id] == nil {
                unresolvedEntries.append(Int(entryIndex))
            }
            let payload = RulePayload(action: action, entryIndex: entryIndex)

            var remainingRules = try u32()
            let reserveHint = min(Int(remainingRules), count / 3)
            var reservedV4 = false
            while remainingRules > 0 {
                let typeByte = try u8()
                let length = Int(try u16())
                let valueStart = cursor
                try advance(length)
                // Type 1 was the removed address-family rule. Reject old
                // payloads containing it rather than silently dropping policy.
                guard typeByte != 1 else { throw NaiveFlowError.routing(.payloadCorrupted(.malformed)) }
                if let type = RoutingRuleType(rawValue: Int(typeByte)) {
                    if type == .ipCIDR, !reservedV4 {
                        state.reserveCIDRv4(tierIndex: Int(tier.rawValue), additionalPrefixes: reserveHint)
                        reservedV4 = true
                    }
                    state.ingestRule(tierIndex: Int(tier.rawValue), payload: payload, type: type,
                                     valueStart: valueStart, length: length, base: bytes)
                }
                remainingRules -= 1
            }
        }

        private mutating func readTier() throws(NaiveFlowError) -> RoutingBinaryFormat.Tier {
            let raw = try u8()
            let tier: RoutingBinaryFormat.Tier? = switch version {
            case .v1: RoutingBinaryFormat.LegacyTier(rawValue: raw)?.current
            case .v2: RoutingBinaryFormat.Tier(rawValue: raw)
            }
            guard let tier else { throw NaiveFlowError.routing(.payloadCorrupted(.malformed)) }
            return tier
        }

        private mutating func readAction(configurations: [UUID: ProxyConfiguration]) throws(NaiveFlowError) -> RouteTarget {
            switch version {
            case .v1: return try readLegacyAction(configurations: configurations)
            case .v2: return try readCurrentAction()
            }
        }

        private mutating func readCurrentAction() throws(NaiveFlowError) -> RouteTarget {
            switch RoutingBinaryFormat.Action(rawValue: try u8()) {
            case .fallback: return .default
            case .defaultProxy: return .defaultProxy
            case .direct: return .direct
            case .reject: return .reject
            case .proxy: return .proxy(try readUUID())
            case nil: throw NaiveFlowError.routing(.payloadCorrupted(.malformed))
            }
        }
        
        private mutating func readLegacyAction(configurations: [UUID: ProxyConfiguration]) throws(NaiveFlowError) -> RouteTarget {
            guard let action = RoutingBinaryFormat.LegacyAction(rawValue: try u8()) else {
                throw NaiveFlowError.routing(.payloadCorrupted(.malformed))
            }
            switch action {
            case .direct: return .direct
            case .reject: return .reject
            case .proxy:
                let id = try readUUID()
                guard configurations[id] != nil, id != legacyDefaultTargetId else { return .default }
                return .proxy(id)
            }
        }

        // MARK: Primitives

        private mutating func readMagic() throws(NaiveFlowError) -> RoutingBinaryFormat.Version {
            let magic = RoutingBinaryFormat.magic
            guard cursor + magic.count <= count else { throw NaiveFlowError.routing(.payloadCorrupted(.truncated)) }
            let head = bytes[cursor..<cursor + magic.count]
            let version: RoutingBinaryFormat.Version
            if head.elementsEqual(magic) {
                version = .v2
            } else if head.elementsEqual(RoutingBinaryFormat.legacyMagic) {
                version = .v1
            } else {
                throw NaiveFlowError.routing(.payloadCorrupted(.badMagic))
            }
            cursor += magic.count
            return version
        }

        private mutating func u8() throws(NaiveFlowError) -> UInt8 {
            guard cursor < count else { throw NaiveFlowError.routing(.payloadCorrupted(.truncated)) }
            defer { cursor += 1 }
            return bytes[cursor]
        }

        private mutating func u16() throws(NaiveFlowError) -> UInt16 {
            guard cursor + 2 <= count else { throw NaiveFlowError.routing(.payloadCorrupted(.truncated)) }
            defer { cursor += 2 }
            return UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8)
        }

        private mutating func u32() throws(NaiveFlowError) -> UInt32 {
            guard cursor + 4 <= count else { throw NaiveFlowError.routing(.payloadCorrupted(.truncated)) }
            defer { cursor += 4 }
            return UInt32(bytes[cursor]) | (UInt32(bytes[cursor + 1]) << 8) | (UInt32(bytes[cursor + 2]) << 16) | (UInt32(bytes[cursor + 3]) << 24)
        }

        private mutating func advance(_ n: Int) throws(NaiveFlowError) {
            guard n >= 0, cursor + n <= count else { throw NaiveFlowError.routing(.payloadCorrupted(.truncated)) }
            cursor += n
        }

        private mutating func readUUID() throws(NaiveFlowError) -> UUID {
            guard cursor + 16 <= count else { throw NaiveFlowError.routing(.payloadCorrupted(.truncated)) }
            let uuid = UUID(uuid: (
                bytes[cursor], bytes[cursor + 1], bytes[cursor + 2], bytes[cursor + 3],
                bytes[cursor + 4], bytes[cursor + 5], bytes[cursor + 6], bytes[cursor + 7],
                bytes[cursor + 8], bytes[cursor + 9], bytes[cursor + 10], bytes[cursor + 11],
                bytes[cursor + 12], bytes[cursor + 13], bytes[cursor + 14], bytes[cursor + 15])
            )
            cursor += 16
            return uuid
        }
    }

    func installBaseline(_ data: Data?) {
        _ = replaceRoutingState(with: Self.makeRoutingState(data: data))
    }

    func installNative(_ bundle: RuntimeConfigurationBundle) {
        var state = RoutingState()
        state.ordered = OrderedRouteMatcher(rules: bundle.rules ?? [], finalAction: bundle.finalAction,
            geoIP: bundle.geo, geoSite: bundle.geo)
        state.configurationMap = Dictionary(uniqueKeysWithValues: bundle.nodes.map { ($0.id, $0) })
        state.policyGroups = Dictionary(uniqueKeysWithValues: bundle.policyGroups.map { ($0.id, $0) })
        _ = replaceRoutingState(with: state)
    }

    var usesNativeRules: Bool { routingState.withLock { $0.ordered != nil } }

    func nativeDecision(_ query: RouteQuery, allowResolution: Bool = true,
                        deferOnHostUnknown: Bool = true,
                        deferOnMissingMetadata: Bool = true) -> OrderedRouteMatcher.Evaluation? {
        routingState.withLock {
            $0.ordered?.evaluate(query, allowAddressResolution: allowResolution,
                                 deferOnHostUnknown: deferOnHostUnknown,
                                 deferOnMissingMetadata: deferOnMissingMetadata)
        }
    }

    static func nativeMatch(_ result: OrderedRouteMatcher.Result) -> Match {
        let target: RouteTarget
        switch result.action {
        case .direct: target = .direct
        case .reject: target = .reject
        case .defaultProxy: target = .defaultProxy
        case .proxy(let id): target = .proxy(id)
        }
        return Match(action: target, ruleSetName: result.ruleLine.map { "Text line \($0)" } ?? "FINAL")
    }

    // MARK: - Matching

    var hasRules: Bool {
        routingState.withLock { $0.ordered != nil || $0.matcher.hasRules }
    }

    func matchDomain(_ domain: String) -> Match? {
        matchDomainVersioned(domain).match
    }

    func matchDomainVersioned(_ domain: String) -> (match: Match?, version: UInt64) {
        guard !domain.isEmpty else { return (nil, currentRulesVersion) }
        var lowered = RouteMatching.asciiLowercasedIfNeeded(domain)
        return routingState.withLock { state in
            if let ordered = state.ordered {
                let match: Match?
                if case .matched(let result) = ordered.evaluate(RouteQuery(host: domain), allowFinal: false) {
                    match = Self.nativeMatch(result)
                } else { match = nil }
                return (match, state.version)
            }
            let payload = lowered.withUTF8 { state.matcher.matchDomain(bytes: $0) }
            return (state.match(resolving: payload), state.version)
        }
    }

    func matchIP(_ ip: String) -> Match? {
        routingState.withLock { state in
            if let ordered = state.ordered {
                if case .matched(let result) = ordered.evaluate(RouteQuery(ip: ip)) { return Self.nativeMatch(result) }
                return nil
            }
            let payload = state.matcher.matchIP(ip)
            return state.match(resolving: payload)
        }
    }

    func resolveConfiguration(action: RouteTarget) -> ProxyConfiguration? {
        switch action {
        case .default, .defaultProxy, .direct, .reject:
            return nil
        case .proxy(let id):
            return routingState.withLock { state in
                if let configuration = state.configurationMap[id] { return configuration }
                // The id names a policy group: apply its selection strategy to
                // pick a member node, using the latest probe results (absent =
                // unknown/unreachable).
                guard let group = state.policyGroups[id] else { return nil }
                let index = state.roundRobin[id] ?? 0
                state.roundRobin[id] = index &+ 1
                guard let memberID = ProxyGroupSelector.select(
                    group: group, latencies: state.latencies, roundRobinIndex: index
                ) else { return nil }
                return state.configurationMap[memberID]
            }
        }
    }

    /// Replaces the probe-result table the group selector consults. Absent ids
    /// are treated as unknown/unreachable.
    func updateLatencies(_ latencies: [UUID: Int]) {
        routingState.withLock { $0.latencies = latencies }
    }
}
