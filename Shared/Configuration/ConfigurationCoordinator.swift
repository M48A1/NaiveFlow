//
//  ConfigurationCoordinator.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/5/26.
//

import Foundation

// MARK: - Modules

/// One subsystem of the running tunnel that a text document configures.
///
/// These four are the units the engine already reloads one at a time — the
/// routing payload, the DNS resolver with its host table, the MITM rewrite
/// policy, and the outbound side (nodes, groups, TUN settings) — so a document
/// can be reported *per module* instead of as one undifferentiated list of
/// changes. Everything the coordinator says about a document is expressed in
/// these terms, which is what lets the editor and the installer agree without
/// either of them knowing what the other shows.
typealias ConfigurationModule = RuntimeCoordinator.Module

nonisolated extension ConfigurationModule {
    var title: String {
        switch self {
        case .rule: return String(localized: "Rule")
        case .dns: return String(localized: "DNS")
        case .mitm: return String(localized: "MITM")
        case .outbound: return String(localized: "Outbound")
        }
    }

    /// What the module decides, in one line, for the editor's report.
    var summary: String {
        switch self {
        case .rule:
            return String(localized: "Which connection goes where.")
        case .dns:
            return String(localized: "Which servers resolve a name, and the host overrides.")
        case .mitm:
            return String(localized: "Which hosts are intercepted, and by which certificate.")
        case .outbound:
            return String(localized: "Which nodes and groups carry a connection, and how the tunnel is built.")
        }
    }
}


// MARK: - Ownership

