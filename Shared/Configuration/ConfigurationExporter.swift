//
//  ConfigurationExporter.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// What the app currently holds, in the shapes a text configuration can express.
///
/// Gathering and rendering are two separate steps on purpose: the store-based
/// initializer lives in `ConfigurationExporter+Stores.swift` and this type is a
/// plain value, so the round trip can be tested without a sync store.
nonisolated struct ConfigurationExportSource: Sendable, Equatable {

    struct Proxy: Sendable, Equatable {
        /// Name shown in the app.
        var name: String
        /// Shareable link, as produced by `ProxyConfiguration.toURLString()`.
        var url: String
    }

    struct Group: Sendable, Equatable {
        var name: String
        /// Members by name, resolved against the exported proxies and groups.
        var members: [String]
    }

    struct RuleSet: Sendable, Equatable {
        var name: String
        /// `nil` when nothing is assigned: the engine still matches those rules
        /// but falls through to the next rule set, which a text document cannot
        /// say. Such a set is reported instead of being given a policy it never
        /// had.
        var policy: String?
        var rules: [RoutingRule]
    }

    struct Setting: Sendable, Equatable {
        var key: String
        var value: String
    }

    var proxies: [Proxy]
    var groups: [Group]
    var ruleSets: [RuleSet]
    var hosts: [HostMapping]
    /// `[General]` entries, in emission order.
    var settings: [Setting]
    var mitmEnabled: Bool
    /// MITM host patterns, without the `%APPEND%` marker.
    var mitmHostnames: [String]
    var mitmRuleSets: [MITMRuleSet]
    /// What the app holds but the text format cannot express.
    var notes: [String]

    init(
        proxies: [Proxy] = [],
        groups: [Group] = [],
        ruleSets: [RuleSet] = [],
        hosts: [HostMapping] = [],
        settings: [Setting] = [],
        mitmEnabled: Bool = false,
        mitmHostnames: [String] = [],
        mitmRuleSets: [MITMRuleSet] = [],
        notes: [String] = []
    ) {
        self.proxies = proxies
        self.groups = groups
        self.ruleSets = ruleSets
        self.hosts = hosts
        self.settings = settings
        self.mitmEnabled = mitmEnabled
        self.mitmHostnames = mitmHostnames
        self.mitmRuleSets = mitmRuleSets
        self.notes = notes
    }
}

/// Renders the app's current configuration as a text document.
///
/// This is the direction that did not exist yet: `NaiveFlowConfigurationParser` and
/// `ConfigurationCompiler` read a document into the app's stores, this writes
/// the app's stores back out. Two rules keep it honest:
///
/// - Only what the engine can act on is emitted. A group member that would be
///   dropped, an unassigned rule set, a chain, a module's rule set — each is
///   reported in `Result.notes` instead of being silently invented.
/// - The result must survive `TextConfigurationPipeline.process(text:)` without
///   errors. `ConfigurationExporterTests` asserts exactly that, so an export
///   that drifts away from the parser fails a test rather than a user.
///
/// The output is NaiveFlow sectioned text: exactly the section names and rule tokens
/// `NaiveFlowConfigurationParser` reads, so an exported document can be imported
/// back into this app. No section is generated that the parser keeps but the
/// engine does not act on (`[Script]`, `[URL Rewrite]`, `[Header Rewrite]`), and
/// none for data the stores do not hold.
nonisolated enum ConfigurationExporter {

    struct Options: Sendable {
        /// Policy of the generated `FINAL` rule.
        var finalPolicy: String = "PROXY"
        /// Emit `# <rule set> -> <policy>` above each rule set's rules.
        var includeRuleSetComments: Bool = true
        /// Emit the generated banner at the top of the document.
        var includeBanner: Bool = true
        /// Export the supported MITM enable switch; report external host policies.
        var includeMITM: Bool = true

        init(
            finalPolicy: String = "PROXY",
            includeRuleSetComments: Bool = true,
            includeBanner: Bool = true,
            includeMITM: Bool = true
        ) {
            self.finalPolicy = finalPolicy
            self.includeRuleSetComments = includeRuleSetComments
            self.includeBanner = includeBanner
            self.includeMITM = includeMITM
        }
    }

    struct Counts: Sendable, Equatable {
        var proxies = 0
        var groups = 0
        var rules = 0
        var hosts = 0
        /// Rule sets whose rules are not in the document; the reason is in
        /// `Result.notes`.
        var skippedRuleSets: [String] = []
    }

    struct Result: Sendable, Equatable {
        let text: String
        /// Everything the document could not carry, plus the source's own notes.
        let notes: [String]
        let counts: Counts
    }

    static let banner = """
        # NaiveFlow configuration
        #
        # Generated from the app's current settings. Edit it here from now on:
        # [General]      proxy-mode / quic-policy / tunnel flags / DNS upstreams
        # [Proxy]        Name = <share link>
        # [Proxy Group]  Name = select, Member, Member
        # [Rule]         DOMAIN-SUFFIX, example.com, DIRECT
        # [Host]         host = address
        # MITM sets use the native encoded section to preserve every operation and parameter.
        """
}

