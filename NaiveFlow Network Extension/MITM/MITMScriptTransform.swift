//
//  MITMScriptTransform.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/9/26.
//

import Foundation
import Synchronization
import JavaScriptCore
import os

nonisolated private let logger = NaiveFlowLogger(category: "MITMScriptTransform")

nonisolated private let nativeBodyEditReservedBytes = Atomic<Int>(0)

nonisolated enum MITMScriptTransform {
    private static let bodyJSONMemoryFactor = 5
    private static let bodyReplaceMemoryFactor = 12
    private static let nativeBodyEditHeadroom = 8 * 1024 * 1024
    private static let maxNativeBodyEditReservedBytes = 48 * 1024 * 1024

    static func rulesDidReload(scopedRules: [(scope: UUID, rules: [CompiledMITMRule])]) {
        let hasScriptRule = scopedRules.contains { entry in
            entry.rules.contains { rule in
                switch rule.operation {
                case .script: return true
                case .rewrite, .headerAdd, .headerDelete, .headerReplace, .bodyReplace, .bodyJSON: return false
                }
            }
        }
        guard hasScriptRule else { return }
        MITMScriptEngine.warmVirtualMachine()
    }

    enum Outcome {
        case message(HTTPMessage)
        case synthesizedResponse(MITMScriptEngine.SynthesizedResponse)
    }

    static func hasScriptRule(in rules: [CompiledMITMRule], verdicts: MITMGateVerdictTable) -> Bool {
        for (index, rule) in rules.enumerated() {
            if case .script = rule.operation, verdicts.matches(at: index) { return true }
        }
        return false
    }

    static func hasBodyReplaceRule(in rules: [CompiledMITMRule], verdicts: MITMGateVerdictTable) -> Bool {
        for (index, rule) in rules.enumerated() {
            if case .bodyReplace = rule.operation, verdicts.matches(at: index) { return true }
        }
        return false
    }

    static func hasBufferedBodyRule(in rules: [CompiledMITMRule], verdicts: MITMGateVerdictTable) -> Bool {
        hasScriptRule(in: rules, verdicts: verdicts)
            || hasBodyReplaceRule(in: rules, verdicts: verdicts)
            || hasBodyJSONRule(in: rules, verdicts: verdicts)
    }

    static func hasBodyAccessingRule(in rules: [CompiledMITMRule], verdicts: MITMGateVerdictTable) -> Bool {
        hasBufferedBodyRule(in: rules, verdicts: verdicts)
    }

    static func isStreamingMediaType(_ contentType: String?) -> Bool {
        guard let raw = contentType else { return false }
        let mediaType = raw
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? ""
        switch mediaType {
        case "text/event-stream",
             "multipart/x-mixed-replace",
             "application/x-ndjson",
             "application/jsonl",
             "application/stream+json",
             "application/json-seq":
            return true
        default:
            return false
        }
    }

    private static func applyNativeBodyEdits(
        _ message: HTTPMessage,
        operations: [CompiledMITMOperation]
    ) async -> HTTPMessage {
        var message = message
        var jsonOperations: [MITMJSONPatch.CompiledOperation] = []
        var replaceOperations: [MITMBodyReplace.CompiledOperation] = []
        for operation in operations {
            if case .bodyJSON(let jsonOperation) = operation { jsonOperations.append(jsonOperation) }
            if case .bodyReplace(let replaceOperation) = operation { replaceOperations.append(replaceOperation) }
        }
        if !jsonOperations.isEmpty {
            let cost = message.body.count * bodyJSONMemoryFactor
            if reserveNativeBodyEdit(cost) {
                message.body = MITMJSONPatch.applyAll(jsonOperations, to: message.body)
                releaseNativeBodyEdit(cost)
            } else {
                logger.warning("[MITM] bodyJSON: Memory budget exceeded")
            }
        }
        if !replaceOperations.isEmpty {
            let cost = message.body.count * bodyReplaceMemoryFactor
            if reserveNativeBodyEdit(cost) {
                message.body = await MITMBodyReplace.applyAll(replaceOperations, to: message.body)
                releaseNativeBodyEdit(cost)
            } else {
                logger.warning("[MITM] bodyReplace: Memory budget exceeded")
            }
        }
        return message
    }

    private static func reserveNativeBodyEdit(_ bytes: Int) -> Bool {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let available = os_proc_available_memory()
        #else
        // os_proc_available_memory is unavailable on macOS. Keep the bounded
        // reservation policy; the process-level limit is enforced by the
        // extension host and the fixed cap remains the conservative fallback.
        let available = 0
        #endif
        let limit = available > 0
            ? min(available - nativeBodyEditHeadroom, maxNativeBodyEditReservedBytes)
            : maxNativeBodyEditReservedBytes
        guard TransientMemoryBudget.mitm.reserve(bytes) else { return false }
        var reserved = nativeBodyEditReservedBytes.load(ordering: .relaxed)
        while reserved + bytes <= limit {
            let (exchanged, current) = nativeBodyEditReservedBytes.compareExchange(
                expected: reserved,
                desired: reserved + bytes,
                ordering: .relaxed
            )
            if exchanged { return true }
            reserved = current
        }
        TransientMemoryBudget.mitm.release(bytes)
        return false
    }

    private static func releaseNativeBodyEdit(_ bytes: Int) {
        nativeBodyEditReservedBytes.wrappingSubtract(bytes, ordering: .relaxed)
        TransientMemoryBudget.mitm.release(bytes)
    }

    static func apply(
        _ message: HTTPMessage,
        rules: [CompiledMITMRule]
    ) async -> Outcome {
        if Task.isCancelled { return .message(message) }
        let bodyRules = rules.filter { rule in
            switch rule.operation {
            case .script, .bodyReplace, .bodyJSON: return true
            case .rewrite, .headerAdd, .headerDelete, .headerReplace: return false
            }
        }
        let verdicts = await MITMGateVerdictTable.resolve(rules: bodyRules, url: message.url)
        let matched = bodyRules.indices.filter { verdicts.matches(at: $0) }.map { bodyRules[$0].operation }
        let edited = await applyNativeBodyEdits(message, operations: matched)
        if Task.isCancelled { return .message(edited) }
        var selectedScript: (source: String, preamble: String, dialect: MITMScriptDialect)?
        for operation in matched.reversed() {
            if case .script(let source, let preamble, let dialect) = operation {
                selectedScript = (source, preamble, dialect)
                break
            }
        }
        guard let script = selectedScript else { return .message(edited) }
        // Source validation happens once when the immutable policy is compiled.
        let outcome = await MITMScriptEngine.shared.applyAsync(edited, source: script.source, preamble: script.preamble, dialect: script.dialect)
        switch outcome {
        case .modified(let updated):  return .message(updated)
        case .done(let updated):      return .message(updated)
        case .respond(let response):  return .synthesizedResponse(response)
        }
    }
}
