import Foundation
import JavaScriptCore

nonisolated struct CompiledTextMITM: Sendable {
    struct Script: Equatable, Sendable {
        let name: String
        let phase: MITMPhase
        let pattern: String
        let source: String
        let argument: String?
        let dialect: MITMScriptDialect
    }
    var embeddedSets: [MITMRuleSet] = []
    var embeddedSignature: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(embeddedSets)
    }
    var suffixes: [String] = []
    var rules: [MITMRule] = []
    var scripts: [Script] = []

    /// Resolve all external content before publication. One document always
    /// carries the same script bytes on first apply, rollback and later starts.
    @concurrent
    func resolveScripts() async throws -> [MITMRuleSet] {
        var resolved = rules
        for script in scripts {
            let data: Data
            if script.source.hasPrefix("base64:") {
                guard let decoded = Data(base64Encoded: String(script.source.dropFirst(7))) else {
                    throw RuntimeConfigurationFailure.rejected("Invalid base64 script: \(script.name)")
                }
                data = decoded
            } else {
                guard let url = URL(string: script.source), url.scheme == "https" else {
                    throw RuntimeConfigurationFailure.rejected("Script sources must use HTTPS or base64:.")
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (download, response) = try await URLSession.shared.bytes(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      response.url?.scheme == "https" else {
                    throw RuntimeConfigurationFailure.rejected("Could not download script: \(script.name)")
                }
                var bounded = Data()
                for try await byte in download {
                    guard bounded.count < RuntimeJavaScript.maximumScriptBytes else {
                        throw RuntimeConfigurationFailure.rejected("A script exceeds 4 MB.")
                    }
                    bounded.append(byte)
                }
                data = bounded
            }
            guard data.count <= RuntimeJavaScript.maximumScriptBytes, var source = String(data: data, encoding: .utf8) else {
                throw RuntimeConfigurationFailure.rejected("Script exceeds 4 MB or is not UTF-8: \(script.name)")
            }
            if let argument = script.argument {
                let json = String(decoding: try JSONEncoder().encode(argument), as: UTF8.self)
                source = "const $argument = \(json);\n" + source
            }
            try Self.validateJavaScript(source)
            let encoded = Data(source.utf8).base64EncodedString()
            resolved.append(MITMRule(
                phase: script.phase, urlPattern: script.pattern,
                operation: .script(scriptBase64: encoded, dialect: script.dialect)
            ))
        }
        guard !suffixes.isEmpty else { return embeddedSets }
        let overlap = embeddedSets.flatMap(\.domainSuffixes).contains { suffixes.contains($0) }
        guard !overlap else { throw RuntimeConfigurationFailure.rejected("MITM Set and MITM hostname have duplicate scopes.") }
        return embeddedSets + [MITMRuleSet(id: UUID(uuidString: "2CB57A63-F025-4636-959B-304A2B652EDF")!, name: "Text configuration", domainSuffixes: suffixes, rules: resolved)]
    }

    static func validateJavaScript(_ source: String) throws { try RuntimeJavaScript.validate(source) }

}

nonisolated enum TextMITMCompiler {
    static func compile(_ parsed: ParsedConfiguration, diagnostics: inout [ConfigurationDiagnostic]) -> CompiledTextMITM {
        var result = CompiledTextMITM()
        result.suffixes = (parsed.mitm.list("hostname") ?? []).compactMap(DNSName.normalizedHost)
        for (name, encoded) in parsed.mitmSets.pairs {
            do {
                guard encoded.hasPrefix("base64:"), let data = Data(base64Encoded: String(encoded.dropFirst(7))),
                      let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawRules = raw["rules"] as? [Any] else { throw RuntimeConfigurationFailure.invalidBundle }
                let set = try JSONDecoder().decode(MITMRuleSet.self, from: data)
                guard set.rules.count == rawRules.count, !set.domainSuffixes.isEmpty,
                      !result.embeddedSets.contains(where: { $0.id == set.id }) else { throw RuntimeConfigurationFailure.invalidBundle }
                result.embeddedSets.append(set)
            } catch {
                diagnostics.append(.init(severity: .error, code: .invalidValue, section: "MITM Set",
                    message: "Invalid native encoded MITM rule set '\(name)'."))
            }
        }
        for directive in parsed.rewrites {
            diagnostics.append(.init(severity: .error, code: .notApplied, line: directive.line,
                section: directive.section, message: "Import rewrite rules as a Surge or Quantumult X module."))
        }
        for script in parsed.scripts where script.phase.isSupportedByEngine {
            guard let pattern = script.pattern, let source = script.path else { continue }
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch {
                diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .invalidValue,
                    line: script.line, section: "Script", message: "Invalid script URL pattern."))
                continue
            }
            let supported = Set(["type", "pattern", "script-path", "source", "argument", "dialect"])
            for (key, _) in script.parameters.pairs where !supported.contains(key) {
                diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .notApplied,
                    line: script.line, section: "Script", message: "Unsupported script parameter '\(key)'."))
            }
            let dialectName = script.parameters["dialect"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "surge"
            guard let dialect = MITMScriptDialect(rawValue: dialectName) else {
                diagnostics.append(.init(severity: .error, code: .invalidValue, line: script.line,
                    section: "Script", message: "dialect must be surge or quantumult-x."))
                continue
            }
            result.scripts.append(.init(name: script.name,
                phase: script.phase == .httpRequest ? .httpRequest : .httpResponse,
                pattern: pattern, source: source, argument: script.argument, dialect: dialect))
        }
        if (!result.rules.isEmpty || !result.scripts.isEmpty), result.suffixes.isEmpty {
            diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .missingValue,
                section: "MITM", message: "Text scripts and rewrites require [MITM] hostname suffixes."))
        }
        return result
    }
}