// MARK: - Export

nonisolated extension ConfigurationExporter {

    static func export(
        _ source: ConfigurationExportSource,
        options: Options = Options()
    ) -> Result {
        var state = State(source: source, options: options)
        state.emitNodes()
        state.emitGroups()
        state.emitRules()
        state.emitHosts()
        state.emitSettings()
        state.emitMITM()
        return state.result()
    }
}

/// Accumulates the document one section at a time.
///
/// Sections are built in dependency order — nodes, then groups (which reference
/// nodes), then rules (which reference both) — so every name a later section
/// uses is already final, including any rename the exporter had to make.
private nonisolated struct State {
    let source: ConfigurationExportSource
    let options: ConfigurationExporter.Options

    var notes: [String]
    var counts = ConfigurationExporter.Counts()
    var used = Set<String>()
    var renames: [String: String] = [:]

    var proxyLines: [String] = []
    var groupLines: [String] = []
    var ruleLines: [String] = []
    var hostLines: [String] = []
    var mitmLines: [String] = []
    var mitmSetLines: [String] = []
    var settingLines: [String] = []

    init(source: ConfigurationExportSource, options: ConfigurationExporter.Options) {
        self.source = source
        self.options = options
        self.notes = source.notes
    }

    func result() -> ConfigurationExporter.Result {
        var blocks: [String] = []
        if options.includeBanner {
            blocks.append(ConfigurationExporter.banner)
        }
        for block in [
            ConfigurationExporter.section("General", settingLines),
            ConfigurationExporter.section("Proxy", proxyLines),
            ConfigurationExporter.section("Proxy Group", groupLines),
            ConfigurationExporter.section("Rule", ruleLines),
            ConfigurationExporter.section("Host", hostLines),
            ConfigurationExporter.section("MITM", mitmLines),
            ConfigurationExporter.section("MITM Set", mitmSetLines)
        ].compactMap({ $0 }) {
            blocks.append(block)
        }

        return ConfigurationExporter.Result(
            text: blocks.joined(separator: "\n\n") + "\n",
            notes: notes,
            counts: counts
        )
    }
}



// MARK: - Sections

nonisolated extension State {

    mutating func emitNodes() {
        for proxy in source.proxies {
            let url = proxy.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                notes.append("Skipped node '\(proxy.name)': it has no shareable link.")
                continue
            }
            let name = ConfigurationExporter.unique(proxy.name, fallback: "Node", used: &used)
            if name != proxy.name {
                // First mapping wins: a duplicated name keeps pointing at the
                // node that kept the original spelling.
                if renames[proxy.name] == nil {
                    renames[proxy.name] = name
                }
                notes.append(
                    "Renamed node '\(proxy.name)' to '\(name)': the original name cannot be used in a text configuration."
                )
            }
            proxyLines.append("\(name) = \(url)")
        }
        counts.proxies = proxyLines.count
    }

    mutating func emitGroups() {
        // Names are reserved first, so a group can reference one declared
        // further down — the parser allows that, and emitting in a single pass
        // would drop those members.
        var groupNames: [String] = []
        for group in source.groups {
            let name = ConfigurationExporter.unique(group.name, fallback: "Group", used: &used)
            if name != group.name {
                if renames[group.name] == nil {
                    renames[group.name] = name
                }
                notes.append(
                    "Renamed group '\(group.name)' to '\(name)': the original name cannot be used in a text configuration."
                )
            }
            groupNames.append(name)
        }

        for (offset, group) in source.groups.enumerated() {
            let name = groupNames[offset]
            var members: [String] = []
            for member in group.members {
                let resolved = renames[member] ?? member
                guard used.contains(resolved) else {
                    notes.append("Group '\(name)' references '\(member)', which is not part of the document.")
                    continue
                }
                guard resolved != name, !members.contains(resolved) else { continue }
                members.append(resolved)
            }
            guard !members.isEmpty else {
                notes.append("Skipped group '\(name)': none of its members could be exported.")
                continue
            }
            groupLines.append("\(name) = select, \(members.joined(separator: ", "))")
        }
        counts.groups = groupLines.count
    }
}

