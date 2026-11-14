import Foundation

@MainActor
enum ModuleImporter {
    static func makeModule(
        from body: String,
        fallbackName: String,
        subscriptionURL: URL? = nil,
        format: ModuleFormat,
        resourceBaseURL: URL? = nil,
        fetchResource: (@MainActor (URL) async throws -> String)? = nil
    ) async throws -> (module: Module, routingSeeds: [UUID: String], warnings: [String]) {
        let parsed = ModuleParser.parse(body, format: format)
        let content = try await resolveContent(parsed, baseURL: resourceBaseURL ?? subscriptionURL, fetchResource: fetchResource)
        let name = content.name.isEmpty ? fallbackName : content.name
        var module = content.makeModule(name: name, subscriptionURL: subscriptionURL)
        module.sourceFormat = format
        try module.validateLimits()
        return (module, content.routingSeeds, parsed.warnings)
    }

    private static func resolveContent(
        _ parsed: (content: ModuleContent, warnings: [String], resources: [ForeignMITMImporter.Resource]),
        baseURL: URL?,
        fetchResource: (@MainActor (URL) async throws -> String)?
    ) async throws -> ModuleContent {
        guard parsed.warnings.isEmpty else {
            throw RuntimeConfigurationFailure.rejected(parsed.warnings.joined(separator: "\n"))
        }
        var content = parsed.content
        guard content.mitmRuleSets.allSatisfy({ $0.rules.isEmpty || !$0.domainSuffixes.isEmpty }) else {
            throw RuntimeConfigurationFailure.rejected("Scripts require MITM hostnames in the module.")
        }
        guard !parsed.resources.isEmpty else { return content }
        guard !content.mitmRuleSets.isEmpty else { throw ModuleImportError.empty }
        guard parsed.resources.count <= ModuleMITMRuleSet.maxRuleCount else { throw ModuleImportError.tooLarge }
        var cache: [URL: Data] = [:]
        var validatedScripts: Set<URL> = []
        var fetchedBytes = 0
        var expandedBytes = 0
        for resource in parsed.resources {
            try Task.checkCancellation()
            guard let url = URL(string: resource.source, relativeTo: baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty else {
                throw RuntimeConfigurationFailure.rejected("Invalid script or resource URL: \(resource.source)")
            }
            let resourceData: Data
            if let cached = cache[url] { resourceData = cached }
            else {
                if let fetchResource { resourceData = Data(try await fetchResource(url).utf8) }
                else { resourceData = try await Self.fetchData(from: url) }
                guard resourceData.count <= 4 * 1024 * 1024 else { throw ModuleImportError.tooLarge }
                fetchedBytes += resourceData.count
                guard fetchedBytes <= 16 * 1024 * 1024 else { throw ModuleImportError.tooLarge }
                cache[url] = resourceData
            }
            var rule = content.mitmRuleSets[0].rules[resource.ruleIndex]
            let source: String
            switch resource.kind {
            case .script(let argument, let binary, let requiresBody, let maxSize, let timeout, let name):
                guard let body = String(data: resourceData, encoding: .utf8) else { throw ModuleImportError.undecodableBody }
                if argument?.contains("{{{") == true {
                    throw RuntimeConfigurationFailure.rejected("Unresolved script argument: \(name)")
                }
                if validatedScripts.insert(url).inserted { try RuntimeJavaScript.validate(body) }
                func json<T: Encodable>(_ value: T) throws -> String {
                    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                }
                var prefix = "globalThis.$script = {name: \(try json(name)), startTime: Date.now()/1000, binaryBodyMode: \(binary)};\n"
                if let timeout { prefix = ForeignScriptContext.timeoutPrefix + String(timeout) + "\n" + prefix }
                if !requiresBody, !binary { prefix += ForeignScriptContext.headerOnlyMarker + "\n" }
                if let argument { prefix += "globalThis.$argument = \(try json(argument));\n" }
                let target = rule.phase == .httpRequest ? "$request" : "$response"
                if let maxSize, maxSize >= 0 {
                    prefix += "if (\(target).bodyBytes && \(target).bodyBytes.byteLength > \(maxSize)) { $done({}); return; }\n"
                }
                if binary { prefix += "\(target).body = \(target).bodyBytes;\n" }
                else if !requiresBody { prefix += "delete \(target).body; delete \(target).bodyBytes;\n" }
                source = prefix + ModuleScriptArchive.sourceMarker + body
            case .response(let status, let headers):
                source = ForeignMITMImporter.responseScript(data: resourceData, status: status, headers: headers, dialect: contentFormat(for: rule))
            }
            expandedBytes += source.utf8.count
            guard source.utf8.count <= RuntimeJavaScript.maximumScriptBytes,
                  expandedBytes <= ModuleScriptArchive.maximumExpandedBytes else { throw ModuleImportError.tooLarge }
            let dialect: MITMScriptDialect = contentFormat(for: rule)
            rule.operation = .script(scriptBase64: Data(source.utf8).base64EncodedString(), dialect: dialect)
            content.mitmRuleSets[0].rules[resource.ruleIndex] = rule
        }
        return content
    }

    private static func contentFormat(for rule: MITMRule) -> MITMScriptDialect {
        if case .script(_, let dialect) = rule.operation { return dialect }
        return .surge
    }

    private static func fetchData(from url: URL) async throws -> Data {
        let (data, http) = try await BoundedHTTPFetcher.fetch(url, maxBytes: 4 * 1024 * 1024)
        guard (200...299).contains(http.statusCode) else {
            throw ModuleImportError.invalidStatusCode(http.statusCode)
        }
        return data
    }

    static func fallbackName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? "Subscription" : base
    }

}
