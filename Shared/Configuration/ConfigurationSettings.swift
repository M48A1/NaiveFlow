//
//  ConfigurationSettings.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// One value a `[General]` key can hold.
///
/// The document is untyped, so every value is parsed into one of these shapes and
/// stays in that shape through compile, apply and export. That is what makes the
/// round trip stable: a `true` is written back as `true`, a list as a comma list,
/// in document order.
nonisolated enum ConfigurationSettingValue: Equatable, Sendable {
    case flag(Bool)
    case text(String)
    case list([String])

    /// How the value appears in a document.
    var rendered: String {
        switch self {
        case .flag(let value):
            return value ? "true" : "false"
        case .text(let value):
            return value
        case .list(let value):
            return value.joined(separator: ", ")
        }
    }

    /// An empty list and an empty string carry no configuration, so the exporter
    /// leaves them out instead of writing `key = `.
    var isEmpty: Bool {
        switch self {
        case .flag:
            return false
        case .text(let value):
            return value.isEmpty
        case .list(let value):
            return value.isEmpty
        }
    }
}

/// One `[General]` key: how to parse it, what it changes, and how much of a
/// reload it costs.
///
/// This table is the only place a setting is declared. Parsing, validation,
/// compilation, installation, export and the reload plan all read it, so adding
/// a setting is one entry here plus one case in `ConfigurationSettingsBindings`
/// — there is no second list to keep in sync.
nonisolated struct ConfigurationSettingKey: Identifiable, Sendable {

    /// The shapes a `[General]` value can take, defining the spellings NaiveFlow
    /// accepts so a real profile imports unchanged.
    enum Kind: Equatable, Sendable {
        /// `true` / `false` / `yes` / `no` / `on` / `off` / `1` / `0`.
        case flag
        /// Free text, trimmed. An empty value means "not set".
        case text
        /// One of `values`, matched case-insensitively.
        case enumeration([String])
        /// ISO country code, uppercased.
        case countryCode
        /// Comma list, trimmed, order preserved. An empty list clears the value.
        case list
        /// A single DNS server that must parse as `1.1.1.1`, `1.1.1.1:53` or
        /// `1.1.1.1:53`.
        case plainServer
        /// A DoH endpoint that must parse as an `https://` URL.
        case dohURL
        case bootstrapDNS
    }

    let name: String
    let kind: Kind
    let scope: ConfigurationReloadPlan.Scope
    /// `false` keeps the key recognized and reported but not installed. That is
    /// how an unavailable setting stays visible in diagnostics
    /// instead of looking applied.
    let applies: Bool
    let summary: String

    var id: String { name }

    /// `nil` when the raw text is not valid for this kind; the validator turns
    /// that into a diagnostic and the compiler skips the key.
    func parse(_ raw: String) -> ConfigurationSettingValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        switch kind {
        case .flag:
            switch trimmed.lowercased() {
            case "1", "true", "yes", "on": return .flag(true)
            case "0", "false", "no", "off": return .flag(false)
            default: return nil
            }

        case .text:
            return trimmed.isEmpty ? nil : .text(trimmed)

        case .enumeration(let values):
            let normalized = trimmed.lowercased()
            return values.contains(normalized) ? .text(normalized) : nil

        case .countryCode:
            let code = trimmed.uppercased()
            guard code.isEmpty || (code.count == 2 && code.allSatisfy(\.isLetter)) else { return nil }
            return code.isEmpty ? nil : .text(code)

        case .list:
            let items = trimmed
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .list(items)

        case .plainServer:
            guard !trimmed.isEmpty, DNSUpstream.parsePlain(trimmed) != nil else { return nil }
            return .text(trimmed)

        case .bootstrapDNS:
            guard let policy = DNSBootstrapPolicy.parse(trimmed) else { return nil }
            return .text(policy.rendered)

        case .dohURL:
            guard !trimmed.isEmpty, DNSUpstream.parseDoH(trimmed) != nil else { return nil }
            return .text(trimmed)
        }
    }
}

