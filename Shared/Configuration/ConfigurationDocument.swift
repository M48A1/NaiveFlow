//
//  ConfigurationDocument.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Line-preserving representation of a NaiveFlow sectioned text configuration.
///
/// The document keeps every original line together with its 1-based number,
/// the comment split off each line, and the ordered section list. Parsing is
/// lossless: `text` reproduces the input (with normalized line endings) so the
/// editor can round-trip a file it already showed, and the compiler can report
/// problems against real line numbers.
nonisolated struct ConfigurationDocument: Equatable, Sendable {

    /// Sections this build understands. Anything else is preserved verbatim and
    /// reported as `unknownSection` instead of being silently dropped.
    enum SectionKind: String, CaseIterable, Sendable {
        case general
        case dns
        case geoIP, geoSite
        case proxy
        case proxyGroup
        case rule
        case host
        case mitm
        case mitmSet
        case script
        case urlRewrite
        case headerRewrite
        case bodyRewrite
        case mapLocal
        case rewrite
        case panel
        case ssidSetting
        case misc
        case chain
        case subscription
        case module

        /// Canonical header text, also used when exporting a document.
        var displayName: String {
            switch self {
            case .general: return "General"
            case .dns: return "DNS"
            case .geoIP: return "GeoIP"
            case .geoSite: return "GeoSite"
            case .proxy: return "Proxy"
            case .proxyGroup: return "Proxy Group"
            case .rule: return "Rule"
            case .host: return "Host"
            case .mitm: return "MITM"
            case .mitmSet: return "MITM Set"
            case .script: return "Script"
            case .urlRewrite: return "URL Rewrite"
            case .headerRewrite: return "Header Rewrite"
            case .bodyRewrite: return "Body Rewrite"
            case .mapLocal: return "Map Local"
            case .rewrite: return "Rewrite"
            case .panel: return "Panel"
            case .ssidSetting: return "SSID Setting"
            case .misc: return "Misc"
            case .chain: return "Chain"
            case .subscription: return "Subscription"
            case .module: return "Module"
            }
        }

        /// Sections whose lines are positional directives (`DOMAIN-SUFFIX,a,DIRECT`)
        /// rather than `key = value` pairs.
        var usesBareDirectives: Bool {
            switch self {
            case .rule, .urlRewrite, .headerRewrite, .bodyRewrite, .mapLocal, .rewrite:
                return true
            case .dns, .geoIP, .geoSite, .mitmSet, .general, .proxy, .proxyGroup, .host, .mitm, .script, .panel, .ssidSetting, .misc, .chain, .subscription, .module:
                return false
            }
        }

        /// Matches a header spelling, ignoring case, spaces, and dashes/underscores.
        static func matching(_ raw: String) -> SectionKind? {
            let normalized = raw
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
            switch normalized {
            case "general": return .general
            case "dns": return .dns
            case "geoip": return .geoIP
            case "geosite": return .geoSite
            case "proxy", "proxies": return .proxy
            case "proxygroup", "proxygroups", "policygroup": return .proxyGroup
            case "rule", "rules": return .rule
            case "host", "hosts": return .host
            case "mitm": return .mitm
            case "mitmset": return .mitmSet
            case "script", "scripts": return .script
            case "urlrewrite": return .urlRewrite
            case "headerrewrite": return .headerRewrite
            case "bodyrewrite": return .bodyRewrite
            case "maplocal": return .mapLocal
            case "rewrite": return .rewrite
            case "panel", "panels": return .panel
            case "ssidsetting": return .ssidSetting
            case "chain", "chains": return .chain
            case "subscription", "subscriptions": return .subscription
            case "module", "modules": return .module
            default: return nil
            }
        }
    }

    struct Comment: Equatable, Sendable {
        let line: Int
        let text: String
    }

    struct Line: Equatable, Sendable {
        let number: Int
        let raw: String
        /// Content with surrounding whitespace and inline comment removed.
        let content: String
        let comment: String?

        var isBlank: Bool { content.isEmpty && comment == nil }
    }

    struct Entry: Equatable, Sendable {
        let line: Int
        /// `nil` for a bare directive (`[Rule]`, `[URL Rewrite]`, …).
        let key: String?
        let value: String
        let raw: String
        let comment: String?

        var isDirective: Bool { key == nil }
    }

    struct Section: Equatable, Sendable {
        let kind: SectionKind
        /// Header text as written, so unknown sections survive a round-trip.
        let rawName: String
        let headerLine: Int
        let comment: String?
        var entries: [Entry] = []
        var comments: [Comment] = []

        var isEmpty: Bool { entries.isEmpty }
    }

    /// All lines, including blanks and comments.
    var lines: [Line] = []
    /// Comments seen before the first section header.
    var preambleComments: [Comment] = []
    var sections: [Section] = []
    var diagnostics: [ConfigurationDiagnostic] = []

    var isEmpty: Bool { lines.allSatisfy(\.isBlank) }

    var text: String { lines.map(\.raw).joined(separator: "\n") }

    var firstError: ConfigurationDiagnostic? {
        diagnostics.sorted().first { $0.severity == .error }
    }

    func section(_ kind: SectionKind) -> Section? {
        sections.first { $0.kind == kind }
    }

    func sections(_ kind: SectionKind) -> [Section] {
        sections.filter { $0.kind == kind }
    }

    /// Entries of the first section of the given kind.
    func entries(_ kind: SectionKind) -> [Entry] {
        section(kind)?.entries ?? []
    }
}