nonisolated extension State {

    mutating func emitRules() {
        for ruleSet in source.ruleSets {
            guard !ruleSet.rules.isEmpty else {
                notes.append("Skipped rule set '\(ruleSet.name)': it has no rules.")
                counts.skippedRuleSets.append(ruleSet.name)
                continue
            }

            let rawPolicy = (ruleSet.policy ?? "").trimmingCharacters(in: .whitespaces)
            guard !rawPolicy.isEmpty else {
                notes.append(
                    "Skipped rule set '\(ruleSet.name)': it has no policy assigned, and a text rule always carries one."
                )
                counts.skippedRuleSets.append(ruleSet.name)
                continue
            }

            let policy = renames[rawPolicy] ?? rawPolicy
            let isBuiltIn = ConfigurationExporter.builtInPolicies.contains(policy.uppercased())
            guard isBuiltIn || used.contains(policy) else {
                notes.append(
                    "Skipped rule set '\(ruleSet.name)': policy '\(rawPolicy)' is not a node or group in this document."
                )
                counts.skippedRuleSets.append(ruleSet.name)
                continue
            }

            if options.includeRuleSetComments {
                ruleLines.append("# \(ruleSet.name) -> \(policy)")
            }
            for rule in ruleSet.rules {
                let value = rule.value.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                guard !value.contains(",") else {
                    notes.append("Skipped a rule in '\(ruleSet.name)': '\(value)' contains a comma.")
                    continue
                }
                ruleLines.append("\(ConfigurationExporter.ruleToken(for: rule.type)), \(value), \(policy)")
                counts.rules += 1
            }
        }

        ruleLines.append("FINAL, \(options.finalPolicy)")
    }

    mutating func emitHosts() {
        for host in source.hosts {
            guard host.isValid else {
                notes.append("Skipped host '\(host.host) = \(host.address)': it is not a valid host or address.")
                continue
            }
            hostLines.append("\(host.host.lowercased()) = \(host.address)")
        }
        counts.hosts = hostLines.count
    }

    mutating func emitMITM() {
        guard options.includeMITM else { return }

        if source.mitmRuleSets.isEmpty {
            if !source.mitmHostnames.isEmpty {
                mitmLines.append("enable = \(source.mitmEnabled)")
                mitmLines.append("hostname = \(source.mitmHostnames.joined(separator: ", "))")
            } else if source.mitmEnabled {
                notes.append("MITM is enabled but has no host policies.")
            }
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            for (index, set) in source.mitmRuleSets.enumerated() {
                if let data = try? encoder.encode(set) {
                    mitmSetLines.append("set-\(index + 1) = base64:\(data.base64EncodedString())")
                } else { notes.append("MITM set '\(set.name)' could not be encoded.") }
            }
        }
        if !source.settings.contains(where: { $0.key.lowercased() == "mitm" }) {
            settingLines.append("mitm = \(source.mitmEnabled)")
        }
    }

    mutating func emitSettings() {
        for setting in source.settings {
            let key = setting.key.trimmingCharacters(in: .whitespaces)
            let value = setting.value.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty, !value.contains("\n") else { continue }
            settingLines.append("\(key) = \(value)")
        }
    }
}


// MARK: - Helpers

nonisolated extension ConfigurationExporter {

    static let builtInPolicies: Set<String> = ["PROXY", "DIRECT", "REJECT"]

    static func section(_ title: String, _ lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        return (["[\(title)]"] + lines).joined(separator: "\n")
    }

    /// The four rule types the binary payload carries, in the document spelling
    /// `NaiveFlowConfigurationParser` maps back to the same type.
    static func ruleToken(for type: RoutingRuleType) -> String {
        switch type {
        case .domainSuffix: return "DOMAIN-SUFFIX"
        case .domainKeyword: return "DOMAIN-KEYWORD"
        case .ipCIDR: return "IP-CIDR"
        }
    }

    /// `[Proxy]` keys are separated from their value by `=`, `[Proxy Group]` and
    /// `[Rule]` split on commas, and a `#` after whitespace starts a comment, so
    /// those characters cannot survive a round trip. Replacing them keeps the
    /// document readable instead of producing one that parses differently.
    ///
    /// Names that collide with a policy token (`DIRECT`, `REJECT`,
    /// `REJECT-TINYGIF`, `PROXY`) get a suffix as well: such a node or group can
    /// be declared but never referenced, because `RULE, value, DIRECT` binds to
    /// the built-in action. The rename is reported through `State.renames` and
    /// `notes`, like every other rename.
    static func sanitized(_ raw: String) -> String {
        var out = ""
        for character in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            switch character {
            case ",", "#", "=", "\n", "\r", "\t":
                out.append("_")
            default:
                out.append(character)
            }
        }
        out = out.trimmingCharacters(in: .whitespaces)
        if ParsedRule.Policy(token: out).isBuiltIn {
            out += "_"
        }
        return out
    }

    /// Declaring the same name twice is an error in the parser, so duplicates
    /// are numbered rather than exported as a document that cannot be read back.
    static func unique(_ raw: String, fallback: String, used: inout Set<String>) -> String {
        let cleaned = sanitized(raw)
        let base = cleaned.isEmpty ? fallback : cleaned
        guard used.contains(base) else {
            used.insert(base)
            return base
        }

        var suffix = 2
        while used.contains("\(base) \(suffix)") {
            suffix += 1
        }
        let name = "\(base) \(suffix)"
        used.insert(name)
        return name
    }
}

