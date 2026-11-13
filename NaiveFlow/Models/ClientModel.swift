import Foundation
import Observation

@MainActor
@Observable
final class ClientModel {
    private(set) var library = ClientProfileLibrary()
    private(set) var parsed = NaiveFlowConfigurationParser.parse(text: "").configuration
    private(set) var nodes: [ProxyConfiguration] = []
    private(set) var isBusy = false
    private(set) var hasApplied = false
    private(set) var liveGroups: [String: PolicyGroupsResponse.Group] = [:]
    var error: String?
    var message: String?
    @ObservationIgnored let operations: Operations
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let documentOverride: ConfigurationDocumentOperations?
    var document: ConfigurationDocumentOperations { documentOverride ?? operations.configurationDocument }
    @ObservationIgnored private var lastActiveText: String?

    init(operations: Operations, directory: URL = ClientProfileLibrary.directory, document: ConfigurationDocumentOperations? = nil) {
        self.documentOverride = document
        self.operations = operations
        self.directory = directory
        do { library = try ClientProfileLibrary.load(from: directory) }
        catch { self.error = "无法读取配置列表：\(error.localizedDescription)" }
        let active = self.document.activation.active
        if library.profiles.isEmpty {
            let profile = ClientProfile(name: "默认配置", text: active?.text ?? self.document.draft())
            library.profiles = [profile]
            library.selectedID = profile.id
        }
        if !library.profiles.contains(where: { $0.id == library.selectedID }) { library.selectedID = library.profiles.first?.id }
        refresh()
    }

    var profile: ClientProfile? { library.profiles.first { $0.id == library.selectedID } }
    var groups: [ParsedProxyGroup] { parsed.proxyGroups }
    var mode: ProxyMode { ProxyMode(rawValue: parsed.general["proxy-mode"] ?? "rule") ?? .rule }
    var selectedNodeName: String { parsed.general["default-node"] ?? self.document.selection?.effectiveConfiguration?.name ?? nodes.first?.name ?? "未选择节点" }
    var modules: [ClientModule] {
        (profile?.modules ?? []).map { source in
            var module = source
            let sets = source.setKeys.compactMap { key -> MITMRuleSet? in
                guard let encoded = parsed.mitmSets[key], encoded.hasPrefix("base64:"),
                      let data = Data(base64Encoded: String(encoded.dropFirst(7))) else { return nil }
                return try? JSONDecoder().decode(MITMRuleSet.self, from: data)
            }
            module.enabled = !sets.isEmpty && sets.allSatisfy(\.enabled)
            return module
        }
    }
    var activeName: String { profile?.name ?? "我的配置" }

    func refresh() {
        let active = self.document.activation.active
        hasApplied = self.document.selection?.usesRuntimeVersion == true
        if let active { lastActiveText = active.text }
        rebuild()
    }

    var operatingText: String { hasApplied ? lastActiveText ?? profile?.text ?? "" : profile?.text ?? "" }

    private func rebuild() {
        let result = TextConfigurationPipeline.process(text: operatingText)
        parsed = result.parsed
        let previous = nodes
        nodes = result.compiled.proxies.map { candidate in previous.first { $0.name == candidate.name && $0.toURLString() == candidate.toURLString() } ?? candidate }
    }

    private func persist() throws { try library.save(to: directory) }
    func report(_ error: Error) { self.error = error.localizedDescription }

    func createProfile(name: String = "新建配置", text: String? = nil, sourceURL: String? = nil) -> ClientProfile {
        let profile = ClientProfile(name: name, text: text ?? TextConfigurationPipeline.template, sourceURL: sourceURL)
        library.profiles.append(profile)
        do { try persist() } catch { report(error) }
        return profile
    }

