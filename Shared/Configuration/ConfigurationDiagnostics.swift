//
//  ConfigurationDiagnostics.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// A single problem found while parsing or validating a text configuration.
///
/// Diagnostics always carry the original 1-based line number when the problem
/// can be attributed to one line, so the editor can jump to it. Messages are
/// intentionally plain strings: they describe parse/validation state rather
/// than user interface copy, and the editor presentation is localized later.
nonisolated struct ConfigurationDiagnostic: Identifiable, Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        /// Informational note, for example a supported-but-ignored directive.
        case info = 0
        /// The document still compiles, but something was dropped or defaulted.
        case warning = 1
        /// The document cannot be activated as written.
        case error = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .info: return "Info"
            case .warning: return "Warning"
            case .error: return "Error"
            }
        }
    }

    /// Stable machine-readable classification. The raw value is used for
    /// filtering and for tests; it is not shown to users.
    enum Code: String, Sendable, CaseIterable {
        case duplicateSection
        case emptyKey
        case emptySection
        case emptyValue
        case duplicateName
        case duplicateFinal
        case finalNotLast
        case groupCycle
        case invalidSectionHeader
        case invalidValue
        case malformedRule
        case ruleValueTooLong
        case missingEquals
        case missingRulePolicy
        case missingValue
        case unknownDirective
        case unknownGeneralKey
        case notApplied
        case unknownPolicy
        case unknownProxyType
        case unknownSection
        case unsupportedRuleType
        case unsupportedRuleOption
        case unresolvedPolicy
        case reservedPolicyName
        case unusedProxy
    }

    let severity: Severity
    let code: Code
    let line: Int?
    let section: String?
    let message: String

    var id: String {
        "\(code.rawValue)@\(line.map(String.init) ?? "-")#\(message)"
    }

    init(
        severity: Severity,
        code: Code,
        line: Int? = nil,
        section: String? = nil,
        message: String
    ) {
        self.severity = severity
        self.code = code
        self.line = line
        self.section = section
        self.message = message
    }

    /// Human-readable single-line description used by logs and the editor list.
    var localizedDescription: String {
        var prefix = "[\(severity.title)]"
        if let line { prefix += " line \(line)" }
        if let section { prefix += " [\(section)]" }
        return "\(prefix) \(message)"
    }
}

extension ConfigurationDiagnostic: Comparable {
    /// Sorts by line first, then by severity (errors before warnings), so the
    /// editor can show the topmost, most serious problem first.
    static func < (lhs: ConfigurationDiagnostic, rhs: ConfigurationDiagnostic) -> Bool {
        let leftLine = lhs.line ?? Int.max
        let rightLine = rhs.line ?? Int.max
        if leftLine != rightLine { return leftLine < rightLine }
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        return lhs.code.rawValue < rhs.code.rawValue
    }
}

nonisolated extension Array where Element == ConfigurationDiagnostic {
    var hasErrors: Bool { contains { $0.severity == .error } }

    var errors: [ConfigurationDiagnostic] { filter { $0.severity == .error } }

    var sorted: [ConfigurationDiagnostic] { sorted() }
}

// MARK: - Ordered Parameters

/// Small ordered key/value collection used by every `key = value`-style
/// section. Keeps the original declaration order so exports are stable and
/// diagnostics can report the offending entry position.
nonisolated struct OrderedParameters: Equatable, Sendable {
    private(set) var keys: [String] = []
    private var storage: [String: String] = [:]

    init() {}

    init(_ pairs: [(String, String)]) {
        for pair in pairs {
            set(pair.0, pair.1)
        }
    }

    var isEmpty: Bool { keys.isEmpty }

    var count: Int { keys.count }

    var pairs: [(key: String, value: String)] {
        keys.map { ($0, storage[$0] ?? "") }
    }

    subscript(key: String) -> String? {
        get { storage[key.lowercased()] }
        set {
            guard let newValue else { return }
            set(key, newValue)
        }
    }

    mutating func set(_ key: String, _ value: String) {
        let normalized = key.lowercased()
        if storage[normalized] == nil {
            keys.append(normalized)
        }
        storage[normalized] = value
    }

    mutating func remove(_ key: String) {
        let normalized = key.lowercased()
        storage.removeValue(forKey: normalized)
        keys.removeAll { $0 == normalized }
    }

    func contains(_ key: String) -> Bool {
        storage[key.lowercased()] != nil
    }

    /// Returns the value parsed as a boolean using NaiveFlow boolean spellings.
    func bool(_ key: String) -> Bool? {
        guard let raw = storage[key.lowercased()]?.trimmingCharacters(in: .whitespaces) else { return nil }
        switch raw.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    func int(_ key: String) -> Int? {
        guard let raw = storage[key.lowercased()] else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    /// Splits a comma-separated value, trimming blanks and dropping empties.
    func list(_ key: String) -> [String]? {
        guard let raw = storage[key.lowercased()] else { return nil }
        return raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Codable

extension ConfigurationDiagnostic: Codable {
    private enum CodingKeys: String, CodingKey {
        case severity, code, line, section, message
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSeverity = try container.decode(Int.self, forKey: .severity)
        severity = Severity(rawValue: rawSeverity) ?? .error
        let rawCode = try container.decode(String.self, forKey: .code)
        code = Code(rawValue: rawCode) ?? .invalidValue
        line = try container.decodeIfPresent(Int.self, forKey: .line)
        section = try container.decodeIfPresent(String.self, forKey: .section)
        message = try container.decode(String.self, forKey: .message)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(severity.rawValue, forKey: .severity)
        try container.encode(code.rawValue, forKey: .code)
        try container.encodeIfPresent(line, forKey: .line)
        try container.encodeIfPresent(section, forKey: .section)
        try container.encode(message, forKey: .message)
    }
}

