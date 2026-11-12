import Foundation
import JavaScriptCore

nonisolated struct CompiledTextMITM: Sendable {
    struct Script: Equatable, Sendable {
        let name: String
        let phase: MITMPhase
        let pattern: String
        let source: String
        let argument: String?
        let stream: Bool
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
            guard !script.stream else {
                throw RuntimeConfigurationFailure.rejected("Anywhere stream-script is no longer supported.")
            }
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
            do { result.rules.append(try rewrite(directive)) }
            catch {
                diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .invalidValue,
                    line: directive.line, section: directive.section, message: error.localizedDescription))
            }
        }
        for script in parsed.scripts where script.phase.isSupportedByEngine {
            guard let pattern = script.pattern, let source = script.path else { continue }
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch {
                diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .invalidValue,
                    line: script.line, section: "Script", message: "Invalid script URL pattern."))
                continue
            }
            let supported = Set(["type", "pattern", "script-path", "source", "argument", "stream", "dialect"])
            for (key, _) in script.parameters.pairs where !supported.contains(key) {
                diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .notApplied,
                    line: script.line, section: "Script", message: "Unsupported script parameter '\(key)'."))
            }
            if script.parameters.contains("stream"), script.parameters.bool("stream") == nil {
                diagnostics.append(.init(severity: .error, code: .invalidValue, line: script.line,
                    section: "Script", message: "stream expects a boolean value."))
            }
            if script.parameters.bool("stream") == true {
                diagnostics.append(.init(severity: .error, code: .invalidValue, line: script.line,
                    section: "Script", message: "Anywhere stream-script has been removed; use a buffered Surge or Quantumult X script."))
                continue
            }
            let dialectName = script.parameters["dialect"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "surge"
            guard let dialect = MITMScriptDialect(rawValue: dialectName) else {
                diagnostics.append(.init(severity: .error, code: .invalidValue, line: script.line,
                    section: "Script", message: "dialect must be surge or quantumult-x."))
                continue
            }
            result.scripts.append(.init(name: script.name,
                phase: script.phase == .httpRequest ? .httpRequest : .httpResponse,
                pattern: pattern, source: source, argument: script.argument,
                stream: script.parameters.bool("stream") ?? false, dialect: dialect))
        }
        if (!result.rules.isEmpty || !result.scripts.isEmpty), result.suffixes.isEmpty {
            diagnostics.append(ConfigurationDiagnostic(severity: .error, code: .missingValue,
                section: "MITM", message: "Text scripts and rewrites require [MITM] hostname suffixes."))
        }
        return result
    }

    private static func rewrite(_ directive: ParsedRewriteDirective) throws -> MITMRule {
        let tokens = ConfigurationDocument.splitList(directive.text)
        var values = tokens
        var phase = MITMPhase.httpRequest
        if directive.section.lowercased() == "header rewrite" || directive.section.lowercased() == "body rewrite" {
            guard let first = values.first, ["request", "response"].contains(first.lowercased()) else {
                throw RuntimeConfigurationFailure.rejected("Rewrite starts with request or response.")
            }
            phase = values.removeFirst().lowercased() == "request" ? .httpRequest : .httpResponse
        }
        guard values.count >= 2 else { throw RuntimeConfigurationFailure.rejected("A rewrite requires a URL regex and an action.") }
        let pattern = values.removeFirst()
        _ = try NSRegularExpression(pattern: pattern)
        let action = values.removeFirst().lowercased()
        let operation: MITMOperation
        switch directive.section.lowercased() {
        case "url rewrite", "rewrite":
            switch (action, values.count) {
            case ("redirect", 1), ("302", 1): operation = .rewrite(.redirect302(url: values[0]))
            case ("transparent", 1):
                guard values[0].hasPrefix("https://") else { throw RuntimeConfigurationFailure.invalidBundle }
                operation = .rewrite(.transparent(url: values[0]))
            case ("reject", 0): operation = .rewrite(.reject200Text(content: ""))
            default: throw RuntimeConfigurationFailure.rejected("URL action is redirect, transparent or reject.")
            }
        case "header rewrite":
            guard values.count == (action == "delete" ? 1 : 2),
                  let name = values.first, validHeader(name),
                  !["content-length", "transfer-encoding", "connection", "upgrade", "host"].contains(name.lowercased()),
                  values.dropFirst().allSatisfy({ !$0.contains("\r") && !$0.contains("\n") })
            else { throw RuntimeConfigurationFailure.rejected("Invalid or framing header rewrite.") }
            switch action {
            case "add": operation = .headerAdd(name: name, value: values[1])
            case "replace": operation = .headerReplace(name: name, value: values[1])
            case "delete": operation = .headerDelete(name: name)
            default: throw RuntimeConfigurationFailure.invalidBundle
            }
        case "body rewrite":
            switch (action, values.count) {
            case ("replace", 2):
                _ = try NSRegularExpression(pattern: values[0])
                operation = .bodyReplace(search: values[0], replacement: values[1])
            case ("json-add", 2): operation = .bodyJSON(.add(path: values[0], value: values[1]))
            case ("json-replace", 2): operation = .bodyJSON(.replace(path: values[0], value: values[1]))
            case ("json-delete", 1): operation = .bodyJSON(.delete(path: values[0]))
            case ("json-replace-recursive", 2): operation = .bodyJSON(.replaceRecursive(key: values[0], value: values[1]))
            case ("json-delete-recursive", 1): operation = .bodyJSON(.deleteRecursive(key: values[0]))
            case ("json-remove-where-key-exists", 2): operation = .bodyJSON(.removeWhereKeyExists(path: values[0], key: values[1]))
            case ("json-remove-where-field-in", 3): operation = .bodyJSON(.removeWhereFieldIn(path: values[0], field: values[1], values: values[2]))
            default: throw RuntimeConfigurationFailure.rejected("Invalid native body rewrite action or argument count.")
            }
        case "map local":
            switch (action, values.count) {
            case ("text", 1): operation = .rewrite(.reject200Text(content: values[0]))
            case ("gif", 0): operation = .rewrite(.reject200Gif)
            case ("base64", 1):
                guard Data(base64Encoded: values[0]) != nil else { throw RuntimeConfigurationFailure.invalidBundle }
                operation = .rewrite(.reject200Data(base64: values[0]))
            default: throw RuntimeConfigurationFailure.rejected("Map Local action is text, gif or base64.")
            }
        default: throw RuntimeConfigurationFailure.invalidBundle
        }
        return MITMRule(phase: phase, urlPattern: pattern, operation: operation)
    }

    private static func validHeader(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }
}
