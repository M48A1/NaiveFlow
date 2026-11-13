//
//  MITMRewritePolicy.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/4/26.
//

import Foundation
import Synchronization

nonisolated private let logger = NaiveFlowLogger(category: "MITMRewritePolicy")

nonisolated struct CompiledMITMRule {
    let phase: MITMPhase
    let gate: MITMGateRegex
    let operation: CompiledMITMOperation
}

extension CompiledMITMRule {
    static let maxGateURLLength = 8 * 1024

    static func gateURL(_ url: String?) -> String? {
        guard let url, url.utf16.count <= maxGateURLLength else { return nil }
        return lowercasingHost(url)
    }

    private static func lowercasingHost(_ url: String) -> String {
        guard let schemeSeparator = url.range(of: "://") else { return url }
        let authorityStart = schemeSeparator.upperBound
        let authorityEnd = url[authorityStart...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? url.endIndex
        var authority = url[authorityStart..<authorityEnd].lowercased()
        if authority.hasSuffix(".") { authority.removeLast() }
        return url[..<authorityStart].lowercased() + authority + String(url[authorityEnd...])
    }
}

extension CompiledMITMRule {
    func resolvedRewriteAction(verdicts: MITMGateVerdictTable, at index: Int) -> ResolvedRewriteAction? {
        guard case .rewrite(let action) = operation else { return nil }
        switch action {
        case .transparent(.resolved(let replacement)):
            return verdicts.matches(at: index) ? .transparent(replacement) : nil
        case .transparent(.templated(let template)):
            guard let captures = verdicts.captures(at: index),
                  let replacement = MITMRewritePolicy.resolveTransparentTemplate(template, captures: captures)
            else { return nil }
            return .transparent(replacement)
        case .redirect302(.location(let location)):
            return verdicts.matches(at: index) ? .redirect302(location: location) : nil
        case .redirect302(.templated(let template)):
            guard let captures = verdicts.captures(at: index),
                  let location = MITMRewritePolicy.resolveRedirectTemplate(template, captures: captures)
            else { return nil }
            return .redirect302(location: location)
        case .reject200Text(let content):
            return verdicts.matches(at: index) ? .reject200Text(content: content) : nil
        case .reject200Gif:
            return verdicts.matches(at: index) ? .reject200Gif : nil
        case .reject200Data(let base64):
            return verdicts.matches(at: index) ? .reject200Data(base64: base64) : nil
        }
    }
}

nonisolated struct MITMGateVerdictTable: Sendable {
    let url: String?
    private let matched: [Bool]
    private let captureGroups: [[String?]?]

    func matches(at index: Int) -> Bool { matched[index] }
    func captures(at index: Int) -> [String?]? { captureGroups[index] }

    static let empty = MITMGateVerdictTable(url: nil, matched: [], captureGroups: [])

    private static func needsCaptures(_ rule: CompiledMITMRule) -> Bool {
        guard case .rewrite(let action) = rule.operation else { return false }
        switch action {
        case .transparent(.templated), .redirect302(.templated):
            return true
        case .transparent(.resolved), .redirect302(.location),
             .reject200Text, .reject200Gif, .reject200Data:
            return false
        }
    }

    static func peek(rules: [CompiledMITMRule], url: String?) -> MITMGateVerdictTable? {
        guard let gateURL = CompiledMITMRule.gateURL(url) else { return unmatched(rules.count, url: url) }
        var verdicts: [MITMGateRegex.Verdict] = []
        verdicts.reserveCapacity(rules.count)
        for rule in rules {
            guard let verdict = rule.gate.peek(gateURL, wantsCaptures: needsCaptures(rule)) else { return nil }
            verdicts.append(verdict)
        }
        return table(rules: rules, url: url, verdicts: verdicts)
    }

    static func resolve(rules: [CompiledMITMRule], url: String?) async -> MITMGateVerdictTable {
        guard let gateURL = CompiledMITMRule.gateURL(url) else { return unmatched(rules.count, url: url) }
        let verdicts = await MITMGateRegex.resolve(
            rules.map { MITMGateRegex.Request(gate: $0.gate, wantsCaptures: needsCaptures($0)) },
            in: gateURL
        )
        return table(rules: rules, url: url, verdicts: verdicts)
    }

    private static func unmatched(_ count: Int, url: String?) -> MITMGateVerdictTable {
        MITMGateVerdictTable(
            url: url,
            matched: [Bool](repeating: false, count: count),
            captureGroups: [[String?]?](repeating: nil, count: count)
        )
    }

    private static func table(rules: [CompiledMITMRule], url: String?, verdicts: [MITMGateRegex.Verdict]) -> MITMGateVerdictTable {
        var matched = [Bool]()
        matched.reserveCapacity(rules.count)
        var captureGroups = [[String?]?](repeating: nil, count: rules.count)
        for (index, verdict) in verdicts.enumerated() {
            guard case .match(let captures) = verdict else {
                matched.append(false)
                continue
            }
            matched.append(true)
            if needsCaptures(rules[index]) { captureGroups[index] = captures }
        }
        return MITMGateVerdictTable(url: url, matched: matched, captureGroups: captureGroups)
    }
}

nonisolated struct ReplacementURL: Equatable {
    let host: String
    let port: UInt16?
    let requestTarget: String

    var authority: String {
        let bracketedHost = host.contains(":") ? "[\(host)]" : host
        if let port { return "\(bracketedHost):\(port)" }
        return bracketedHost
    }
}

nonisolated enum TransparentTarget {
    case resolved(ReplacementURL)
    case templated(MITMCaptureTemplate)
}

nonisolated enum RedirectTarget {
    case location(String)
    case templated(MITMCaptureTemplate)
}

nonisolated enum CompiledRewriteAction {
    case transparent(TransparentTarget)
    case redirect302(RedirectTarget)
    case reject200Text(content: String)
    case reject200Gif
    case reject200Data(base64: String)
}

nonisolated enum ResolvedRewriteAction {
    case transparent(ReplacementURL)
    case redirect302(location: String)
    case reject200Text(content: String)
    case reject200Gif
    case reject200Data(base64: String)
}

nonisolated enum CompiledMITMOperation {
    case rewrite(CompiledRewriteAction)
    case headerAdd(name: String, value: String)
    case headerDelete(nameLower: String)
    case headerReplace(name: String, value: String)
    case bodyReplace(MITMBodyReplace.CompiledOperation)
    case bodyJSON(MITMJSONPatch.CompiledOperation)
    case script(source: String, preamble: String, dialect: MITMScriptDialect, headerOnly: Bool)
}

nonisolated struct CompiledMITMRuleSet {
    let id: UUID
    let domainSuffix: String
    let rules: [CompiledMITMRule]
}

nonisolated final class MITMRewritePolicy: Sendable {
    private struct PolicyState {
        var trie = FlatLabelTrie<Int16>()
        var compiledSets: [CompiledMITMRuleSet] = []
        var setCount: Int = 0
        var gateCache: [String: MITMGateRegex] = [:]
    }

    private let state = Mutex(PolicyState())

    var hasRules: Bool { state.withLock { $0.setCount > 0 } }

    func reset() {
        state.withLock { $0 = PolicyState() }
    }

    static func validate(ruleSets: [MITMRuleSet]) throws {
        let compiler = MITMRewritePolicy()
        var scriptSources: [String: String] = [:]
        for set in ruleSets {
            for rule in set.rules {
                guard MITMGateRegex(pattern: rule.urlPattern) != nil,
                      compiler.compile(rule.operation, ruleSet: set.name, scriptSources: &scriptSources) != nil else {
                    throw RuntimeConfigurationFailure.rejected("An MITM operation cannot be compiled.")
                }
            }
        }
    }

    func load(ruleSets: [MITMRuleSet]) {
        var scopedRules: [(scope: UUID, rules: [CompiledMITMRule])] = []
        let previousGates = state.withLock { $0.gateCache }
        var newState = PolicyState()
        let trie = FlatLabelTrieBuilder<Int16>()
        var newGates: [String: MITMGateRegex] = [:]
        for set in ruleSets {
            guard set.enabled else { continue }
            if let compiled = insert(set, into: &newState, trie: trie, previousGates: previousGates, newGates: &newGates) {
                scopedRules.append((scope: set.id, rules: compiled))
            }
        }
        newState.gateCache = newGates
        newState.trie = trie.freeze()
        state.withLock { $0 = newState }
        let activeIDs = Set(ruleSets.map { $0.id })
        MITMScriptEngine.setRuleSetNames(Dictionary(ruleSets.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
        MITMScriptEngine.purgeRuns(activeIDs: activeIDs)
        MITMScriptStore.shared.purgeExcept(activeIDs: activeIDs)
        MITMParameterStore.shared.replaceAll(ruleSets.map { (scope: $0.id, values: $0.parameterValues) })
        MITMScriptTransform.rulesDidReload(scopedRules: scopedRules)
    }

    private func insert(
        _ set: MITMRuleSet,
        into state: inout PolicyState,
        trie: FlatLabelTrieBuilder<Int16>,
        previousGates: [String: MITMGateRegex],
        newGates: inout [String: MITMGateRegex]
    ) -> [CompiledMITMRule]? {
        let suffixes = set.domainSuffixes
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet.whitespaces) }
            .filter { !$0.isEmpty }
        guard !suffixes.isEmpty else { return nil }

        var scriptSources: [String: String] = [:]
        let compiledRules = set.rules.compactMap { rule -> CompiledMITMRule? in
            let gate: MITMGateRegex
            if let cached = newGates[rule.urlPattern] ?? previousGates[rule.urlPattern] {
                gate = cached
            } else {
                guard let compiled = MITMGateRegex(pattern: rule.urlPattern) else {
                    logger.warning("[MITM] \(set.name): Invalid URL pattern: \(rule.urlPattern)")
                    return nil
                }
                gate = compiled
            }
            newGates[rule.urlPattern] = gate
            guard let operation = compile(rule.operation, ruleSet: set.name, scriptSources: &scriptSources) else { return nil }
            return CompiledMITMRule(phase: rule.phase, gate: gate, operation: operation)
        }

        for suffix in suffixes {
            guard state.compiledSets.count < Int(Int16.max) else {
                logger.warning("[MITM] Domain suffix table full")
                break
            }
            let payload = CompiledMITMRuleSet(
                id: set.id,
                domainSuffix: suffix,
                rules: compiledRules
            )
            let payloadID = Int16(state.compiledSets.count)
            state.compiledSets.append(payload)
            if trie.insert(suffix: suffix, payload: payloadID) {
                state.setCount += 1
            } else {
                logger.warning("[MITM] \(set.name): Duplicate domain suffix: \(suffix)")
            }
        }
        return compiledRules
    }

    func matches(_ host: String) -> Bool {
        set(for: host) != nil
    }

    func set(for host: String) -> CompiledMITMRuleSet? {
        guard !host.isEmpty else { return nil }
        var lowered = host.lowercased()
        return state.withLock { state -> CompiledMITMRuleSet? in
            guard state.setCount > 0 else { return nil }
            guard let id = lowered.withUTF8({ state.trie.lookup($0) }) else { return nil }
            let index = Int(id)
            guard index >= 0, index < state.compiledSets.count else { return nil }
            return state.compiledSets[index]
        }
    }

    func rules(for host: String, phase: MITMPhase) -> [CompiledMITMRule] {
        guard let set = set(for: host) else { return [] }
        return set.rules.filter { $0.phase == phase }
    }

    // MARK: - Compilation

    private func compile(_ operation: MITMOperation, ruleSet: String, scriptSources: inout [String: String]) -> CompiledMITMOperation? {
        guard operation.isSupportedMITMOperation else { return nil }
        switch operation {
        case .rewrite(let action):
            guard let compiled = Self.compileRewrite(action, ruleSet: ruleSet) else { return nil }
            return .rewrite(compiled)
        case .headerAdd(let name, let value):
            guard HTTPHeader.isValidName(name) else {
                logger.warning("[MITM] \(ruleSet): headerAdd: Invalid header name: \(name)")
                return nil
            }
            guard !Self.isFramingHeader(name) else {
                logger.warning("[MITM] \(ruleSet): headerAdd: Framing header: \(name)")
                return nil
            }
            guard HTTPHeader.isValidValue(value) else {
                logger.warning("[MITM] \(ruleSet): headerAdd: Invalid header value: \(name)")
                return nil
            }
            return .headerAdd(name: name, value: value)
        case .headerDelete(let name):
            guard HTTPHeader.isValidName(name) else {
                logger.warning("[MITM] \(ruleSet): headerDelete: Invalid header name: \(name)")
                return nil
            }
            return .headerDelete(nameLower: name.lowercased())
        case .headerReplace(let name, let value):
            guard HTTPHeader.isValidName(name) else {
                logger.warning("[MITM] \(ruleSet): headerReplace: Invalid header name: \(name)")
                return nil
            }
            guard !Self.isFramingHeader(name) else {
                logger.warning("[MITM] \(ruleSet): headerReplace: Framing header: \(name)")
                return nil
            }
            guard HTTPHeader.isValidValue(value) else {
                logger.warning("[MITM] \(ruleSet): headerReplace: Invalid header value: \(name)")
                return nil
            }
            return .headerReplace(name: name, value: value)
        case .script(let scriptBase64, let dialect):
            guard let source = decodeScript(scriptBase64, ruleSet: ruleSet, kind: "script") else {
                return nil
            }
            let preamble: String
            let body: String
            if let marker = source.range(of: ForeignScriptContext.sourceMarker) {
                preamble = String(source[..<marker.lowerBound])
                body = String(source[marker.upperBound...])
            } else { preamble = ""; body = source }
            let sharedBody = scriptSources[body] ?? body
            scriptSources[body] = sharedBody
            let headerOnly = preamble.split(separator: "\n").contains { line in
                line == ForeignScriptContext.headerOnlyMarker
                    || line == "delete $request.body; delete $request.bodyBytes;"
                    || line == "delete $response.body; delete $response.bodyBytes;"
            }
            return .script(source: sharedBody, preamble: preamble, dialect: dialect, headerOnly: headerOnly)
        case .bodyReplace(let search, let replacement):
            guard let compiled = MITMBodyReplace.compile(search: search, replacement: replacement) else {
                logger.warning("[MITM] \(ruleSet): bodyReplace: Invalid regex: \(search)")
                return nil
            }
            return .bodyReplace(compiled)
        case .bodyJSON(let operation):
            guard let compiled = MITMJSONPatch.compile(operation) else {
                logger.warning("[MITM] \(ruleSet): bodyJSON: Invalid path: \(operation)")
                return nil
            }
            return .bodyJSON(compiled)
        }
    }

    private func decodeScript(_ scriptBase64: String, ruleSet: String, kind: String) -> String? {
        guard let raw = Data(base64Encoded: scriptBase64) else {
            logger.warning("[MITM] \(ruleSet): \(kind): Invalid base64")
            return nil
        }
        guard let source = String(data: raw, encoding: .utf8) else {
            logger.warning("[MITM] \(ruleSet): \(kind): Invalid UTF-8")
            return nil
        }
        do { try RuntimeJavaScript.validate(source) }
        catch {
            logger.warning("[MITM] \(ruleSet): \(kind): Unsupported or invalid script")
            return nil
        }
        return source
    }

    // MARK: - Static-rule validation

    private static func isFramingHeader(_ name: String) -> Bool {
        switch name.lowercased() {
        case "content-length", "transfer-encoding",
             "connection", "keep-alive", "proxy-connection", "upgrade", "te", "trailer":
            return true
        default:
            return false
        }
    }

    private static func isValidRequestTargetReplacement(_ replacement: String) -> Bool {
        for byte in replacement.utf8 {
            if byte <= 0x20 || byte == 0x7F {
                return false
            }
        }
        return true
    }

    // MARK: - Rewrite compilation

    private static func compileRewrite(_ action: MITMRewriteAction, ruleSet: String) -> CompiledRewriteAction? {
        switch action {
        case .transparent(let url):
            let template = MITMCaptureTemplate(url)
            if template.referencesCaptures {
                return .transparent(.templated(template))
            }
            guard let parsed = parseReplacementURL(url) else {
                logger.warning("[MITM] \(ruleSet): rewrite: Invalid URL: \(url)")
                return nil
            }
            guard isValidRequestTargetReplacement(parsed.requestTarget) else {
                logger.warning("[MITM] \(ruleSet): rewrite: Invalid request target: \(url)")
                return nil
            }
            return .transparent(.resolved(parsed))
        case .redirect302(let url):
            let template = MITMCaptureTemplate(url)
            if template.referencesCaptures {
                return .redirect302(.templated(template))
            }
            let trimmed = url.trimmingCharacters(in: .whitespaces)
            guard parseReplacementURL(trimmed) != nil, HTTPHeader.isValidValue(trimmed) else {
                logger.warning("[MITM] \(ruleSet): rewrite 302: Invalid URL: \(url)")
                return nil
            }
            return .redirect302(.location(trimmed))
        case .reject200Text(let content):
            return .reject200Text(content: content)
        case .reject200Gif:
            return .reject200Gif
        case .reject200Data(let base64):
            if !base64.isEmpty, Data(base64Encoded: base64) == nil {
                logger.warning("[MITM] \(ruleSet): rewrite reject-data: Invalid base64")
                return nil
            }
            return .reject200Data(base64: base64)
        }
    }

    static func parseReplacementURL(_ raw: String) -> ReplacementURL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let rawHost = components.host, !rawHost.isEmpty else { return nil }
        var host = rawHost
        if host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        let port: UInt16?
        if let rawPort = components.port {
            guard let valid = UInt16(exactly: rawPort) else { return nil }
            port = valid
        } else {
            port = nil
        }
        var target = components.percentEncodedPath
        if target.isEmpty { target = "/" }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            target += "?\(query)"
        }
        return ReplacementURL(host: host, port: port, requestTarget: target)
    }

    // MARK: - Per-request template resolution

    static func resolveTransparentTemplate(_ template: MITMCaptureTemplate, captures: [String?]) -> ReplacementURL? {
        let url = template.expand(captures: captures)
        guard let parsed = parseReplacementURL(url),
              isValidRequestTargetReplacement(parsed.requestTarget) else { return nil }
        return parsed
    }

    static func resolveRedirectTemplate(_ template: MITMCaptureTemplate, captures: [String?]) -> String? {
        let location = template.expand(captures: captures).trimmingCharacters(in: .whitespaces)
        guard parseReplacementURL(location) != nil, HTTPHeader.isValidValue(location) else { return nil }
        return location
    }
}
