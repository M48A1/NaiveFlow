import Foundation

/// Native rule providers contain conditions only. The referencing document owns
/// policy, ordering and no-resolve. Only flattened rules reach the extension.
nonisolated enum NativeRuleSet {
    static let maximumSourceBytes = 4 * 1024 * 1024
    static let maximumTotalBytes = 16 * 1024 * 1024
    static let maximumSources = 64
    static let maximumRules = 100_000
    /// Rule kinds a provider may contain. Providers hold conditions only, so
    /// anything needing tunnel metadata (PROCESS-NAME / USER-AGENT / URL-REGEX)
    /// or a nested reference (RULE-SET / FINAL) is rejected here. Logical
    /// composition (AND/OR/NOT) is allowed; a nested RULE-SET inside it is
    /// caught by the matcher.
    static let providerRuleKinds: Set<ParsedRule.Kind> = [
        .domain, .domainSuffix, .domainKeyword, .domainWildcard, .domainRegex,
        .ipCIDR, .ipASN, .sourceIP, .sourcePort, .destinationPort, .protocolType,
        .geoIP, .geoASN, .geoSite,
        .logicalAnd, .logicalOr, .logicalNot
    ]
    typealias Loader = @Sendable (URL) async throws -> Data

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func sourceURL(_ source: String) throws -> URL {
        guard let url = URL(string: source), url.user == nil, url.password == nil,
              url.fragment == nil else { throw Failure(message: "Invalid RULE-SET source URL.") }
        if url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty { return url }
        if url.isFileURL, url.path.hasPrefix("/"), url.host == nil || url.host == "" || url.host == "localhost" { return url }
        throw Failure(message: "RULE-SET sources must be HTTPS URLs or absolute file:/// URLs accessible to the app.")
    }

    @concurrent
    static func resolve(_ configuration: ParsedConfiguration, loader: Loader? = nil) async throws -> [String: String] {
        var contents: [String: String] = [:]
        var total = 0
        for rule in configuration.rules where rule.kind == .ruleSet {
            try Task.checkCancellation()
            guard let source = rule.value else { throw Failure(message: "RULE-SET has no source.") }
            if contents[source] != nil { continue }
            guard contents.count < maximumSources else { throw Failure(message: "Too many RULE-SET sources (maximum 64).") }
            do {
                let url = try sourceURL(source)
                let data: Data
                if let loader { data = try await loader(url) }
                else { data = try await download(url) }
                guard data.count <= maximumSourceBytes else { throw Failure(message: "RULE-SET exceeds 4 MiB.") }
                total += data.count
                guard total <= maximumTotalBytes else { throw Failure(message: "RULE-SET sources exceed 16 MiB in total.") }
                guard let text = String(data: data, encoding: .utf8) else { throw Failure(message: "RULE-SET is not valid UTF-8.") }
                contents[source] = text
            } catch {
                throw Failure(message: "RULE-SET at document line \(rule.line) (\(source)): \(error.localizedDescription)")
            }
        }
        return contents
    }

    @concurrent
    private static func download(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var data = Data()
            while data.count <= maximumSourceBytes {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: min(65_536, maximumSourceBytes + 1 - data.count)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            return data
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https" else { throw Failure(message: "RULE-SET download failed or redirected away from HTTPS.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumSourceBytes else { throw Failure(message: "RULE-SET exceeds 4 MiB.") }
            data.append(byte)
        }
        return data
    }

    /// Synchronous editor compilation never performs I/O. Pending sources are
    /// visible diagnostics; publication recompiles with all resources resolved.
    static func expand(_ source: ParsedConfiguration, contents: [String: String], diagnostics: inout [ConfigurationDiagnostic]) -> ParsedConfiguration {
        var result = source
        result.rules = []
        var cache: [String: [ParsedRule]] = [:]
        var sources = Set<String>()
        for reference in source.rules {
            guard reference.kind == .ruleSet else { result.rules.append(reference); continue }
            do {
                guard let name = reference.value else { throw Failure(message: "RULE-SET has no source.") }
                _ = try sourceURL(name)
                sources.insert(name)
                guard sources.count <= maximumSources else { throw Failure(message: "Too many RULE-SET sources (maximum 64).") }
                guard let text = contents[name] else {
                    diagnostics.append(.init(severity: .warning, code: .notApplied, line: reference.line, section: "Rule",
                        message: "RULE-SET is pending resource validation at apply time; routing preview is incomplete."))
                    result.rules.append(reference)
                    continue
                }
                ConfigurationValidator.validateRuleOptions(reference, diagnostics: &diagnostics)
                let entries: [ParsedRule]
                if let cached = cache[name] { entries = cached }
                else { entries = try parse(text, source: name); cache[name] = entries }
                guard result.rules.count + entries.count <= maximumRules else { throw Failure(message: "Expanded configuration exceeds 100,000 rules.") }
                for entry in entries {
                    var options = entry.options
                    if reference.hasOption(.noResolve), !entry.hasOption(.noResolve),
                       ConfigurationCompiler.matcher(for: entry)?.requiresResolvedAddress == true { options.append(.noResolve) }
                    result.rules.append(ParsedRule(line: reference.line, kind: entry.kind, value: entry.value,
                        policy: reference.policy, options: options, raw: entry.raw))
                }
            } catch {
                diagnostics.append(.init(severity: .error, code: .invalidValue, line: reference.line, section: "Rule", message: error.localizedDescription))
            }
        }
        if result.rules.count > maximumRules {
            diagnostics.append(.init(severity: .error, code: .invalidValue, section: "Rule", message: "Expanded configuration exceeds 100,000 rules."))
        }
        return result
    }

    static func parse(_ text: String, source: String) throws -> [ParsedRule] {
        guard text.utf8.count <= maximumSourceBytes else { throw Failure(message: "RULE-SET exceeds 4 MiB: \(source)") }
        var rules: [ParsedRule] = []
        for (offset, raw) in ConfigurationImport.normalize(text).components(separatedBy: "\n").enumerated() {
            let line = ConfigurationDocument.splitComment(raw).content
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            do {
                let fields = ConfigurationDocument.splitExpression(line)
                guard fields.count == 2 || (fields.count == 3 && fields[2].lowercased() == "no-resolve") else {
                    throw Failure(message: "Expected TYPE, value[, no-resolve]; policies belong on the RULE-SET reference.")
                }
                let kind = ParsedRule.Kind(token: fields[0])
                guard Self.providerRuleKinds.contains(kind) else {
                    throw Failure(message: "Unsupported provider rule type; providers hold conditions only.")
                }
                let rule = ParsedRule(line: offset + 1, kind: kind, value: fields[1], policy: .direct,
                    options: fields.count == 3 ? [.noResolve] : [], raw: line)
                guard let matcher = ConfigurationCompiler.matcher(for: rule) else { throw Failure(message: "Invalid rule expression.") }
                try ConfigurationCompiler.validateExpression(matcher)
                rules.append(rule)
                guard rules.count <= maximumRules else { throw Failure(message: "RULE-SET exceeds 100,000 rules.") }
            } catch { throw Failure(message: "\(source):\(offset + 1): \(error.localizedDescription)") }
        }
        guard !rules.isEmpty else { throw Failure(message: "RULE-SET contains no rules: \(source)") }
        return rules
    }
}