// MARK: - Catalog

/// Every `[General]` key this build understands, in the order it is written back
/// out.
///
/// `applies: false` marks settings that are recognized so a real profile imports,
/// but that have no effect yet; each one produces a `notApplied` warning. Never
/// flip that flag without adding the binding too — the test target checks that
/// the two tables agree.
nonisolated enum ConfigurationSettings {

    static let catalog: [ConfigurationSettingKey] = [

        ConfigurationSettingKey(
            name: "lan-proxy-enabled",
            kind: .flag,
            scope: .live,
            applies: true,
            summary: "false disables LAN SOCKS5 sharing even when enabled locally; true permits the local switch."
        ),

        // MARK: Routing mode

        ConfigurationSettingKey(
            name: "proxy-mode",
            kind: .enumeration(["rule", "global", "direct"]),
            scope: .stackRestart,
            applies: true,
            summary: "rule routes by [Rule], global sends everything through PROXY, direct bypasses the tunnel."
        ),
        ConfigurationSettingKey(
            name: "quic-policy",
            kind: .enumeration(["automatic", "blocked", "unblocked"]),
            scope: .live,
            applies: true,
            summary: "Whether QUIC/UDP 443 is blocked."
        ),
        ConfigurationSettingKey(
            name: "block-udp",
            kind: .flag,
            scope: .live,
            applies: true,
            summary: "Drops UDP traffic that is not proxied."
        ),
        ConfigurationSettingKey(
            name: "block-webrtc",
            kind: .flag,
            scope: .live,
            applies: true,
            summary: "Blocks WebRTC traffic so the real address cannot leak."
        ),
        ConfigurationSettingKey(
            name: "prevent-dns-leak",
            kind: .flag,
            scope: .live,
            applies: true,
            summary: "Forces DNS through the tunnel resolver."
        ),
        ConfigurationSettingKey(
            name: "hide-vpn-icon",
            kind: .flag,
            scope: .live,
            applies: true,
            summary: "Hides the VPN badge in the status bar."
        ),
        ConfigurationSettingKey(
            name: "bypass-country",
            kind: .countryCode,
            scope: .live,
            applies: true,
            summary: "Routes this country's IP ranges directly."
        ),

        // MARK: Tunnel

        ConfigurationSettingKey(
            name: "include-all-networks",
            kind: .flag,
            scope: .reconnect,
            applies: true,
            summary: "Routes every network, including ones iOS normally excludes."
        ),
        ConfigurationSettingKey(
            name: "exclude-local-network",
            kind: .flag,
            scope: .reconnect,
            applies: true,
            summary: "Keeps local networks outside the tunnel."
        ),
        ConfigurationSettingKey(
            name: "include-apns",
            kind: .flag,
            scope: .reconnect,
            applies: true,
            summary: "Sends APNs traffic through the tunnel."
        ),
        ConfigurationSettingKey(
            name: "include-cellular-services",
            kind: .flag,
            scope: .reconnect,
            applies: true,
            summary: "Sends carrier services through the tunnel."
        ),
        ConfigurationSettingKey(
            name: "exclude-device-communication",
            kind: .flag,
            scope: .reconnect,
            applies: true,
            summary: "Keeps AirDrop/Handoff traffic outside the tunnel."
        ),
        ConfigurationSettingKey(
            name: "always-on",
            kind: .flag,
            scope: .reconnect,
            applies: true,
            summary: "Asks iOS to keep the tunnel up."
        ),
        ConfigurationSettingKey(
            name: "tun-included-routes",
            kind: .list,
            scope: .live,
            applies: true,
            summary: "CIDRs the tunnel must capture."
        ),
        ConfigurationSettingKey(
            name: "tun-excluded-routes",
            kind: .list,
            scope: .live,
            applies: true,
            summary: "CIDRs the tunnel must leave alone."
        ),

        // MARK: DNS

        ConfigurationSettingKey(name: "bootstrap-dns", kind: .bootstrapDNS,
            scope: .stackRestart, applies: true,
            summary: "System or numeric seed servers used only for named DoH endpoint resolution."),
        ConfigurationSettingKey(
            name: "dns-mode",
            kind: .enumeration(["default", "plain", "doh"]),
            scope: .stackRestart,
            applies: true,
            summary: "Which direct resolver is used: the system one, dns-server, or encrypted-dns-server."
        ),
        ConfigurationSettingKey(
            name: "dns-server",
            kind: .plainServer,
            scope: .stackRestart,
            applies: true,
            summary: "Plain resolver for direct connections; sets dns-mode = plain."
        ),
        ConfigurationSettingKey(
            name: "encrypted-dns-server",
            kind: .dohURL,
            scope: .stackRestart,
            applies: true,
            summary: "DoH resolver for direct connections; sets dns-mode = doh."
        ),
        ConfigurationSettingKey(
            name: "proxy-dns-mode",
            kind: .enumeration(["default", "plain", "doh"]),
            scope: .stackRestart,
            applies: true,
            summary: "Which resolver proxied connections use."
        ),
        ConfigurationSettingKey(
            name: "proxy-dns-server",
            kind: .plainServer,
            scope: .stackRestart,
            applies: true,
            summary: "Plain resolver used for proxied connections."
        ),
        ConfigurationSettingKey(
            name: "proxy-encrypted-dns-server",
            kind: .dohURL,
            scope: .stackRestart,
            applies: true,
            summary: "DoH resolver used for proxied connections."
        ),
        ConfigurationSettingKey(
            name: "subscription-dns-mode",
            kind: .enumeration(["default", "plain", "doh"]),
            scope: .live,
            applies: true,
            summary: "Which resolver downloads subscriptions use."
        ),
        ConfigurationSettingKey(
            name: "subscription-dns-server",
            kind: .plainServer,
            scope: .live,
            applies: true,
            summary: "Plain resolver used while downloading subscriptions."
        ),
        ConfigurationSettingKey(
            name: "subscription-encrypted-dns-server",
            kind: .dohURL,
            scope: .live,
            applies: true,
            summary: "DoH resolver used while downloading subscriptions."
        ),
        ConfigurationSettingKey(
            name: "fallback-dns-mode",
            kind: .enumeration(["default", "plain"]),
            scope: .stackRestart,
            applies: true,
            summary: "Whether fallback-dns-server is used at all."
        ),
        ConfigurationSettingKey(
            name: "fallback-dns-server",
            kind: .plainServer,
            scope: .stackRestart,
            applies: true,
            summary: "Resolver used when the primary one fails."
        ),
        ConfigurationSettingKey(
            name: "ech-dns-mode",
            kind: .enumeration(["default", "plain", "doh"]),
            scope: .stackRestart,
            applies: true,
            summary: "Which resolver looks up ECH configs."
        ),
        ConfigurationSettingKey(
            name: "ech-dns-server",
            kind: .plainServer,
            scope: .stackRestart,
            applies: true,
            summary: "Plain resolver used to look up ECH configs."
        ),
        ConfigurationSettingKey(
            name: "ech-encrypted-dns-server",
            kind: .dohURL,
            scope: .stackRestart,
            applies: true,
            summary: "DoH resolver used to look up ECH configs."
        ),
        ConfigurationSettingKey(
            name: "synthetic-address-excluded-suffix",
            kind: .list,
            scope: .stackRestart,
            applies: true,
            summary: "Domain suffixes that never get a fake IP."
        ),
        ConfigurationSettingKey(
            name: "dns-exempt-servers",
            kind: .list,
            scope: .stackRestart,
            applies: true,
            summary: "IPv4 addresses the ordinary DNS interception leaves alone."
        ),

        // MARK: TLS and interception

        ConfigurationSettingKey(
            name: "mitm",
            kind: .flag,
            scope: .live,
            applies: true,
            summary: "Turns MITM on; [MITM] enable wins when both appear."
        ),
        ConfigurationSettingKey(
            name: "allow-insecure",
            kind: .flag,
            scope: .stackRestart,
            applies: true,
            summary: "Accepts invalid upstream certificates (testing only)."
        ),
        ConfigurationSettingKey(
            name: "trusted-certificate",
            kind: .list,
            scope: .live,
            applies: true,
            summary: "SHA-256 fingerprints of upstream certificates to trust."
        ),
        ConfigurationSettingKey(
            name: "trusted-ssid",
            kind: .list,
            scope: .live,
            applies: true,
            summary: "Wi-Fi networks where the tunnel stays off."
        ),
        ConfigurationSettingKey(
            name: "always-trust-cellular",
            kind: .flag,
            scope: .live,
            applies: true,
            summary: "Treats cellular as trusted even when a trusted SSID is set."
        ),
        ConfigurationSettingKey(
            name: "always-untrust-cellular",
            kind: .flag,
            scope: .live,
            applies: true,
            summary: "Treats cellular as untrusted even when a trusted SSID is set."
        ),

        // MARK: Diagnostics

        ConfigurationSettingKey(
            name: "reflection",
            kind: .flag,
            scope: .live,
            applies: true,
            summary: "Mirrors connection activity into the app for debugging."
        ),
        ConfigurationSettingKey(
            name: "experimental",
            kind: .flag,
            scope: .live,
            applies: true,
            summary: "Enables the experimental engine features."
        ),
        ConfigurationSettingKey(
            name: "loglevel",
            kind: .enumeration(["debug", "info", "warn", "error"]),
            scope: .live,
            applies: false,
            summary: "Recorded in the document; this build has no persisted log level."
        ),

        // MARK: Recognized, not applied
        //
        // Reserved keys not implemented by this build (activation rejects them).
        // They stay in the catalog so the parser accepts them and the validator
        // reports each one instead of silently dropping it.

        ConfigurationSettingKey(
            name: "dns-server-fallback",
            kind: .plainServer,
            scope: .stackRestart,
            applies: false,
            summary: "Use fallback-dns-server instead."
        ),
        ConfigurationSettingKey(
            name: "dns-fallback-system",
            kind: .flag,
            scope: .stackRestart,
            applies: false,
            summary: "Falling back to the system resolver is not implemented."
        ),
        ConfigurationSettingKey(
            name: "dns-direct-system",
            kind: .flag,
            scope: .stackRestart,
            applies: false,
            summary: "The direct resolver follows dns-mode instead."
        ),
        ConfigurationSettingKey(
            name: "hijack-dns",
            kind: .list,
            scope: .stackRestart,
            applies: false,
            summary: "DNS hijacking is not implemented."
        ),
        ConfigurationSettingKey(
            name: "dns-exclude-route",
            kind: .list,
            scope: .stackRestart,
            applies: false,
            summary: "Use synthetic-address-excluded-suffix instead."
        ),
        ConfigurationSettingKey(
            name: "test-url",
            kind: .text,
            scope: .live,
            applies: false,
            summary: "Latency testing is configured from the app."
        ),
        ConfigurationSettingKey(
            name: "proxy-test-url",
            kind: .text,
            scope: .live,
            applies: false,
            summary: "Latency testing is configured from the app."
        ),
        ConfigurationSettingKey(
            name: "test-timeout",
            kind: .text,
            scope: .live,
            applies: false,
            summary: "Latency testing is configured from the app."
        ),
        ConfigurationSettingKey(
            name: "internet-test-url",
            kind: .text,
            scope: .live,
            applies: false,
            summary: "Connectivity testing is configured from the app."
        ),
        ConfigurationSettingKey(
            name: "auto-quic-block",
            kind: .flag,
            scope: .live,
            applies: false,
            summary: "Use quic-policy = automatic instead."
        ),
        ConfigurationSettingKey(
            name: "allow-hotspot-access",
            kind: .flag,
            scope: .live,
            applies: false,
            summary: "Hotspot access is not implemented."
        ),
        ConfigurationSettingKey(
            name: "skip-proxy",
            kind: .list,
            scope: .live,
            applies: false,
            summary: "Use tun-excluded-routes instead."
        ),
        ConfigurationSettingKey(
            name: "always-real-ip",
            kind: .list,
            scope: .live,
            applies: false,
            summary: "Fake-IP exclusions use synthetic-address-excluded-suffix."
        ),
    ]

    private static let byName = Dictionary(
        catalog.map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func key(named name: String) -> ConfigurationSettingKey? {
        byName[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// Keys whose value actually reaches the engine.
    static var appliedKeys: [ConfigurationSettingKey] {
        catalog.filter(\.applies)
    }

    /// Keys accepted for compatibility and reported as not applied.
    static var unappliedKeys: [ConfigurationSettingKey] {
        catalog.filter { !$0.applies }
    }

    static var names: Set<String> {
        Set(catalog.map(\.name))
    }
}

// MARK: - Bindings

/// How a `[General]` key reaches `AWCore`.
///
/// The catalog says what a key means; this table says where the value lives.
/// Both are keyed by the same names, and `ConfigurationSettingsTests` fails the
/// build if they drift apart — that is what keeps "add a feature, add a
/// parameter" to two entries in one file.
nonisolated struct ConfigurationSettingBinding: Sendable {
    let name: String
    /// The value the app is using right now, or `nil` when it is not set.
    let read: @Sendable () -> ConfigurationSettingValue?
    /// Applies a document value. Values of the wrong shape are ignored, so a
    /// binding never has to re-validate what the parser already checked.
    let write: @Sendable (ConfigurationSettingValue) -> Void
}

nonisolated enum ConfigurationSettingsBindings {

    static let all: [ConfigurationSettingBinding] = [

        // MARK: Routing mode

        bind("lan-proxy-enabled", read: { .flag(AWCore.getLANProxyAllowed()) }, write: { value in
            if let flag = bool(value) { AWCore.setLANProxyAllowed(flag) }
        }),

        bind("proxy-mode", read: {
            .text(AWCore.getProxyMode().rawValue)
        }, write: { value in
            if let mode = ProxyMode(rawValue: text(value) ?? "") { AWCore.setProxyMode(mode) }
        }),

        bind("quic-policy", read: {
            .text(AWCore.getQUICPolicy().rawValue)
        }, write: { value in
            if let policy = QUICPolicy(rawValue: text(value) ?? "") { AWCore.setQUICPolicy(policy) }
        }),

        bind("block-udp", read: { .flag(AWCore.getBlockUDP()) }, write: { value in
            if let flag = bool(value) { AWCore.setBlockUDP(flag) }
        }),

        bind("block-webrtc", read: { .flag(AWCore.getBlockWebRTC()) }, write: { value in
            if let flag = bool(value) { AWCore.setBlockWebRTC(flag) }
        }),

        bind("prevent-dns-leak", read: { .flag(AWCore.getPreventDNSLeak()) }, write: { value in
            if let flag = bool(value) { AWCore.setPreventDNSLeak(flag) }
        }),

        bind("hide-vpn-icon", read: { .flag(AWCore.getHideVPNIcon()) }, write: { value in
            if let flag = bool(value) { AWCore.setHideVPNIcon(flag) }
        }),

        bind("bypass-country", read: {
            let code = AWCore.getBypassCountryCode()
            return code.isEmpty ? nil : .text(code.uppercased())
        }, write: { value in
            if let code = text(value) { AWCore.setBypassCountryCode(code.uppercased()) }
        }),

        // MARK: Tunnel

        bind("include-all-networks", read: { .flag(AWCore.getTunnelIncludeAllNetworks()) }, write: { value in
            if let flag = bool(value) { AWCore.setTunnelIncludeAllNetworks(flag) }
        }),

        bind("exclude-local-network", read: { .flag(AWCore.getTunnelExcludeLocalNetworks()) }, write: { value in
            if let flag = bool(value) { AWCore.setTunnelExcludeLocalNetworks(flag) }
        }),

        // APNs and carrier services are stored inverted so the tunnel preferences
        // keep their iOS default; the document uses the positive spelling.
        bind("include-apns", read: { .flag(!AWCore.getTunnelExcludeAPNs()) }, write: { value in
            if let flag = bool(value) { AWCore.setTunnelExcludeAPNs(!flag) }
        }),

        bind("include-cellular-services", read: {
            .flag(!AWCore.getTunnelExcludeCellularServices())
        }, write: { value in
            if let flag = bool(value) { AWCore.setTunnelExcludeCellularServices(!flag) }
        }),

        bind("exclude-device-communication", read: {
            .flag(AWCore.getTunnelExcludeDeviceCommunication())
        }, write: { value in
            if let flag = bool(value) { AWCore.setTunnelExcludeDeviceCommunication(flag) }
        }),

        bind("always-on", read: { .flag(AWCore.getAlwaysOnEnabled()) }, write: { value in
            if let flag = bool(value) { AWCore.setAlwaysOnEnabled(flag) }
        }),

        bind("tun-included-routes", read: { .list(AWCore.getTunnelIncludedRoutes()) }, write: { value in
            if let routes = list(value) { AWCore.setTunnelIncludedRoutes(routes) }
        }),

        bind("tun-excluded-routes", read: { .list(AWCore.getTunnelExcludedRoutes()) }, write: { value in
            if let routes = list(value) { AWCore.setTunnelExcludedRoutes(routes) }
        }),

        // MARK: DNS
        //
        // Each channel has a mode key plus one key per transport. Writing a
        // server switches the mode to match, so `dns-server = 1.1.1.1` is enough
        // and `dns-mode` only has to be written to go back to the system
        // resolver.

        bind("bootstrap-dns", read: { .text(AWCore.getBootstrapDNS().rendered) }, write: { value in
            if let value = text(value), let policy = DNSBootstrapPolicy.parse(value) { AWCore.setBootstrapDNS(policy) }
        }),

        bind("dns-mode", read: { .text(AWCore.getLocalRequestDNSMode().rawValue) }, write: { value in
            if let mode = DNSMode(rawValue: text(value) ?? "") { AWCore.setLocalRequestDNSMode(mode) }
        }),

        bind("dns-server", read: {
            plainServer(AWCore.getLocalRequestDNSMode(), AWCore.getLocalRequestDNSPlainServer())
        }, write: { value in
            guard let server = text(value) else { return }
            AWCore.setLocalRequestDNSPlainServer(server)
            AWCore.setLocalRequestDNSMode(.plain)
        }),

        bind("encrypted-dns-server", read: {
            dohServer(AWCore.getLocalRequestDNSMode(), AWCore.getLocalRequestDNSDoHURL())
        }, write: { value in
            guard let url = text(value) else { return }
            AWCore.setLocalRequestDNSDoHURL(url)
            AWCore.setLocalRequestDNSMode(.doh)
        }),

        bind("proxy-dns-mode", read: { .text(AWCore.getProxyDNSMode().rawValue) }, write: { value in
            if let mode = DNSMode(rawValue: text(value) ?? "") { AWCore.setProxyDNSMode(mode) }
        }),

        bind("proxy-dns-server", read: {
            plainServer(AWCore.getProxyDNSMode(), AWCore.getProxyDNSPlainServer())
        }, write: { value in
            guard let server = text(value) else { return }
            AWCore.setProxyDNSPlainServer(server)
            AWCore.setProxyDNSMode(.plain)
        }),

        bind("proxy-encrypted-dns-server", read: {
            dohServer(AWCore.getProxyDNSMode(), AWCore.getProxyDNSDoHURL())
        }, write: { value in
            guard let url = text(value) else { return }
            AWCore.setProxyDNSDoHURL(url)
            AWCore.setProxyDNSMode(.doh)
        }),

        bind("subscription-dns-mode", read: {
            .text(AWCore.getSubscriptionDNSMode().rawValue)
        }, write: { value in
            if let mode = DNSMode(rawValue: text(value) ?? "") { AWCore.setSubscriptionDNSMode(mode) }
        }),

        bind("subscription-dns-server", read: {
            plainServer(AWCore.getSubscriptionDNSMode(), AWCore.getSubscriptionDNSPlainServer())
        }, write: { value in
            guard let server = text(value) else { return }
            AWCore.setSubscriptionDNSPlainServer(server)
            AWCore.setSubscriptionDNSMode(.plain)
        }),

        bind("subscription-encrypted-dns-server", read: {
            dohServer(AWCore.getSubscriptionDNSMode(), AWCore.getSubscriptionDNSDoHURL())
        }, write: { value in
            guard let url = text(value) else { return }
            AWCore.setSubscriptionDNSDoHURL(url)
            AWCore.setSubscriptionDNSMode(.doh)
        }),

        bind("fallback-dns-mode", read: {
            .text(AWCore.getFallbackDNSMode().rawValue)
        }, write: { value in
            if let mode = FallbackDNSMode(rawValue: text(value) ?? "") { AWCore.setFallbackDNSMode(mode) }
        }),

        bind("fallback-dns-server", read: {
            let mode = AWCore.getFallbackDNSMode()
            guard mode == .plain else { return nil }
            let server = AWCore.getFallbackDNSServer()
            return server.isEmpty ? nil : .text(server)
        }, write: { value in
            guard let server = text(value) else { return }
            AWCore.setFallbackDNSServer(server)
            AWCore.setFallbackDNSMode(.plain)
        }),

        bind("ech-dns-mode", read: { .text(AWCore.getECHDNSMode().rawValue) }, write: { value in
            if let mode = DNSMode(rawValue: text(value) ?? "") { AWCore.setECHDNSMode(mode) }
        }),

        bind("ech-dns-server", read: {
            plainServer(AWCore.getECHDNSMode(), AWCore.getECHDNSPlainServer())
        }, write: { value in
            guard let server = text(value) else { return }
            AWCore.setECHDNSPlainServer(server)
            AWCore.setECHDNSMode(.plain)
        }),

        bind("ech-encrypted-dns-server", read: {
            dohServer(AWCore.getECHDNSMode(), AWCore.getECHDNSDoHURL())
        }, write: { value in
            guard let url = text(value) else { return }
            AWCore.setECHDNSDoHURL(url)
            AWCore.setECHDNSMode(.doh)
        }),

        bind("synthetic-address-excluded-suffix", read: {
            .list(AWCore.getSyntheticAddressExcludedDomainSuffixes())
        }, write: { value in
            if let suffixes = list(value) { AWCore.setSyntheticAddressExcludedDomainSuffixes(suffixes) }
        }),

        bind("dns-exempt-servers", read: {
            .list(AWCore.getDNSExemptServers())
        }, write: { value in
            if let servers = list(value) { AWCore.setDNSExemptServers(servers) }
        }),

        // MARK: TLS and interception

        bind("mitm", read: { .flag(AWCore.getMITMEnabled()) }, write: { value in
            if let flag = bool(value) { AWCore.setMITMEnabled(flag) }
        }),

        bind("allow-insecure", read: { .flag(AWCore.getAllowInsecure()) }, write: { value in
            if let flag = bool(value) { AWCore.setAllowInsecure(flag) }
        }),

        bind("trusted-certificate", read: {
            .list(AWCore.getTrustedCertificateFingerprints())
        }, write: { value in
            if let fingerprints = list(value) { AWCore.setTrustedCertificateFingerprints(fingerprints) }
        }),

        bind("trusted-ssid", read: { .list(AWCore.getTrustedSSIDs()) }, write: { value in
            if let ssids = list(value) { AWCore.setTrustedSSIDs(ssids) }
        }),

        bind("always-trust-cellular", read: { .flag(AWCore.getAlwaysTrustCellular()) }, write: { value in
            if let flag = bool(value) { AWCore.setAlwaysTrustCellular(flag) }
        }),

        bind("always-untrust-cellular", read: { .flag(AWCore.getAlwaysUntrustCellular()) }, write: { value in
            if let flag = bool(value) { AWCore.setAlwaysUntrustCellular(flag) }
        }),

        // MARK: Diagnostics

        bind("reflection", read: { .flag(AWCore.getReflectionEnabled()) }, write: { value in
            if let flag = bool(value) { AWCore.setReflectionEnabled(flag) }
        }),

        bind("experimental", read: { .flag(AWCore.getExperimentalEnabled()) }, write: { value in
            if let flag = bool(value) { AWCore.setExperimentalEnabled(flag) }
        }),
    ]

    private static let byName = Dictionary(
        all.map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static var names: Set<String> { Set(all.map(\.name)) }

    static func read(_ name: String) -> ConfigurationSettingValue? {
        byName[name]?.read()
    }

    static func write(_ name: String, _ value: ConfigurationSettingValue) {
        byName[name]?.write(value)
    }

    /// Everything the app is using right now, in the shape the compiler produces
    /// so a document can be diffed against it key by key.
    static func snapshot() -> CompiledSettings {
        var settings = CompiledSettings()
        for key in ConfigurationSettings.catalog where key.applies {
            if let value = read(key.name), !value.isEmpty {
                settings.values[key.name] = value
            }
        }
        return settings
    }

    // MARK: Helpers

    private static func bind(
        _ name: String,
        read: @escaping @Sendable () -> ConfigurationSettingValue?,
        write: @escaping @Sendable (ConfigurationSettingValue) -> Void
    ) -> ConfigurationSettingBinding {
        ConfigurationSettingBinding(name: name, read: read, write: write)
    }

    private static func bool(_ value: ConfigurationSettingValue) -> Bool? {
        if case .flag(let flag) = value { return flag }
        return nil
    }

    private static func text(_ value: ConfigurationSettingValue) -> String? {
        if case .text(let text) = value { return text }
        return nil
    }

    private static func list(_ value: ConfigurationSettingValue) -> [String]? {
        if case .list(let items) = value { return items }
        return nil
    }

    /// A plain resolver is only in use when the channel is in `.plain` mode;
    /// otherwise the key is absent from the document instead of exporting a
    /// server nothing reads.
    private static func plainServer(_ mode: DNSMode, _ server: String) -> ConfigurationSettingValue? {
        guard mode == .plain, !server.isEmpty else { return nil }
        return .text(server)
    }

    private static func dohServer(_ mode: DNSMode, _ url: String) -> ConfigurationSettingValue? {
        guard mode == .doh, !url.isEmpty else { return nil }
        return .text(url)
    }
}

// MARK: - Compiled settings

/// The `[General]` values a document asked for, keyed by setting name.
///
/// A key that is absent means "the document did not say", so installing it
/// leaves whatever the app had. That is the same contract the old per-field
/// struct had, without a struct field to add for every new setting.
nonisolated struct CompiledSettings: Equatable, Sendable {
    var values: [String: ConfigurationSettingValue] = [:]

    var isEmpty: Bool { values.isEmpty }

    subscript(name: String) -> ConfigurationSettingValue? {
        get { values[name] }
        set { values[name] = newValue }
    }

    /// The settings the engine is using right now.
    static func current() -> CompiledSettings {
        ConfigurationSettingsBindings.snapshot()
    }
}
