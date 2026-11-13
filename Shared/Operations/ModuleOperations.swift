//
//  ModuleOperations.swift
//  NaiveFlow
//
//  Created by NodePassProject on 10/9/26.
//

import Foundation

@MainActor
struct ModuleOperations {
    let moduleStore: ModuleStore
    let routingExportScheduler: RoutingExportScheduler
    let mitmExportScheduler: MITMExportScheduler
    /// Shared per-module refresh coordination so a slow fetch cannot overwrite a
    /// newer one. Defaulted so existing call sites/tests keep a private instance.
    var coordinator = RefreshTicketCoordinator<UUID>()
    /// Injectable fetch seam for tests; production uses the bounded downloader.
    var fetchBodyOverride: (@MainActor (URL) async throws -> String)? = nil

    // MARK: - Modules

    func add(_ module: Module, routingSeeds: [UUID: String] = [:]) {
        moduleStore.add(module, routingSeeds: routingSeeds)
        exportAll()
    }

    @discardableResult
    func addEmpty(name: String) -> Module {
        let module = Module(name: name)
        moduleStore.add(module)
        return module
    }

    func remove(id: UUID) {
        moduleStore.remove(id: id)
        exportAll()
    }

    func remove(atOffsets offsets: IndexSet) {
        moduleStore.remove(atOffsets: offsets)
        exportAll()
    }

    func move(in format: ModuleFormat, fromOffsets source: IndexSet, toOffset destination: Int) {
        moduleStore.move(in: format, fromOffsets: source, toOffset: destination)
        exportAll()
    }

    func rename(id: UUID, name: String) {
        moduleStore.rename(id: id, name: name)
        exportAll()
    }

    func setEnabled(id: UUID, enabled: Bool) {
        moduleStore.setEnabled(id: id, enabled: enabled)
        exportAll()
    }

    // MARK: - Routing rule sets

    @discardableResult
    func addRoutingRuleSet(name: String, to moduleId: UUID) -> ModuleRoutingRuleSet {
        let ruleSet = ModuleRoutingRuleSet(name: name)
        moduleStore.addRoutingRuleSet(ruleSet, to: moduleId)
        return ruleSet
    }

    func updateRoutingRuleSet(_ ruleSetId: UUID, in moduleId: UUID, name: String? = nil, rules: [RoutingRule]? = nil) {
        moduleStore.updateRoutingRuleSet(ruleSetId, in: moduleId, name: name, rules: rules)
        routingExportScheduler.schedule()
    }

    func removeRoutingRuleSets(atOffsets offsets: IndexSet, in moduleId: UUID) {
        moduleStore.removeRoutingRuleSets(atOffsets: offsets, in: moduleId)
        routingExportScheduler.schedule()
    }

    func moveRoutingRuleSets(fromOffsets source: IndexSet, toOffset destination: Int, in moduleId: UUID) {
        moduleStore.moveRoutingRuleSets(fromOffsets: source, toOffset: destination, in: moduleId)
        routingExportScheduler.schedule()
    }

    func setRoutingRuleSetAssignment(_ configurationId: String?, for ruleSetId: UUID) {
        moduleStore.setAssignment(configurationId, for: ruleSetId)
        routingExportScheduler.schedule()
    }

    // MARK: - MITM rule sets

    @discardableResult
    func addMITMRuleSet(name: String, to moduleId: UUID) -> ModuleMITMRuleSet {
        let ruleSet = ModuleMITMRuleSet(name: name)
        moduleStore.addMITMRuleSet(ruleSet, to: moduleId)
        return ruleSet
    }

    func updateMITMRuleSet(_ ruleSetId: UUID, in moduleId: UUID, domainSuffixes: [String], rules: [MITMRule]) {
        moduleStore.updateMITMRuleSet(ruleSetId, in: moduleId, domainSuffixes: domainSuffixes, rules: rules)
        mitmExportScheduler.schedule()
    }

    func setMITMRuleSet(_ ruleSetId: UUID, in moduleId: UUID, enabled: Bool) {
        moduleStore.setMITMRuleSet(ruleSetId, in: moduleId, enabled: enabled)
        mitmExportScheduler.schedule()
    }

    func setMITMParameterValue(in moduleId: UUID, name: String, value: String) {
        moduleStore.setMITMParameterValue(in: moduleId, name: name, value: value)
        mitmExportScheduler.schedule()
    }

    func removeMITMRuleSets(atOffsets offsets: IndexSet, in moduleId: UUID) {
        moduleStore.removeMITMRuleSets(atOffsets: offsets, in: moduleId)
        mitmExportScheduler.schedule()
    }

    func moveMITMRuleSets(fromOffsets source: IndexSet, toOffset destination: Int, in moduleId: UUID) {
        moduleStore.moveMITMRuleSets(fromOffsets: source, toOffset: destination, in: moduleId)
        mitmExportScheduler.schedule()
    }

    // MARK: - Import
    
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

    static func fetchBody(from url: URL) async throws -> String {
        let data = try await fetchData(from: url)
        guard let body = String(data: data, encoding: .utf8) else {
            throw ModuleImportError.undecodableBody
        }
        return body
    }

    static func fallbackName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        return base.isEmpty ? "Subscription" : base
    }

    // MARK: - Subscription Refresh

    @discardableResult
    func refresh(id: UUID) async throws -> Module {
        guard let source = moduleStore.module(id: id), let url = source.subscriptionURL else {
            throw ModuleImportError.missingSubscriptionURL
        }
        let ticket = coordinator.begin(id)
        defer { coordinator.end(id, ticket: ticket) }

        let body: String
        if let fetchBodyOverride {
            body = try await fetchBodyOverride(url)
        } else {
            body = try await Self.fetchBody(from: url)
        }
        let parsed = ModuleParser.parse(body, format: source.sourceFormat)
        let content = try await Self.resolveContent(parsed, baseURL: url, fetchResource: fetchBodyOverride)

        // A superseded refresh must not overwrite newer content; hand back the
        // current module unchanged instead of committing this stale response.
        guard coordinator.isCurrent(id, ticket: ticket) else {
            guard let current = moduleStore.module(id: id) else {
                throw ModuleImportError.moduleRemoved
            }
            return current
        }
        guard let current = moduleStore.module(id: id) else {
            throw ModuleImportError.moduleRemoved
        }
        // The source may have been re-pointed while this request was in flight;
        // drop the commit rather than apply content from the old URL.
        guard current.subscriptionURL == url, current.sourceFormat == source.sourceFormat else { return current }
        try content.makeModule(name: current.name, subscriptionURL: url).validateLimits()
        guard let updated = moduleStore.applyRefreshedContent(content, to: id) else {
            throw ModuleImportError.moduleRemoved
        }
        exportAll()
        return updated
    }

    private func exportAll() {
        routingExportScheduler.schedule()
        mitmExportScheduler.schedule()
    }
}
