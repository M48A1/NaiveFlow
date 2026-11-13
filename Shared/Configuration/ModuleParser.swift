//
//  ModuleParser.swift
//  NaiveFlow
//
//  Created by NodePassProject on 10/9/26.
//

import Foundation

enum ModuleParser {
    static func parse(_ text: String, format: ModuleFormat) -> (content: ModuleContent, warnings: [String], resources: [ForeignMITMImporter.Resource]) {
        let normalized = ForeignMITMImporter.expandArguments(ConfigurationImport.normalize(text))
        let parsed = format == .surge
            ? ForeignMITMImporter.parseSurge(normalized)
            : ForeignMITMImporter.parseQX(normalized)
        var content = ModuleContent()
        for raw in normalized.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\n", with: "\n")
            if key == "#!name" { content.name = value }
            if key == "#!desc" { content.description = value }
        }
        if !parsed.rules.isEmpty || !parsed.domainSuffixes.isEmpty {
            content.mitmRuleSets = [ModuleMITMRuleSet(
                name: "MITM", domainSuffixes: parsed.domainSuffixes, rules: parsed.rules
            )]
        }
        return (content, parsed.warnings, parsed.resources)
    }
}
