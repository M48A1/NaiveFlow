import Foundation

/// Imports Surge / Quantumult X MITM + rewrite sections into the internal
/// `MITMRule` model. Unsupported directives are reported as warnings instead of
/// being silently dropped. Script download (`script-path`) is out of scope for
/// now; static rewrites are handled.
nonisolated enum ForeignMITMImporter {
    struct Result: Sendable {
        var domainSuffixes: [String] = []
        var rules: [MITMRule] = []
        var warnings: [String] = []
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
            case "rewrite_local", "rewrite_remote":
                if let rule = Self.parseQXRewrite(line) { result.rules.append(rule) }
                else { result.warnings.append("QX rewrite unsupported: \(line)") }
            default:
                break
            }
        }
        return result
    }

    // MARK: - Line handling

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(";") && !$0.hasPrefix("//") }
    }

    private static func sectionName(_ line: String) -> String? {
        guard line.hasPrefix("[") && line.hasSuffix("]") else { return nil }
        return String(line.dropFirst().dropLast()).lowercased()
    }

    private static func parseHostname(_ line: String) -> [String] {
        guard line.lowercased().hasPrefix("hostname"), let equals = line.firstIndex(of: "=") else { return [] }
        let value = line[line.index(after: equals)...]
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
            case "reject", "reject-200":
                return MITMRule(phase: .httpRequest, urlPattern: pattern, operation: .rewrite(.reject200Text(content: "")))
            default:
                return nil
            }
        }
        guard parts.count >= 3 else { return nil }
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
