//
//  ConfigurationDocumentEditing.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Line-level edits for the configuration editor's rule list and settings
/// switches.
///
/// Every helper returns a freshly parsed document instead of mutating stale
/// indexes, so a caller can chain edits (`document.insertingRule(…).movingRule(…)`)
/// and always end up with line numbers that match the text it will show. Editing
/// is text-preserving: comments, blank lines, and unknown sections stay where the
/// user put them.
nonisolated extension ConfigurationDocument {

    /// 1-based line lookup matching `Line.number`.
    func line(_ number: Int) -> Line? {
        lines.first { $0.number == number }
    }

    func replacingLine(_ number: Int, with content: String) -> ConfigurationDocument {
        var rawLines = rawLineTexts
        guard rawLines.indices.contains(number - 1) else { return self }
        rawLines[number - 1] = content
        return document(from: rawLines)
    }

    /// Inserts after `number`; pass `lines.count` to append at the end.
    func insertingLine(_ content: String, after number: Int) -> ConfigurationDocument {
        var rawLines = rawLineTexts
        let index = min(max(number, 0), rawLines.count)
        rawLines.insert(content, at: index)
        return document(from: rawLines)
    }

    func appendingLine(_ content: String) -> ConfigurationDocument {
        insertingLine(content, after: lines.count)
    }

    func removingLine(_ number: Int) -> ConfigurationDocument {
        var rawLines = rawLineTexts
        guard rawLines.indices.contains(number - 1) else { return self }
        rawLines.remove(at: number - 1)
        return document(from: rawLines)
    }

    // MARK: - Rules

    /// Appends a rule to `[Rule]`, or inserts it after `lineNumber` when that line
    /// is already one of the section's rules.
    func insertingRule(_ rule: String, after lineNumber: Int? = nil) -> ConfigurationDocument {
        if let lineNumber, isRuleLine(lineNumber) {
            return insertingLine(rule, after: lineNumber)
        }
        guard let section = section(.rule) else {
            let separator = isEmpty || lines.last?.isBlank == true ? "" : "\n"
            let withHeader = appendingLine(separator + "[\(SectionKind.rule.displayName)]")
            return withHeader.appendingLine(rule)
        }
        return insertingLine(rule, after: section.entries.last?.line ?? section.headerLine)
    }

    /// Moves a rule by `offset` positions inside `[Rule]`. Offsets that would
    /// leave the section are ignored; FINAL only moves if the user asks for it,
    /// and the validator reports a misplaced FINAL afterwards.
    func movingRule(at lineNumber: Int, by offset: Int) -> ConfigurationDocument {
        let ruleLines = entries(.rule).map(\.line)
        guard let position = ruleLines.firstIndex(of: lineNumber) else { return self }
        let target = position + offset
        guard ruleLines.indices.contains(target) else { return self }
        var rawLines = rawLineTexts
        let first = ruleLines[position] - 1
        let second = ruleLines[target] - 1
        guard rawLines.indices.contains(first), rawLines.indices.contains(second) else { return self }
        rawLines.swapAt(first, second)
        return document(from: rawLines)
    }

    func isRuleLine(_ number: Int) -> Bool {
        entries(.rule).contains { $0.line == number }
    }

    // MARK: - Settings

    /// Rewrites `key = value` in the first section of `kind`. An inline comment is
    /// re-rendered as `# …` because the original marker is not stored per entry.
    func settingValue(_ value: String, forKey key: String, in kind: SectionKind) -> ConfigurationDocument {
        guard let entry = entries(kind).first(where: { $0.key?.caseInsensitiveCompare(key) == .orderedSame }),
              let stored = line(entry.line)
        else { return self }
        let indent = String(stored.raw.prefix { $0 == " " || $0 == "\t" })
        let comment = stored.comment.map { "  # \($0)" } ?? ""
        return replacingLine(entry.line, with: "\(indent)\(entry.key ?? key) = \(value)\(comment)")
    }

    func settingValue(_ value: Bool, forKey key: String, in kind: SectionKind) -> ConfigurationDocument {
        settingValue(value ? "true" : "false", forKey: key, in: kind)
    }

    // MARK: - Helpers

    private var rawLineTexts: [String] { lines.map(\.raw) }

    private func document(from rawLines: [String]) -> ConfigurationDocument {
        ConfigurationDocument.parse(text: rawLines.joined(separator: "\n"))
    }
}