    @discardableResult
    func saveProfile(_ candidate: ClientProfile, apply: Bool) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            var saved = candidate
            saved.updatedAt = .now
            if apply {
                _ = try await self.document.apply(saved.text)
                liveGroups = [:]
                library.selectedID = saved.id
                lastActiveText = saved.text
                hasApplied = true
            }
            if let index = library.profiles.firstIndex(where: { $0.id == saved.id }) { library.profiles[index] = saved }
            else { library.profiles.append(saved) }
            try persist()
            rebuild()
            message = apply ? "已应用 \(saved.name)" : "配置已保存"
            return true
        } catch { report(error); return false }
    }

    func activate(_ profile: ClientProfile) async { _ = await saveProfile(profile, apply: true) }

    func deleteProfile(_ id: UUID) {
        guard id != library.selectedID else { error = "请先切换到其他配置，再删除当前配置。"; return }
        library.profiles.removeAll { $0.id == id }
        do { try persist() } catch { report(error) }
    }

    func updateProfile(_ profile: ClientProfile) async {
        guard let source = profile.sourceURL else { return }
        do {
            var candidate = profile
            candidate.text = try await fetchText(source)
            _ = await saveProfile(candidate, apply: profile.id == library.selectedID && hasApplied)
        } catch { report(error) }
    }

    func fetchText(_ source: String) async throws -> String {
        guard let url = URL(string: source), url.scheme?.lowercased() == "https", url.host != nil else {
            throw ClientFailure("请输入有效的 HTTPS 地址。")
        }
        let (data, response) = try await BoundedHTTPFetcher.fetch(url, maxBytes: ConfigurationImport.maximumBytes)
        guard (200...299).contains(response.statusCode), response.url?.scheme?.lowercased() == "https",
              let text = String(data: data, encoding: .utf8) else { throw ClientFailure("下载失败或文件不是 UTF-8 文本。") }
        return ConfigurationImport.normalize(text)
    }

    @discardableResult
    func commit(_ text: String, moduleUpdate: [ClientModule]? = nil, styles: [String: ClientGroupStyle]? = nil) async -> Bool {
        guard var candidate = profile else { return false }
        candidate.text = text
        if let moduleUpdate { candidate.modules = moduleUpdate }
        if let styles { candidate.groupStyles = styles }
        return await saveProfile(candidate, apply: true)
    }

    func setSetting(_ key: String, value: String, section: ConfigurationDocument.SectionKind = .general) async {
        guard profile != nil else { return }
        let text = operatingText
        _ = await commit(ClientDocumentEditing.set(text, section: section, key: key, value: value))
    }

    func selectNode(_ name: String) async { await setSetting("default-node", value: ClientDocumentEditing.token(name)) }

    func selectMember(_ member: String, in group: ParsedProxyGroup) async {
        let parameters = group.parameters.pairs.filter { $0.0 != "selected" } + [("selected", member)]
        // A manual choice is explicit Select; automatic groups retain their strategy until edited.
        let value = ClientDocumentEditing.groupValue(kind: "select", members: group.members, parameters: parameters.filter { !["interval", "url", "tolerance"].contains($0.0) })
        guard profile != nil else { return }
        let text = operatingText
        _ = await commit(ClientDocumentEditing.set(text, section: .proxyGroup, key: group.name, value: value))
    }

    func selectedMember(in group: ParsedProxyGroup) -> String {
        if group.kind != .select, let live = liveGroups[group.name]?.nextMember {
            return group.kind == .loadBalance ? "轮询 · " + live : live
        }
        if group.kind == .select { return group.parameters["selected"] ?? group.members.first ?? "无成员" }
        switch group.kind {
        case .urlTest: return "自动选择 · 延迟优先"
        case .fallback: return "自动选择 · 故障转移"
        case .loadBalance: return "自动选择 · 负载均衡"
        default: return group.members.first ?? "无成员"
        }
    }

    func pollPolicyStatus() async {
        guard let tunnel = document.tunnel, tunnel.hasRunningTunnel,
              let data = await tunnel.send(.fetchPolicyGroups),
              let response = try? JSONDecoder().decode(PolicyGroupsResponse.self, from: data),
              let head = try? RuntimeBundleStore(directory: document.activation.store.directory.appendingPathComponent("runtime-v2")).head(),
              response.versionID == head.current else { liveGroups = [:]; return }
        liveGroups = Dictionary(response.groups.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func renameReferences(_ text: String, from old: String, to new: String) -> String {
        guard old != new else { return text }
        let parsed = NaiveFlowConfigurationParser.parse(text: text).configuration
        var result = text
        for group in parsed.proxyGroups {
            var parameters = group.parameters.pairs
            if parameters.contains(where: { $0.0 == "selected" && $0.1 == old }) {
                parameters = parameters.map { $0.0 == "selected" && $0.1 == old ? ($0.0, new) : $0 }
            }
            if group.members.contains(old) || group.parameters["selected"] == old {
                result = ClientDocumentEditing.set(result, section: .proxyGroup, key: group.name,
                    value: ClientDocumentEditing.groupValue(kind: group.kindToken, members: group.members.map { $0 == old ? new : $0 }, parameters: parameters))
            }
        }
        var document = ConfigurationDocument.parse(text: result)
        let rules = NaiveFlowConfigurationParser.parse(text: result).configuration.rules
        for rule in rules where rule.policy == .named(old) {
            let parts = ConfigurationDocument.splitExpression(rule.raw)
            var updated = parts
            let policyIndex = rule.isFinal ? 1 : 2
            if updated.indices.contains(policyIndex) { updated[policyIndex] = ClientDocumentEditing.token(new) }
            let comment = document.line(rule.line)?.comment.map { "  # " + $0 } ?? ""
            document = document.replacingLine(rule.line, with: updated.joined(separator: ", ") + comment)
        }
        result = document.text
        for chain in parsed.chains where chain.members.contains(old) {
            result = ClientDocumentEditing.set(result, section: .chain, key: chain.name,
                value: chain.members.map { ClientDocumentEditing.token($0 == old ? new : $0) }.joined(separator: ", "))
        }
        if parsed.general["default-node"] == old { result = ClientDocumentEditing.set(result, section: .general, key: "default-node", value: ClientDocumentEditing.token(new)) }
        return result
    }

    @discardableResult
    func importNodes(_ source: String) async throws -> Bool {
        let result = TextConfigurationPipeline.process(text: source)
        let imported = !result.compiled.proxies.isEmpty ? result.compiled.proxies
            : try SubscriptionFetcher.parseLocal(data: Data(source.utf8)).configurations
        guard !imported.isEmpty else { throw ClientFailure("没有找到可用节点。") }
        var text = operatingText
        for node in imported {
            text = ClientDocumentEditing.set(text, section: .proxy, key: node.name, value: node.isDirect ? "direct" : node.toURLString())
        }
        return await commit(text)
    }

    func saveNode(_ node: ProxyConfiguration, replacing old: String? = nil) async {
        guard profile != nil else { return }
        var text = operatingText
        if let old, old != node.name {
            guard !nodes.contains(where: { $0.name == node.name }) else { error = "节点名称已存在。"; return }
            text = renameReferences(text, from: old, to: node.name)
            text = ClientDocumentEditing.renameKey(text, section: .proxy, from: old, to: node.name)
        }
        text = ClientDocumentEditing.set(text, section: .proxy, key: node.name, value: node.isDirect ? "direct" : node.toURLString())
        _ = await commit(text)
    }

    func deleteNode(_ name: String) async {
        guard profile != nil else { return }
        var text = operatingText
        if parsed.rules.contains(where: { $0.policy == .named(name) }) || parsed.chains.contains(where: { $0.members.contains(name) }) {
            error = "这个节点仍被规则或代理链引用，请先在配置中修改这些引用。"; return
        }
        text = ClientDocumentEditing.set(text, section: .proxy, key: name, value: nil)
        for group in groups where group.members.contains(name) {
            let members = group.members.filter { $0 != name }
            guard !members.isEmpty else { error = "\(group.name) 至少需要一个成员。"; return }
            let parameters = group.parameters.pairs.filter { !($0.0 == "selected" && $0.1 == name) }
            text = ClientDocumentEditing.set(text, section: .proxyGroup, key: group.name,
                value: ClientDocumentEditing.groupValue(kind: group.kindToken, members: members, parameters: parameters))
        }
        if parsed.general["default-node"] == name { text = ClientDocumentEditing.set(text, section: .general, key: "default-node", value: nil) }
        _ = await commit(text)
    }

    func reorderNodes(_ names: [String]) async {
        guard profile != nil else { return }
        let text = operatingText
        _ = await commit(ClientDocumentEditing.reorder(text, section: .proxy, keys: names))
    }

    func saveGroup(original: String?, name: String, kind: String, members: [String], parameters: [(String,String)], style: ClientGroupStyle) async -> Bool {
        guard profile != nil else { return false }
        var text = operatingText
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !members.isEmpty else { error = "请输入名称并选择至少一个成员。"; return false }
        if original != name, groups.contains(where: { $0.name == name }) { error = "策略组名称已存在。"; return false }
        var styles = profile?.groupStyles ?? [:]
        if let original, original != name {
            text = renameReferences(text, from: original, to: name)
            text = ClientDocumentEditing.renameKey(text, section: .proxyGroup, from: original, to: name)
            styles.removeValue(forKey: original)
        }
        text = ClientDocumentEditing.set(text, section: .proxyGroup, key: name,
            value: ClientDocumentEditing.groupValue(kind: kind, members: members, parameters: parameters))
        styles[name] = style
        return await commit(text, styles: styles)
    }

    func deleteGroup(_ name: String) async {
        guard profile != nil else { return }
        let text = operatingText
        if groups.contains(where: { $0.members.contains(name) }) || parsed.rules.contains(where: { $0.policy == .named(name) }) {
            error = "策略组仍被规则或其他组引用，请先修改相关引用。"; return
        }
        var styles = profile?.groupStyles ?? [:]
        styles.removeValue(forKey: name)
        _ = await commit(ClientDocumentEditing.set(text, section: .proxyGroup, key: name, value: nil), styles: styles)
    }

    func reorderGroups(_ names: [String]) async {
        guard profile != nil else { return }
        let text = operatingText
        _ = await commit(ClientDocumentEditing.reorder(text, section: .proxyGroup, keys: names))
    }

    func saveModule(_ candidate: ClientModule) async -> Bool {
        guard profile != nil else { return false }
        let profileID = profile?.id
        do {
            let made = try await ModuleImporter.makeModule(from: candidate.source, fallbackName: candidate.name,
                subscriptionURL: candidate.sourceURL.flatMap(URL.init(string:)), format: candidate.format)
            guard !made.module.mitmRuleSets.isEmpty else { throw ClientFailure("模块没有可用的 MITM 规则。") }
            guard profile?.id == profileID else { throw ClientFailure("当前配置已切换，请在目标配置中重新保存模块。") }
            var text = operatingText
            var saved = candidate
            saved.summary = candidate.summary.isEmpty ? made.module.description ?? "" : candidate.summary
            for key in candidate.setKeys { text = ClientDocumentEditing.set(text, section: .mitmSet, key: key, value: nil) }
            saved.setKeys = []
            for (index, raw) in made.module.mitmRuleSets.enumerated() {
                var set = raw.asMITMRuleSet()
                set.id = UUID() // scope identity belongs to this publication, not an old module store
                set.enabled = candidate.enabled
                let key = "module_\(candidate.id.uuidString.replacingOccurrences(of: "-", with: ""))_\(index)"
                let value = "base64:" + (try JSONEncoder().encode(set)).base64EncodedString()
                text = ClientDocumentEditing.set(text, section: .mitmSet, key: key, value: value)
                saved.setKeys.append(key)
            }
            var modules = self.modules.filter { $0.id != candidate.id }
            modules.append(saved)
            return await commit(text, moduleUpdate: modules)
        } catch { report(error); return false }
    }

    func toggleModule(_ module: ClientModule, enabled: Bool) async {
        guard profile != nil else { return }
        var text = operatingText
        do {
            for key in module.setKeys {
                guard let encoded = parsed.mitmSets[key], encoded.hasPrefix("base64:"), let data = Data(base64Encoded: String(encoded.dropFirst(7))) else { throw ClientFailure("找不到模块规则，请重新保存模块。") }
                var set = try JSONDecoder().decode(MITMRuleSet.self, from: data)
                set.enabled = enabled
                text = ClientDocumentEditing.set(text, section: .mitmSet, key: key, value: "base64:" + (try JSONEncoder().encode(set)).base64EncodedString())
            }
            var modules = self.modules
            if let index = modules.firstIndex(where: { $0.id == module.id }) { modules[index].enabled = enabled }
            _ = await commit(text, moduleUpdate: modules)
        } catch { report(error) }
    }

    func deleteModule(_ module: ClientModule) async {
        guard profile != nil else { return }
        var text = operatingText
        for key in module.setKeys { text = ClientDocumentEditing.set(text, section: .mitmSet, key: key, value: nil) }
        _ = await commit(text, moduleUpdate: modules.filter { $0.id != module.id })
    }

    func refreshModule(_ module: ClientModule) async {
        guard let url = module.sourceURL else { return }
        do { var updated = module; updated.source = try await fetchText(url); _ = await saveModule(updated) }
        catch { report(error) }
    }
}

nonisolated struct ClientFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
