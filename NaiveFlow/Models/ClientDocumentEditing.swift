import Foundation

/// Structured UI edits always produce the same document consumed by the compiler.
nonisolated enum ClientDocumentEditing {
    static func token(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func set(_ text: String, section: ConfigurationDocument.SectionKind, key: String, value: String?) -> String {
        var document = ConfigurationDocument.parse(text: text)
        let matches = document.entries(section).filter { ConfigurationDocument.unquoted($0.key ?? "").caseInsensitiveCompare(key) == .orderedSame }
        guard let value else {
            for entry in matches.reversed() { document = document.removingLine(entry.line) }
            return document.text
        }
        let renderedKey = [.proxy, .proxyGroup, .chain].contains(section) ? token(key) : key
        let comment = matches.first?.comment.map { "  # " + $0 } ?? ""
        let line = "\(renderedKey) = \(value)" + comment
        if let first = matches.first {
            for entry in matches.dropFirst().reversed() { document = document.removingLine(entry.line) }
            return document.replacingLine(first.line, with: line).text
        }
        if let existing = document.section(section) {
            return document.insertingLine(line, after: existing.entries.last?.line ?? existing.headerLine).text
        }
        return document.appendingLine("\n[\(section.displayName)]\n\(line)").text
    }

    static func saveRuleSet(_ text: String, original: ParsedRule?, source: String, policy: String, noResolve: Bool) throws -> String {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.contains(where: { $0.isNewline }), !policy.contains(where: { $0.isNewline }) else {
            throw ClientFailure("The URL and policy cannot contain line breaks.")
        }
        _ = try NativeRuleSet.sourceURL(source)
        let otherOptions = original?.options.filter { $0 != .noResolve }.map(\.token) ?? []
        let fields = ["RULE-SET", token(source), token(policy)] + otherOptions + (noResolve ? ["no-resolve"] : [])
        let line = fields.joined(separator: ", ")
        let document = ConfigurationDocument.parse(text: text)
        let parsed = NaiveFlowConfigurationParser.parse(text: text).configuration
        if let original {
            guard original.kind == .ruleSet, parsed.rules.contains(original) else {
                throw ClientFailure("This rule has changed. Close and reopen the editor.")
            }
            let comment = document.entries(.rule).first { $0.line == original.line }?.comment.map { "  # " + $0 } ?? ""
            return document.replacingLine(original.line, with: line + comment).text
        }
        // A new reference must precede FINAL so it remains reachable.
        if let final = parsed.rules.first(where: \.isFinal) {
            return document.insertingLine(line, after: final.line - 1).text
        }
        return document.insertingRule(line).text
    }

    static func renameKey(_ text: String, section: ConfigurationDocument.SectionKind, from old: String, to new: String) -> String {
        let document = ConfigurationDocument.parse(text: text)
        guard let entry = document.entries(section).first(where: { ConfigurationDocument.unquoted($0.key ?? "") == old }) else { return text }
        let comment = entry.comment.map { "  # " + $0 } ?? ""
        return document.replacingLine(entry.line, with: token(new) + " = " + entry.value + comment).text
    }

    static func reorder(_ text: String, section: ConfigurationDocument.SectionKind, keys: [String]) -> String {
        let document = ConfigurationDocument.parse(text: text)
        let entries = document.entries(section)
        let byName = Dictionary(entries.compactMap { e in e.key.map { (ConfigurationDocument.unquoted($0), e.raw) } }, uniquingKeysWith: { first, _ in first })
        let ordered = keys.compactMap { byName[$0] }
        guard ordered.count == entries.count else { return text }
        var result = document
        for (entry, raw) in zip(entries, ordered) { result = result.replacingLine(entry.line, with: raw) }
        return result.text
    }

    static func groupValue(kind: String, members: [String], parameters: [(String, String)]) -> String {
        ([kind] + members.map(token) + parameters.filter { !$0.1.isEmpty }.map { "\($0.0)=\(token($0.1))" }).joined(separator: ", ")
    }
}
