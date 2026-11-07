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

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        moduleStore.move(fromOffsets: source, toOffset: destination)
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
        subscriptionURL: URL? = nil
    ) throws -> (module: Module, routingSeeds: [UUID: String]) {
        let content = ModuleParser.parse(body)
        let name = content.name.isEmpty ? fallbackName : content.name
        let module = content.makeModule(name: name, subscriptionURL: subscriptionURL)
        try module.validateLimits()
        return (module, content.routingSeeds)
    }

    static func fetchBody(from url: URL) async throws -> String {
        let (data, http) = try await BoundedHTTPFetcher.fetch(url)
        guard (200...299).contains(http.statusCode) else {
            throw ModuleImportError.invalidStatusCode(http.statusCode)
        }
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
        guard let url = moduleStore.module(id: id)?.subscriptionURL else {
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
        let content = ModuleParser.parse(body)

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
        guard current.subscriptionURL == url else { return current }
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
