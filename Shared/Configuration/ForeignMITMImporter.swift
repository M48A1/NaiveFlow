import Foundation

/// Imports Surge / Quantumult X MITM + rewrite sections into the internal
/// `MITMRule` model. Resources are resolved before a module can be committed.
nonisolated enum ForeignMITMImporter {
    struct Resource: Sendable {
        enum Kind: Sendable {
            case script(argument: String?, binary: Bool, requiresBody: Bool, maxSize: Int?, timeout: Double?, name: String)
            case response(status: Int, headers: [String: String])
        }
        var ruleIndex: Int
        var source: String
        var kind: Kind
    }

    struct Result: Sendable {
        var domainSuffixes: [String] = []
        var rules: [MITMRule] = []
        var warnings: [String] = []
        var resources: [Resource] = []
    }

    static func parseSurge(_ text: String) -> Result {
        var result = Result()
        var section = ""
        for line in Self.lines(text) {
            if let name = Self.sectionName(line) { section = name; continue }
            switch section {
            case "mitm":
                result.domainSuffixes.append(contentsOf: Self.parseHostname(line))
            case "url rewrite":
                if let rule = Self.parseSurgeURLRewrite(line) { result.rules.append(rule) }
                else { result.warnings.append("Surge URL Rewrite unsupported: \(line)") }
            case "script":
                if !appendSurgeScript(line, to: &result) {
                    result.warnings.append("Surge script unsupported: \(line)")
                }
            case "map local":
                if !appendMapLocal(line, to: &result) {
                    result.warnings.append("Surge Map Local unsupported: \(line)")
                }
            case "body rewrite":
                if let rule = parseJQDelete(line) { result.rules.append(rule) }
                else { result.warnings.append("Surge Body Rewrite unsupported: \(line)") }
            case "rule":
                result.warnings.append("Surge directive unsupported: \(line)")
            case "header rewrite":
                if let rule = Self.parseSurgeHeaderRewrite(line) { result.rules.append(rule) }
                else { result.warnings.append("Surge Header Rewrite unsupported: \(line)") }
            default:
                break
            }
        }
        return result
    }

    static func parseQX(_ text: String) -> Result {
        var result = Result()
        var section = ""
        for line in Self.lines(text) {
            if let name = Self.sectionName(line) { section = name; continue }
            switch section {
            case "mitm":
                result.domainSuffixes.append(contentsOf: Self.parseHostname(line))
            case "", "rewrite_local":
                // Rewrite snippets may omit section headings entirely.
                if line.lowercased().hasPrefix("hostname") {
                    result.domainSuffixes.append(contentsOf: Self.parseHostname(line))
                } else if appendQXResponse(line, to: &result) {
                    continue
                } else if appendQXScript(line, to: &result) {
                    continue
                } else if let rule = Self.parseQXRewrite(line) {
                    result.rules.append(rule)
                } else {
                    result.warnings.append("QX rewrite unsupported: \(line)")
                }
            case "rewrite_remote":
                if let rule = Self.parseQXRewrite(line) { result.rules.append(rule) }
                else { result.warnings.append("QX rewrite unsupported: \(line)") }
            default:
                break
            }
        }
        return result
    }

    /// Apply the module author's defaults before reading script arguments.
    static func expandArguments(_ text: String) -> String {
        var expanded = text
        for line in text.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "#!arguments" else { continue }
            for pair in ConfigurationDocument.splitList(String(parts[1])) {
                let field = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard field.count == 2 else { continue }
                let name = field[0].trimmingCharacters(in: .whitespaces)
                let value = ConfigurationDocument.unquoted(field[1].trimmingCharacters(in: .whitespaces))
                expanded = expanded.replacingOccurrences(of: "{{{\(name)}}}", with: value)
            }
        }
        return expanded
    }

    private static func appendSurgeScript(_ line: String, to result: inout Result) -> Bool {
        guard let equal = line.firstIndex(of: "=") else { return false }
        let name = line[..<equal].trimmingCharacters(in: .whitespaces)
        var fields: [String: String] = [:]
        for token in ConfigurationDocument.splitList(String(line[line.index(after: equal)...])) {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return false }
            fields[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = ConfigurationDocument.unquoted(pair[1].trimmingCharacters(in: .whitespaces))
        }
        if ["false", "0"].contains(fields["enabled"]?.lowercased() ?? "") { return true }
        let supported: Set<String> = ["type", "pattern", "script-path", "argument", "requires-body", "binary-body-mode", "max-size", "timeout", "engine", "debug", "enabled", "script-update-interval"]
        guard fields.keys.allSatisfy(supported.contains),
              let type = fields["type"], ["http-request", "http-response"].contains(type),
              let pattern = fields["pattern"], let source = fields["script-path"], !source.isEmpty,
              (try? NSRegularExpression(pattern: pattern)) != nil else { return false }
        for key in ["requires-body", "binary-body-mode", "debug", "enabled"] {
            if let value = fields[key], !["true", "false", "1", "0"].contains(value.lowercased()) { return false }
        }
        if let size = fields["max-size"], Int(size) == nil { return false }
        let timeout = fields["timeout"].flatMap(Double.init)
        if fields["timeout"] != nil, !(timeout.map { $0.isFinite && $0 > 0 } ?? false) { return false }
        let index = result.rules.count
        result.rules.append(MITMRule(phase: type == "http-request" ? .httpRequest : .httpResponse,
            urlPattern: pattern, operation: .script(scriptBase64: "", dialect: .surge)))
        result.resources.append(Resource(ruleIndex: index, source: source,
            kind: .script(argument: fields["argument"],
                binary: ["true", "1"].contains(fields["binary-body-mode"]?.lowercased() ?? ""),
                requiresBody: ["true", "1"].contains(fields["requires-body"]?.lowercased() ?? ""),
                maxSize: fields["max-size"].flatMap(Int.init), timeout: timeout, name: name)))
        return true
    }

    private static func appendQXResponse(_ line: String, to result: inout Result) -> Bool {
        let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 4, fields[1] == "url", fields[2] == "echo-response",
              let separator = fields[3].range(of: " echo-response ", options: .backwards),
              (try? NSRegularExpression(pattern: fields[0])) != nil else { return false }
        let source = String(fields[3][separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return false }
        let headerText = fields[3][..<separator.lowerBound].replacingOccurrences(of: "\\r\\n", with: "\n")
        let lines = headerText.components(separatedBy: "\n")
        guard let contentType = lines.first, !contentType.isEmpty else { return false }
        var headers = ["Content-Type": contentType]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return false }
            headers[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        result.resources.append(Resource(ruleIndex: result.rules.count, source: source, kind: .response(status: 200, headers: headers)))
        result.rules.append(MITMRule(phase: .httpRequest, urlPattern: fields[0], operation: .script(scriptBase64: "", dialect: .quantumultX)))
        return true
    }

    private static func appendQXScript(_ line: String, to result: inout Result) -> Bool {
        let parts = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 4, parts[1].lowercased() == "url" else { return false }
        let action = parts[2].lowercased()
        let supported = ["script-request-header", "script-request-body", "script-response-header", "script-response-body", "script-echo-response", "script-analyze-echo-response"]
        guard supported.contains(action), (try? NSRegularExpression(pattern: parts[0])) != nil else { return false }
        let phase: MITMPhase = action.hasPrefix("script-response") ? .httpResponse : .httpRequest
        let index = result.rules.count
        result.rules.append(MITMRule(phase: phase, urlPattern: parts[0], operation: .script(scriptBase64: "", dialect: .quantumultX)))
        result.resources.append(Resource(ruleIndex: index, source: parts[3],
            kind: .script(argument: nil, binary: false, requiresBody: action.hasSuffix("body") || action == "script-analyze-echo-response", maxSize: nil, timeout: nil, name: action)))
        return true
    }

    private static func appendMapLocal(_ line: String, to result: inout Result) -> Bool {
        let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, (try? NSRegularExpression(pattern: String(parts[0]))) != nil else { return false }
        // Values can contain spaces and unescaped JSON quotes. The next key=value
        // starts a field; splitting on whitespace alone corrupts JSON responses.
        let body = String(parts[1])
        let regex = try! NSRegularExpression(pattern: #"(?:^|\s+)([a-z-]+)="#)
        let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
        var fields: [String: String] = [:]
        for (i, match) in matches.enumerated() {
            guard let keyRange = Range(match.range(at: 1), in: body) else { continue }
            let start = match.range.location + match.range.length
            let end = i + 1 < matches.count ? matches[i + 1].range.location : (body as NSString).length
            let value = (body as NSString).substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
            fields[String(body[keyRange])] = ConfigurationDocument.unquoted(value)
        }
        let status = fields["status-code"].flatMap(Int.init) ?? 200
        guard (100...599).contains(status) else { return false }
        var headers: [String: String] = [:]
        for raw in (fields["header"] ?? "").split(separator: "|") {
            let pair = raw.split(separator: ":", maxSplits: 1)
            if pair.count == 2 { headers[String(pair[0]).trimmingCharacters(in: .whitespaces)] = String(pair[1]).trimmingCharacters(in: .whitespaces) }
            else { headers["Content-Type"] = String(raw) }
        }
        let data = fields["data"] ?? ""
        let type = fields["data-type"] ?? "text"
        guard ["file", "text", "base64"].contains(type) else { return false }
        let index = result.rules.count
        if type == "file" {
            result.rules.append(MITMRule(phase: .httpRequest, urlPattern: String(parts[0]), operation: .script(scriptBase64: "", dialect: .surge)))
            result.resources.append(Resource(ruleIndex: index, source: data, kind: .response(status: status, headers: headers)))
        } else {
            guard let bytes = type == "base64" ? Data(base64Encoded: data) : data.data(using: .utf8) else { return false }
            let source = responseScript(data: bytes, status: status, headers: headers)
            result.rules.append(MITMRule(phase: .httpRequest, urlPattern: String(parts[0]), operation: .script(scriptBase64: Data(source.utf8).base64EncodedString(), dialect: .surge)))
        }
        return true
    }

    static func responseScript(data: Data, status: Int, headers: [String: String], dialect: MITMScriptDialect = .surge) -> String {
        let headersJSON = String(decoding: try! JSONEncoder().encode(headers), as: UTF8.self)
        let bytes = "Uint8Array.from(atob('\(data.base64EncodedString())'),c=>c.charCodeAt(0))"
        if dialect == .quantumultX {
            return "$done({status:\(status),headers:\(headersJSON),bodyBytes:\(bytes).buffer});"
        }
        return "$done({response:{status:\(status),headers:\(headersJSON),body:\(bytes)}});"
    }

    private static func parseJQDelete(_ line: String) -> MITMRule? {
        let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 3, parts[0] == "http-response-jq" else { return nil }
        let expression = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard expression.hasPrefix("del(."), expression.hasSuffix(")") else { return nil }
        let path = String(expression.dropFirst(5).dropLast())
        guard path.range(of: #"^[A-Za-z_][A-Za-z_0-9]*(\.[A-Za-z_][A-Za-z_0-9]*)*$"#, options: .regularExpression) != nil else { return nil }
        return MITMRule(phase: .httpResponse, urlPattern: parts[1], operation: .bodyJSON(.delete(path: path)))
    }

    // MARK: - Line handling

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(";") && !$0.hasPrefix("//") }
    }

    private static func sectionName(_ line: String) -> String? {
        guard line.hasPrefix("[") && line.hasSuffix("]") else { return nil }
        return String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func parseHostname(_ line: String) -> [String] {
        guard line.lowercased().hasPrefix("hostname"), let equals = line.firstIndex(of: "=") else { return [] }
        let value = line[line.index(after: equals)...]
            .replacingOccurrences(of: "%APPEND%", with: "", options: .caseInsensitive)
        var suffixes: [String] = []
        for item in value.split(separator: ",") {
            var host = item.trimmingCharacters(in: .whitespaces)
            if host.hasPrefix("*.") { host = String(host.dropFirst(2)) }
            else if host.hasPrefix(".") { host = String(host.dropFirst()) }
            if let normalized = DNSName.normalizedHost(host) { suffixes.append(normalized) }
        }
        return suffixes
    }

    private static func parseSurgeURLRewrite(_ line: String) -> MITMRule? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let pattern = String(parts[0])
        let replacement = String(parts[1])
        let type = parts.count >= 3 ? String(parts[2]).lowercased() : "302"
        switch type {
        case "302", "redirect":
            return MITMRule(phase: .httpRequest, urlPattern: pattern, operation: .rewrite(.redirect302(url: replacement)))
        case "reject", "reject-200":
            return MITMRule(phase: .httpRequest, urlPattern: pattern, operation: .rewrite(.reject200Text(content: "")))
        default:
            return nil
        }
    }

    private static func parseSurgeHeaderRewrite(_ line: String) -> MITMRule? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        let pattern = String(parts[0])
        let name = String(parts[1])
        let value = String(parts[2])
        guard Self.isValidHeaderName(name), !value.contains("\r"), !value.contains("\n") else { return nil }
        return MITMRule(phase: .httpRequest, urlPattern: pattern, operation: .headerReplace(name: name, value: value))
    }

    private static func parseQXRewrite(_ line: String) -> MITMRule? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let pattern = String(parts[0])
        let type = String(parts[1]).lowercased()
        if type == "url" {
            guard parts.count >= 3 else { return nil }
            let action = String(parts[2]).lowercased()
            switch action {
            case "302", "redirect":
                guard parts.count >= 4 else { return nil }
                return MITMRule(phase: .httpRequest, urlPattern: pattern, operation: .rewrite(.redirect302(url: String(parts[3]))))
            case "reject-200":
                return MITMRule(phase: .httpRequest, urlPattern: pattern, operation: .rewrite(.reject200Text(content: "")))
            case "reject-img":
                return MITMRule(phase: .httpRequest, urlPattern: pattern, operation: .rewrite(.reject200Gif))
            case "reject", "reject-dict", "reject-array":
                let json = action == "reject-dict" ? "{}" : action == "reject-array" ? "[]" : ""
                let status = action == "reject" ? 404 : 200
                let headers = action == "reject" ? [:] : ["Content-Type": "application/json"]
                let source = responseScript(data: Data(json.utf8), status: status, headers: headers, dialect: .quantumultX)
                return MITMRule(phase: .httpRequest, urlPattern: pattern, operation: .script(scriptBase64: Data(source.utf8).base64EncodedString(), dialect: .quantumultX))
            default:
                return nil
            }
        }
        guard !type.hasPrefix("url-"), parts.count >= 3 else { return nil }
        let name = String(parts[1])
        let value = String(parts[2])
        guard Self.isValidHeaderName(name), !value.contains("\r"), !value.contains("\n") else { return nil }
        return MITMRule(phase: .httpRequest, urlPattern: pattern, operation: .headerReplace(name: name, value: value))
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }
}