nonisolated extension ConfigurationModule {

    /// The `[General]` keys this module owns.
    ///
    /// The table covers `ConfigurationSettings.appliedKeys` exactly — a test
    /// fails when a key is added to the catalog without an owner — so a settings
    /// change is never reported against the wrong module, and the running tunnel
    /// is only told about the subsystems that actually changed.
    ///
    /// Keys marked `applies: false` have no owner on purpose: they never reach
    /// the engine, so nothing has to be reloaded for them.
    static let settingOwners: [String: ConfigurationModule] = [
        // DNS: which servers resolve what, and how names become addresses.
        "bootstrap-dns": .dns,
        "dns-mode": .dns,
        "dns-server": .dns,
        "encrypted-dns-server": .dns,
        "proxy-dns-mode": .dns,
        "proxy-dns-server": .dns,
        "proxy-encrypted-dns-server": .dns,
        "subscription-dns-mode": .dns,
        "subscription-dns-server": .dns,
        "subscription-encrypted-dns-server": .dns,
        "fallback-dns-mode": .dns,
        "fallback-dns-server": .dns,
        "ech-dns-mode": .dns,
        "ech-dns-server": .dns,
        "ech-encrypted-dns-server": .dns,
        "synthetic-address-excluded-suffix": .dns,
        "prevent-dns-leak": .dns,

        // MITM: interception, its certificate and its exceptions.
        "mitm": .mitm,
        "allow-insecure": .mitm,
        "trusted-certificate": .mitm,

        // Rule: the routing payload.
        "bypass-country": .rule,

        // Outbound: nodes, groups, mode, and everything shaping the interface.
        "proxy-mode": .outbound,
        "quic-policy": .outbound,
        "block-udp": .outbound,
        "block-webrtc": .outbound,
        "hide-vpn-icon": .outbound,
        "include-all-networks": .outbound,
        "exclude-local-network": .outbound,
        "include-apns": .outbound,
        "include-cellular-services": .outbound,
        "exclude-device-communication": .outbound,
        "always-on": .outbound,
        "tun-included-routes": .outbound,
        "tun-excluded-routes": .outbound,
        "trusted-ssid": .outbound,
        "always-trust-cellular": .outbound,
        "always-untrust-cellular": .outbound,
        "reflection": .outbound,
        "experimental": .outbound,
    ]

    private static let settingsByModule: [ConfigurationModule: [String]] = {
        var grouped: [ConfigurationModule: [String]] = [:]
        for (name, module) in settingOwners {
            grouped[module, default: []].append(name)
        }
        return grouped.mapValues { $0.sorted() }
    }()

    /// Every `[General]` key this module owns, sorted.
    var settingNames: [String] { Self.settingsByModule[self] ?? [] }

    /// The module a `[General]` key belongs to, or `nil` for a key that never
    /// reaches the engine.
    static func owning(setting name: String) -> ConfigurationModule? {
        settingOwners[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// The module a document section belongs to, read from its header.
    ///
    /// `[General]` answers `nil` because its keys are split between the modules
    /// above; `owning(setting:)` answers those one key at a time.
    static func owning(section name: String?) -> ConfigurationModule? {
        guard let name, let kind = ConfigurationDocument.SectionKind.matching(name) else { return nil }

        switch kind {
        case .proxy, .proxyGroup, .ssidSetting:
            return .outbound
        case .rule, .geoIP, .geoSite:
            return .rule
        case .dns, .host:
            return .dns
        case .mitmSet, .mitm, .script, .urlRewrite, .headerRewrite, .bodyRewrite, .mapLocal, .rewrite:
            // The rewrite sections only do anything while interception is on, and
            // they are loaded together with the MITM policy.
            return .mitm
        case .general, .panel, .misc:
            return nil
        }
    }
}

// MARK: - Coordinator

/// Compiles a text document and reports it in the modules the engine reloads.
///
/// This is the one place that answers, for a document:
/// - does it compile, and what is wrong with it — overall and per module;
/// - which modules it describes, and how much of each;
/// - what activating it costs, module by module;
/// - which notifications the running tunnel has to be told about.
///
/// It holds no state and touches no store: `ConfigurationPublisher` publishes an
/// immutable version, the extension reloads its modules, and this only decides what the
/// answer is. That is also why the editor can run it on every keystroke — it is
/// the same code path a real apply goes through, without the side effects.
nonisolated struct ConfigurationCoordinator: Sendable {

    /// A Darwin notification the host posts to the running tunnel.
    ///
    /// The extension side of the same table lives in `RuntimeCoordinator`, which
    /// maps these names back to the reload work they trigger.
    enum Announcement: String, CaseIterable, Sendable, Hashable {
        /// The `[General]` values changed; the extension re-reads them in place.
        case settings
        /// The MITM policy changed.
        case mitm
        /// The routing payload was rewritten and can be reloaded.
        case routing
        /// A different node list or selection is installed.
        case activeConfiguration

        var name: CFString {
            switch self {
            case .settings: return AWNotificationCenter.Notification.tunnelSettingsChanged
            case .mitm: return AWNotificationCenter.Notification.mitmChanged
            case .routing: return AWNotificationCenter.Notification.routingChanged
            case .activeConfiguration: return AWNotificationCenter.Notification.activeConfigurationChanged
            }
        }

        func post() {
            switch self {
            case .settings: AWNotificationCenter.notifyTunnelSettingsChanged()
            case .mitm: AWNotificationCenter.notifyMITMChanged()
            case .routing: AWNotificationCenter.notifyRoutingChanged()
            case .activeConfiguration: AWNotificationCenter.notifyActiveConfigurationChanged()
            }
        }
    }

    /// What this build can run, so validation reports a supported-but-inert
    /// directive instead of accepting it silently.
    let capabilities: ConfigurationValidator.Capabilities

    init(capabilities: ConfigurationValidator.Capabilities = .current) {
        self.capabilities = capabilities
    }
}

// MARK: - Preparation

nonisolated extension ConfigurationCoordinator {

    /// The single compilation boundary, including syntax diagnostics. A parser
    /// error must never disappear merely because an invalid entry was omitted.
    func compile(text: String, ruleSetContents: [String: String] = [:]) -> TextConfigurationPipeline.Result {
        let parsed = RuleManager.parse(text)
        return TextConfigurationPipeline.Result(
            document: parsed.document,
            parsed: parsed.configuration,
            compiled: ConfigurationCompiler.compile(
                parsed.configuration, capabilities: capabilities,
                parsingDiagnostics: parsed.diagnostics, ruleSetContents: ruleSetContents
            )
        )
    }

    /// What one module gets out of a document.
    struct ModuleReport: Sendable, Equatable, Identifiable {
        let module: ConfigurationModule
        /// `[General]` keys the document sets for this module, sorted.
        let settingNames: [String]
        /// How many items of this module's payload the document declares.
        let payloadCount: Int
        /// What that payload is, e.g. `3 node(s), 1 group(s)`.
        let payloadSummary: String
        /// The diagnostics this module's part of the document produced.
        let diagnostics: [ConfigurationDiagnostic]

        var id: ConfigurationModule { module }
        var errorCount: Int { diagnostics.count { $0.severity == .error } }
        var warningCount: Int { diagnostics.count { $0.severity == .warning } }
        var isEmpty: Bool { settingNames.isEmpty && payloadCount == 0 }

        var summary: String {
            var parts: [String] = []
            if !settingNames.isEmpty { parts.append("\(settingNames.count) setting(s)") }
            if !payloadSummary.isEmpty { parts.append(payloadSummary) }
            return parts.joined(separator: ", ")
        }
    }

    /// A document compiled and reported per module.
    struct Preparation: Sendable {
        /// What the document compiled to.
        let compiled: CompiledConfiguration
        /// One report per module the document actually describes, in the
        /// coordinator's module order.
        let modules: [ModuleReport]
        /// Diagnostics that belong to the document rather than to one module: a
        /// section header, or a key that never reaches the engine.
        let documentDiagnostics: [ConfigurationDiagnostic]

        var diagnostics: [ConfigurationDiagnostic] { compiled.diagnostics }
        var canActivate: Bool { compiled.isActivatable }
        var errorCount: Int { compiled.diagnostics.count { $0.severity == .error } }
        var warningCount: Int { compiled.diagnostics.count { $0.severity == .warning } }
        /// True when the document says nothing about any module.
        var isEmpty: Bool { modules.isEmpty }

        func report(for module: ConfigurationModule) -> ModuleReport? {
            modules.first { $0.module == module }
        }

        /// `Rule, DNS · 2 warning(s)` — one line for the editor.
        var summary: String {
            guard !modules.isEmpty else {
                return String(localized: "The document configures no module.")
            }
            let names = modules.map(\.module.title).joined(separator: ", ")
            if errorCount > 0 {
                return "\(names) · \(errorCount) error(s), \(warningCount) warning(s)."
            }
            if warningCount > 0 {
                return "\(names) · \(warningCount) warning(s)."
            }
            return "\(names)."
        }
    }

    /// Compiles the text and reports it per module.
    func prepare(text: String) -> Preparation {
        prepare(compile(text: text))
    }

    /// Reports a document that was already compiled by the same pipeline.
    func prepare(_ result: TextConfigurationPipeline.Result) -> Preparation {
        prepare(result.compiled)
    }

    /// Reports an already compiled document.
    func prepare(_ compiled: CompiledConfiguration) -> Preparation {
        var diagnosticsByModule: [ConfigurationModule: [ConfigurationDiagnostic]] = [:]
        var documentDiagnostics: [ConfigurationDiagnostic] = []

        for diagnostic in compiled.diagnostics {
            if let module = ConfigurationCoordinator.module(for: diagnostic) {
                diagnosticsByModule[module, default: []].append(diagnostic)
            } else {
                documentDiagnostics.append(diagnostic)
            }
        }

        var reports: [ModuleReport] = []
        for module in ConfigurationModule.allCases {
            let names = module.settingNames.filter { compiled.settings.values[$0] != nil }
            let payload = describePayload(of: compiled, module: module)
            let report = ModuleReport(
                module: module,
                settingNames: names,
                payloadCount: payload.count,
                payloadSummary: payload.summary,
                diagnostics: diagnosticsByModule[module] ?? []
            )
            // A module the document says nothing about is left out: listing all
            // four for every document would say nothing.
            guard !report.isEmpty || !report.diagnostics.isEmpty else { continue }
            reports.append(report)
        }

        return Preparation(compiled: compiled, modules: reports, documentDiagnostics: documentDiagnostics)
    }

    /// Which module a diagnostic belongs to.
    ///
    /// The validator tags every diagnostic with the section it came from, so a
    /// section decides it. `[General]` diagnostics name the key in their message
    /// (`General setting 'loglevel' is recognized but not applied`), which is
    /// looked up in the ownership table; a key with no owner stays with the
    /// document, because nothing reloads for it.
    static func module(for diagnostic: ConfigurationDiagnostic) -> ConfigurationModule? {
        if let module = ConfigurationModule.owning(section: diagnostic.section) {
            return module
        }
        guard let name = settingName(in: diagnostic.message) else { return nil }
        return ConfigurationModule.owning(setting: name)
    }

    /// The quoted name in a diagnostic message, e.g. `loglevel`.
    private static func settingName(in message: String) -> String? {
        guard let open = message.firstIndex(of: "'") else { return nil }
        let rest = message[message.index(after: open)...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<close])
    }

    /// The items a document declares for one module, counted and named.
    ///
    /// Only what a text document can own is counted: nodes, groups, rules and
    /// host overrides. MITM rules are not part of a document — they come from the
    /// MITM rule sets the app manages — so that module reports settings only.
    private func describePayload(
        of compiled: CompiledConfiguration,
        module: ConfigurationModule
    ) -> (count: Int, summary: String) {
        switch module {
        case .outbound:
            let parts = [
                "\(compiled.proxies.count) node(s)",
                "\(compiled.proxyGroups.count) group(s)"
            ]
            return (compiled.proxies.count + compiled.proxyGroups.count, parts.joined(separator: ", "))

        case .rule:
            let count = compiled.orderedRules.count
            let data = compiled.geo.networks.count + compiled.geo.sites.values.reduce(0) { $0 + $1.count }
            return count + data == 0 ? (0, "") : (count + data, "\(count) rule(s), \(data) geo entry/entries")

        case .dns:
            let count = compiled.hosts.count
            return count == 0 ? (0, "") : (count, "\(count) host override(s)")

        case .mitm:
            let count = compiled.textMITM.rules.count + compiled.textMITM.scripts.count + compiled.textMITM.embeddedSets.reduce(0) { $0 + $1.rules.count }
            return (count + compiled.textMITM.suffixes.count, count == 0 ? "" : "\(count) rewrite/script rule(s)")
        }
    }
}

// MARK: - Plans

nonisolated extension ConfigurationCoordinator {

    /// What activating one module costs.
    struct Change: Sendable, Equatable, Identifiable {
        let module: ConfigurationModule
        /// The settings changes this module owns.
        let reload: ConfigurationReloadPlan
        /// Whether the module's payload changed as well.
        let payloadChanged: Bool

        var id: ConfigurationModule { module }
        var isEmpty: Bool { reload.isEmpty && !payloadChanged }
        var scope: ConfigurationReloadPlan.Scope { reload.scope }

        var summary: String {
            var parts: [String] = []
            if !reload.isEmpty { parts.append(reload.summary) }
            if payloadChanged { parts.append(String(localized: "The module's payload changed.")) }
            return parts.isEmpty ? String(localized: "Nothing to do.") : parts.joined(separator: " ")
        }
    }

    /// Everything activating one document costs, grouped by module.
    struct Plan: Sendable, Equatable {
        let changes: [Change]
        /// The `[General]` diff on its own, in the form the editor and the
        /// installer already work with.
        let reload: ConfigurationReloadPlan

        var modules: [ConfigurationModule] { changes.map(\.module) }
        var isEmpty: Bool { changes.isEmpty }
        var requiresReconnect: Bool { reload.requiresReconnect }
        var requiresStackRestart: Bool { reload.requiresStackRestart }

        func change(for module: ConfigurationModule) -> Change? {
            changes.first { $0.module == module }
        }

        /// The notifications the host posts after installing the document.
        ///
        /// Settings and payload changes both participate. The installer publishes
        /// settings after writing them; binary exporters and node publication
        /// post their events only after their respective resources are ready.
        var announcements: [Announcement] {
            var events = ConfigurationCoordinator.announcements(for: reload)
            for change in changes where change.payloadChanged {
                let event: Announcement
                switch change.module {
                case .dns: event = .settings
                case .rule: event = .routing
                case .mitm: event = .mitm
                case .outbound: event = .activeConfiguration
                }
                if !events.contains(event) { events.append(event) }
            }
            return events
        }

        var summary: String {
            guard !changes.isEmpty else {
                return String(localized: "No module has anything to apply.")
            }
            let names = changes.map(\.module.title).joined(separator: ", ")
            guard !reload.isEmpty else {
                return "\(names) · \(String(localized: "The payload changed."))"
            }
            return "\(names) · \(reload.summary)"
        }
    }

    /// What activating `next` changes, module by module.
    ///
    /// - Parameters:
    ///   - previous: what the engine last activated, when the caller knows it.
    ///     `nil` treats nonempty payloads as new. `currentHosts` lets the installer
    ///     compare with the actual shared table, including removing its last entry.
    ///   - next: the document being activated.
    ///   - running: the `[General]` values in use, i.e. the base a settings change
    ///     is measured against. Defaults to the live settings, which is what the
    ///     installer writes over.
    func plan(
        from previous: CompiledConfiguration?,
        to next: CompiledConfiguration,
        running: CompiledSettings = .current(),
        currentHosts: [HostMapping]? = nil
    ) -> Plan {
        let reload = ConfigurationReloadPlan.make(from: running, to: next.settings)

        var changes: [Change] = []
        for module in ConfigurationModule.allCases {
            let owned = reload.changes.filter { ConfigurationModule.owning(setting: $0.field) == module }
            let payloadChanged: Bool
            if module == .dns, let currentHosts {
                payloadChanged = Set(currentHosts) != Set(next.hosts)
            } else if let previous {
                payloadChanged = Self.payloadChanged(from: previous, to: next, module: module)
            } else {
                switch module {
                case .rule: payloadChanged = !next.orderedRules.isEmpty || !next.geo.networks.isEmpty || !next.geo.sites.isEmpty
                case .dns: payloadChanged = !next.hosts.isEmpty
                case .outbound: payloadChanged = !next.proxies.isEmpty || !next.proxyGroups.isEmpty
                case .mitm: payloadChanged = !next.textMITM.suffixes.isEmpty || !next.textMITM.embeddedSets.isEmpty
                }
            }

            guard !owned.isEmpty || payloadChanged else { continue }
            changes.append(
                Change(
                    module: module,
                    reload: ConfigurationReloadPlan(changes: owned),
                    payloadChanged: payloadChanged
                )
            )
        }

        return Plan(changes: changes, reload: reload)
    }
}

// MARK: - Announcements

nonisolated extension ConfigurationCoordinator {

    /// The notifications a settings diff owes the running tunnel.
    ///
    /// Callers that only have the diff — the installer, which writes the new
    /// `[General]` values itself and therefore never plans a document — get the
    /// same announcement set as `Plan.announcements`, instead of growing a
    /// second copy of the rule.
    static func announcements(for reload: ConfigurationReloadPlan) -> [Announcement] {
        guard !reload.isEmpty else { return [] }
        var announcements: [Announcement] = [.settings]
        let touchesMITM = reload.changes.contains {
            ConfigurationModule.owning(setting: $0.field) == .mitm
        }
        if touchesMITM { announcements.append(.mitm) }
        return announcements
    }
}

// MARK: - Announcement Bridge

/// The bridge from the host's announcement vocabulary to the extension's events.
///
/// It lives here rather than in `RuntimeCoordinator` because the extension builds
/// that file without this one: the extension needs to recognize the notifications
/// the host posts, but it does not need — and does not link — the compiler and
/// schema behind `Announcement`. Keeping the conversion on the host side means the
/// extension's table stays a plain list of names, and this direction is where the
/// two are held against each other.
nonisolated extension RuntimeCoordinator.Event {

    /// The event a host announcement asks for.
    ///
    /// `nil` when this build has no counterpart, which the test suite treats as a
    /// contract break rather than something to ignore: the host would post a
    /// notification the running extension silently drops.
    init?(_ announcement: ConfigurationCoordinator.Announcement) {
        self.init(notificationName: announcement.name as String)
    }
}

nonisolated extension RuntimeCoordinator {

    /// The work a host announcement turns into, or `nil` when this build has no
    /// event for it.
    ///
    /// The label is `forAnnouncement` rather than `for` so that a caller holding a
    /// plain `.settings` cannot resolve to the wrong table: both vocabularies have
    /// a case by that name, and an unlabelled overload would make the call site
    /// ambiguous instead of obvious.
    static func plan(forAnnouncement announcement: ConfigurationCoordinator.Announcement) -> Plan? {
        Event(announcement).map(plan(for:))
    }
}

// MARK: - Payload Comparison

nonisolated extension ConfigurationCoordinator {

    /// Whether one module's payload differs between two compiled documents.
    ///
    /// Compared by content, never by identity: every compile mints new node and
    /// group ids (and new timestamps), so ids cannot be compared across
    /// documents. Rule actions are normalized to names and comments/source-line
    /// shifts are ignored, while rule order remains significant.
    static func payloadChanged(
        from previous: CompiledConfiguration,
        to next: CompiledConfiguration,
        module: ConfigurationModule
    ) -> Bool {
        switch module {
        case .rule:
            return previous.geo != next.geo || ruleSignatures(previous) != ruleSignatures(next)
                || actionName(previous.finalAction, in: previous) != actionName(next.finalAction, in: next)
        case .dns:
            return Set(previous.hosts) != Set(next.hosts)
        case .outbound:
            return nodeSignatures(previous) != nodeSignatures(next)
                || groupSignatures(previous) != groupSignatures(next)
        case .mitm:
            // A document carries no MITM rules: they live in the MITM rule sets
            // the app manages, so only `[General]` keys can change here.
            return previous.textMITM.embeddedSignature != next.textMITM.embeddedSignature
                || previous.textMITM.suffixes != next.textMITM.suffixes
                || previous.textMITM.rules.map { $0.operation } != next.textMITM.rules.map { $0.operation }
                || previous.textMITM.rules.map { $0.urlPattern } != next.textMITM.rules.map { $0.urlPattern }
                || previous.textMITM.rules.map { $0.phase } != next.textMITM.rules.map { $0.phase }
                || previous.textMITM.scripts != next.textMITM.scripts
        }
    }

    /// Name, endpoint and protocol per node: what switching to another node list
    /// actually changes.
    private struct NodeSignature: Equatable {
        let name: String
        let address: String
        let port: UInt16
        let outbound: Outbound
        let chain: [NodeSignature]

        init(_ proxy: ProxyConfiguration) {
            name = proxy.name
            address = proxy.serverAddress
            port = proxy.serverPort
            outbound = proxy.outbound
            chain = (proxy.chain ?? []).map(NodeSignature.init)
        }
    }

    private static func nodeSignatures(_ compiled: CompiledConfiguration) -> [NodeSignature] {
        compiled.proxies.map(NodeSignature.init)
    }

    private struct RuleSignature: Equatable {
        let matcher: OrderedRoutingRule.Matcher
        let action: String
        let noResolve: Bool
    }

    private static func ruleSignatures(_ compiled: CompiledConfiguration) -> [RuleSignature] {
        compiled.orderedRules.map {
            RuleSignature(matcher: $0.matcher, action: actionName($0.action, in: compiled), noResolve: $0.noResolve)
        }
    }

    private static func actionName(_ action: RouteMatchAction, in compiled: CompiledConfiguration) -> String {
        switch action {
        case .direct: return "builtin:direct"
        case .reject: return "builtin:reject"
        case .defaultProxy: return "builtin:proxy"
        case .proxy(let id):
            return "node:" + (compiled.proxies.first { $0.id == id }?.name ?? id.uuidString)
        }
    }

    /// Name, kind and members per group, with members resolved through the same
    /// document's nodes so ids never leak into the comparison.
    private static func groupSignatures(_ compiled: CompiledConfiguration) -> [String] {
        let names = Dictionary(
            compiled.proxies.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return compiled.proxyGroups.map { group in
            let members = group.memberIds.compactMap { names[$0] }.joined(separator: ",")
            return [group.name, group.kind.rawValue, members].joined(separator: "|")
        }
    }
}