// MARK: - Parsing

nonisolated extension ConfigurationDocument {

    /// Parses configuration text into a lossless document plus structural
    /// diagnostics. Semantic checks live in `NaiveFlowConfigurationParser` and
    /// `ConfigurationValidator`.
    static func parse(text source: String) -> ConfigurationDocument {
        var document = ConfigurationDocument()
        let rawLines = normalize(source).components(separatedBy: "\n")
        var currentSection: Int?

        for (offset, rawLine) in rawLines.enumerated() {
            let number = offset + 1
            let split = splitComment(rawLine)
            document.lines.append(
                Line(number: number, raw: rawLine, content: split.content, comment: split.comment)
            )

            guard !split.content.isEmpty else {
                if let text = split.comment {
                    let comment = Comment(line: number, text: text)
                    if let index = currentSection {
                        document.sections[index].comments.append(comment)
                    } else {
                        document.preambleComments.append(comment)
                    }
                }
                continue
            }

            if split.content.hasPrefix("[") {
                guard let name = sectionHeaderName(split.content) else {
                    document.diagnostics.append(
                        ConfigurationDiagnostic(
                            severity: .error,
                            code: .invalidSectionHeader,
                            line: number,
                            message: "Section header is not closed with ']'."
                        )
                    )
                    appendEntry(
                        content: split.content,
                        comment: split.comment,
                        line: number,
                        currentSection: currentSection,
                        in: &document
                    )
                    continue
                }

                let kind = SectionKind.matching(name)
                if kind == nil {
                    document.diagnostics.append(
                        ConfigurationDiagnostic(
                            severity: .error,
                            code: .unknownSection,
                            line: number,
                            section: name,
                            message: "Unrecognized section [\(name)]; its contents are preserved but not applied."
                        )
                    )
                }
                if let kind, document.sections.contains(where: { $0.kind == kind }) {
                    document.diagnostics.append(
                        ConfigurationDiagnostic(
                            severity: .warning,
                            code: .duplicateSection,
                            line: number,
                            section: name,
                            message: "Duplicate section [\(name)]; later entries are read as a continuation of the first section."
                        )
                    )
                }

                document.sections.append(
                    Section(kind: kind ?? .misc, rawName: name, headerLine: number, comment: split.comment)
                )
                currentSection = document.sections.count - 1
                continue
            }

            appendEntry(
                content: split.content,
                comment: split.comment,
                line: number,
                currentSection: currentSection,
                in: &document
            )
        }

        for section in document.sections where section.entries.isEmpty && section.kind != .misc {
            document.diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .warning,
                    code: .emptySection,
                    line: section.headerLine,
                    section: section.rawName,
                    message: "Section [\(section.rawName)] has no entries."
                )
            )
        }

        return document
    }

    private static func appendEntry(
        content: String,
        comment: String?,
        line: Int,
        currentSection: Int?,
        in document: inout ConfigurationDocument
    ) {
        guard let index = currentSection else {
            document.diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .unknownDirective,
                    line: line,
                    message: "Content appears before the first section header."
                )
            )
            return
        }

        let kind = document.sections[index].kind
        guard let entry = makeEntry(
            content: content,
            comment: comment,
            line: line,
            kind: kind,
            diagnostics: &document.diagnostics
        ) else { return }
        document.sections[index].entries.append(entry)
    }
}


// MARK: - Entry helpers

nonisolated extension ConfigurationDocument {

    static func makeEntry(
        content: String,
        comment: String?,
        line: Int,
        kind: SectionKind,
        diagnostics: inout [ConfigurationDiagnostic]
    ) -> Entry? {
        if kind.usesBareDirectives || kind == .misc {
            return Entry(line: line, key: nil, value: content, raw: content, comment: comment)
        }

        guard let equalsIndex = firstUnquotedEquals(in: content) else {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .missingEquals,
                    line: line,
                    section: kind.displayName,
                    message: "Expected 'key = value' but the line has no '='."
                )
            )
            return Entry(line: line, key: nil, value: content, raw: content, comment: comment)
        }

        let key = String(content[content.startIndex..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        let valueIndex = content.index(after: equalsIndex)
        let value = String(content[valueIndex...]).trimmingCharacters(in: .whitespaces)

        guard !key.isEmpty else {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .error,
                    code: .emptyKey,
                    line: line,
                    section: kind.displayName,
                    message: "Entry has no key before '='."
                )
            )
            return nil
        }

        if value.isEmpty {
            diagnostics.append(
                ConfigurationDiagnostic(
                    severity: .warning,
                    code: .emptyValue,
                    line: line,
                    section: kind.displayName,
                    message: "Entry '\(key)' has an empty value."
                )
            )
        }

        return Entry(line: line, key: key, value: value, raw: content, comment: comment)
    }

    static func sectionHeaderName(_ content: String) -> String? {
        guard content.hasPrefix("["), content.hasSuffix("]"), content.count >= 2 else { return nil }
        let name = content.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func firstUnquotedEquals(in content: String) -> String.Index? {
        var inQuote = false
        var escaped = false
        var index = content.startIndex
        while index < content.endIndex {
            let character = content[index]
            if escaped {
                escaped = false
            } else if character == "\\", inQuote {
                escaped = true
            } else if character == "\"" {
                inQuote.toggle()
            } else if character == "=", !inQuote {
                return index
            }
            index = content.index(after: index)
        }
        return nil
    }
}

// MARK: - Text helpers

nonisolated extension ConfigurationDocument {

    static func normalize(_ source: String) -> String {
        var text = source
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Splits a raw line into content and comment.
    ///
    /// `#` starts a comment at the beginning of a line or after whitespace, `;`
    /// starts a comment only at the beginning of a line, and `//` starts a
    /// comment only when nothing but whitespace precedes it. Treating `//`
    /// conservatively keeps URLs inside values (`script-path=https://…`) intact.
    static func splitComment(_ raw: String) -> (content: String, comment: String?) {
        let characters = Array(raw)
        var inQuote = false
        var escaped = false
        var onlyWhitespaceSoFar = true
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if escaped {
                escaped = false
                index += 1
                continue
            }
            if character == "\\", inQuote {
                escaped = true
                index += 1
                continue
            }
            if character == "\"" {
                inQuote.toggle()
                onlyWhitespaceSoFar = false
                index += 1
                continue
            }

            if !inQuote {
                let precededByWhitespace = index > 0 && characters[index - 1].isWhitespace
                var markerLength = 0
                if character == "#", onlyWhitespaceSoFar || precededByWhitespace {
                    markerLength = 1
                } else if character == ";", onlyWhitespaceSoFar {
                    markerLength = 1
                } else if character == "/", index + 1 < characters.count,
                          characters[index + 1] == "/", onlyWhitespaceSoFar {
                    markerLength = 2
                }

                if markerLength > 0 {
                    let content = String(characters[0..<index]).trimmingCharacters(in: .whitespaces)
                    let comment = String(characters[(index + markerLength)...])
                        .trimmingCharacters(in: .whitespaces)
                    return (content, comment.isEmpty ? nil : comment)
                }
                if !character.isWhitespace {
                    onlyWhitespaceSoFar = false
                }
            }

            index += 1
        }

        return (raw.trimmingCharacters(in: .whitespaces), nil)
    }

    /// Removes one level of surrounding double quotes and unescapes `\\` / `\"`.
    static func unquoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        if let decoded = try? JSONDecoder().decode(String.self, from: Data(trimmed.utf8)) { return decoded }
        var result = ""
        var escaped = false
        for character in trimmed.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            result.append(character)
        }
        return result
    }

    /// Splits a comma-separated list while respecting double quotes, dropping
    /// empty elements. Used for rule fields and proxy group members.
    static func splitList(_ value: String) -> [String] {
        splitFields(value, nested: false)
    }

    static func splitExpression(_ value: String) -> [String] {
        splitFields(value, nested: true)
    }

    private static func splitFields(_ value: String, nested: Bool) -> [String] {
        var results: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        var depth = 0
        func append() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { results.append(unquoted(trimmed)) }
            current = ""
        }
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", inQuote { current.append(character); escaped = true; continue }
            if character == "\"" { inQuote.toggle(); current.append(character); continue }
            if nested && !inQuote {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
            }
            if character == ",", !inQuote, depth == 0 { append(); continue }
            current.append(character)
        }
        append()
        return results
    }
}

