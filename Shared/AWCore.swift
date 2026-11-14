//
//  AWCore.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation
import Synchronization

nonisolated private let logger = NaiveFlowLogger(category: "AWCore")

nonisolated final class AWCore {
    
    // MARK: - Identifiers

    enum Identifier {
        static let appGroupSuite = "group.\(bundle)"
        static let bundle = "com.argsment.NaiveFlow"
        static let errorDomain = bundle
        static let iCloudContainer = "iCloud.\(bundle)"
    }
    
    static var isHostApp: Bool {
        Bundle.main.bundleIdentifier == Identifier.bundle
    }
    
    nonisolated(unsafe) private static let rawUserDefaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: Identifier.appGroupSuite)!
        defaults.register(defaults: runtimeDefaults.merging(["remnawaveHWID": UUID().uuidString], uniquingKeysWith: { _, new in new }))
        return defaults
    }()

    private static var runtimeDefaults: [String: Any] { [
            UserDefaultsKey.blockWebRTC: true,
            UserDefaultsKey.echDNSDoHURL: DNSUpstream.defaultDoHURL,
            UserDefaultsKey.echDNSPlainServer: DNSUpstream.defaultPlainServer,
            UserDefaultsKey.fallbackDNSServer: DNSUpstream.defaultPlainServer,
            UserDefaultsKey.localRequestDNSDoHURL: DNSUpstream.defaultDoHURL,
            UserDefaultsKey.localRequestDNSPlainServer: DNSUpstream.defaultPlainServer,
            UserDefaultsKey.proxyDNSDoHURL: DNSUpstream.defaultDoHURL,
            UserDefaultsKey.proxyDNSPlainServer: DNSUpstream.defaultPlainServer,
            UserDefaultsKey.proxyMode: ProxyMode.rule.rawValue,
            UserDefaultsKey.quicPolicy: QUICPolicy.automatic.rawValue,
            UserDefaultsKey.subscriptionDNSDoHURL: DNSUpstream.defaultDoHURL,
            UserDefaultsKey.subscriptionDNSPlainServer: DNSUpstream.defaultPlainServer,
            UserDefaultsKey.syntheticAddressExcludedDomainSuffixes: [],
            UserDefaultsKey.trustedSSIDs: [],
        ] }

    private static let userDefaults = RuntimePreferences(defaults: rawUserDefaults)

    static let runtimePreferenceKeys = [
        "bootstrapDNS", "activeConfiguration", "alwaysOnEnabled", "alwaysTrustCellular",
        "alwaysUntrustCellular", "blockUDP", "blockWebRTC",
        "echDNSDoHURL", "echDNSMode", "echDNSPlainServer", "experimentalEnabled",
        "fallbackDNSMode", "fallbackDNSServer", "hideVPNIcon", "hostMappings",
        "localRequestDNSDoHURL", "localRequestDNSMode", "localRequestDNSPlainServer", "lanProxyAllowed",
        "mitmEnabled", "preventDNSLeak", "proxyDNSDoHURL", "proxyDNSMode",
        "proxyDNSPlainServer", "proxyMode", "quicPolicy", "reflectionEnabled",
        "selectedChainId", "selectedConfigurationId", "subscriptionDNSDoHURL",
        "subscriptionDNSMode", "subscriptionDNSPlainServer", "syntheticAddressExcludedDomainSuffixes",
        "trustedSSIDs", "tunnelExcludeAPNs",
        "tunnelExcludeCellularServices", "tunnelExcludeDeviceCommunication",
        "tunnelExcludedRoutes", "tunnelExcludeLocalNetworks", "tunnelIncludeAllNetworks", "tunnelIncludedRoutes"
    ]

    /// Discard preferences from the removed manual settings and appearance UI.
    static func discardManualSettings() {
        for key in runtimePreferenceKeys + [
            "bypassCountryCode", "allowInsecure", "trustedCertificateSHA256s",
            "ruleSetAssignments", "moduleRuleSetAssignments", "onboardingCompleted", "homeColorScheme"
        ] { rawUserDefaults.removeObject(forKey: key) }
        for key in rawUserDefaults.dictionaryRepresentation().keys where key.hasPrefix("themeColor.") {
            rawUserDefaults.removeObject(forKey: key)
        }
    }

    static func defaultRuntimePreferences() -> [String: RuntimePreferenceValue] {
        Dictionary(uniqueKeysWithValues: runtimePreferenceKeys.map { ($0, RuntimePreferenceValue(runtimeDefaults[$0])) })
    }

    static func runtimePreferences() -> [String: RuntimePreferenceValue] {
        userDefaults.snapshot(keys: runtimePreferenceKeys)
    }

    static func installRuntimePreferences(_ values: [String: RuntimePreferenceValue]?) {
        userDefaults.install(values)
    }

    static func captureRuntimePreferences(
        base: [String: RuntimePreferenceValue]? = nil, _ write: () throws -> Void
    ) rethrows -> [String: RuntimePreferenceValue] {
        let values = base ?? defaultRuntimePreferences()
        let capture = RuntimePreferenceCapture(values)
        try RuntimePreferenceContext.$capture.withValue(capture, operation: write)
        return capture.values.withLock { $0 }
    }

    // MARK: - UserDefaults Keys

    private enum UserDefaultsKey {
        static let activeConfiguration = "activeConfiguration"
        static let alwaysOnEnabled = "alwaysOnEnabled"
        static let alwaysTrustCellular = "alwaysTrustCellular"
        static let alwaysUntrustCellular = "alwaysUntrustCellular"
        static let blockUDP = "blockUDP"
        static let blockWebRTC = "blockWebRTC"
        static let chainLatencyResults = "chainLatencyResults"
        static let detailRevealed = "detailRevealed"
        static let echDNSDoHURL = "echDNSDoHURL"
        static let echDNSMode = "echDNSMode"
        static let echDNSPlainServer = "echDNSPlainServer"
        static let experimentalEnabled = "experimentalEnabled"
        static let fallbackDNSMode = "fallbackDNSMode"
        static let fallbackDNSServer = "fallbackDNSServer"
        static let hideVPNIcon = "hideVPNIcon"
        static let hostMappings = "hostMappings"
        static let iCloudSyncEnabled = "iCloudSyncEnabled"
        static let identifier = "identifier"
        static let latencyResults = "latencyResults"
        static let localRequestDNSDoHURL = "localRequestDNSDoHURL"
        static let localRequestDNSMode = "localRequestDNSMode"
        static let localRequestDNSPlainServer = "localRequestDNSPlainServer"
        static let mitmEnabled = "mitmEnabled"
        static let preventDNSLeak = "preventDNSLeak"
        static let proxiesPageProxyType = "proxiesPageProxyType"
        static let proxyDNSDoHURL = "proxyDNSDoHURL"
        static let proxyDNSMode = "proxyDNSMode"
        static let proxyDNSPlainServer = "proxyDNSPlainServer"
        static let proxyMode = "proxyMode"
        static let quicPolicy = "quicPolicy"
        static let reflectionEnabled = "reflectionEnabled"
        static let remnawaveHWID = "remnawaveHWID"
        static let selectedChainId = "selectedChainId"
        static let selectedConfigurationId = "selectedConfigurationId"
        static let subscriptionDNSDoHURL = "subscriptionDNSDoHURL"
        static let subscriptionDNSMode = "subscriptionDNSMode"
        static let subscriptionDNSPlainServer = "subscriptionDNSPlainServer"
        static let syntheticAddressExcludedDomainSuffixes = "syntheticAddressExcludedDomainSuffixes"
        static let dnsExemptServers = "dnsExemptServers"
        static let trustedSSIDs = "trustedSSIDs"
        static let tunnelExcludeAPNs = "tunnelExcludeAPNs"
        static let tunnelExcludeCellularServices = "tunnelExcludeCellularServices"
        static let tunnelExcludeDeviceCommunication = "tunnelExcludeDeviceCommunication"
        static let tunnelExcludedRoutes = "tunnelExcludedRoutes"
        static let tunnelExcludeLocalNetworks = "tunnelExcludeLocalNetworks"
        static let tunnelIncludeAllNetworks = "tunnelIncludeAllNetworks"
        static let tunnelIncludedRoutes = "tunnelIncludedRoutes"
    }

    // Profiles can veto device-local LAN sharing; absence permits the local switch.
    static func getLANProxyAllowed() -> Bool {
        (userDefaults.object(forKey: "lanProxyAllowed") as? Bool) ?? true
    }

    static func setLANProxyAllowed(_ value: Bool) {
        userDefaults.set(value, forKey: "lanProxyAllowed")
    }

    // LAN sharing is device-local and intentionally outside runtime profile pins.
    static func getLANProxySettingsData() -> Data? {
        rawUserDefaults.data(forKey: "lanProxySettings")
    }

    static func setLANProxySettingsData(_ data: Data) {
        rawUserDefaults.set(data, forKey: "lanProxySettings")
    }

    // MARK: - Typed UserDefaults Accessors
    
    // App

    static func getDetailRevealed() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.detailRevealed)
    }

    static func setDetailRevealed(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.detailRevealed)
    }

    static func getProxiesPageProxyType() -> String? {
        userDefaults.string(forKey: UserDefaultsKey.proxiesPageProxyType)
    }

    static func setProxiesPageProxyType(_ rawValue: String) {
        userDefaults.set(rawValue, forKey: UserDefaultsKey.proxiesPageProxyType)
    }
    
    static func getICloudSyncEnabled() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.iCloudSyncEnabled)
    }

    static func setICloudSyncEnabled(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.iCloudSyncEnabled)
    }
    
    // Tunnel
    static func getActiveConfigurationData() -> Data? {
        userDefaults.data(forKey: UserDefaultsKey.activeConfiguration)
    }

    static func setActiveConfigurationData(_ data: Data?) {
        if let data {
            userDefaults.set(data, forKey: UserDefaultsKey.activeConfiguration)
        } else {
            userDefaults.removeObject(forKey: UserDefaultsKey.activeConfiguration)
        }
    }
    
    static func getSelectedConfigurationId() -> UUID? {
        userDefaults.string(forKey: UserDefaultsKey.selectedConfigurationId).flatMap(UUID.init(uuidString:))
    }
    
    static func setSelectedConfigurationId(_ id: UUID?) {
        if let id {
            userDefaults.set(id.uuidString, forKey: UserDefaultsKey.selectedConfigurationId)
        } else {
            userDefaults.removeObject(forKey: UserDefaultsKey.selectedConfigurationId)
        }
    }

    static func getSelectedChainId() -> UUID? {
        userDefaults.string(forKey: UserDefaultsKey.selectedChainId).flatMap(UUID.init(uuidString:))
    }
    
    static func setSelectedChainId(_ id: UUID?) {
        if let id {
            userDefaults.set(id.uuidString, forKey: UserDefaultsKey.selectedChainId)
        } else {
            userDefaults.removeObject(forKey: UserDefaultsKey.selectedChainId)
        }
    }

    // Latency
    static func getLatencyResultsData() -> Data? {
        userDefaults.data(forKey: UserDefaultsKey.latencyResults)
    }

    static func setLatencyResultsData(_ data: Data) {
        userDefaults.set(data, forKey: UserDefaultsKey.latencyResults)
    }

    static func getChainLatencyResultsData() -> Data? {
        userDefaults.data(forKey: UserDefaultsKey.chainLatencyResults)
    }

    static func setChainLatencyResultsData(_ data: Data) {
        userDefaults.set(data, forKey: UserDefaultsKey.chainLatencyResults)
    }

    // Settings
    static func getProxyMode() -> ProxyMode {
        ProxyMode(rawValue: userDefaults.string(forKey: UserDefaultsKey.proxyMode)!) ?? .rule
    }
    
    static func setProxyMode(_ proxyMode: ProxyMode) {
        userDefaults.set(proxyMode.rawValue, forKey: UserDefaultsKey.proxyMode)
    }
    
    static func getAlwaysOnEnabled() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.alwaysOnEnabled)
    }

    static func setAlwaysOnEnabled(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.alwaysOnEnabled)
    }
    
    static func getTunnelIncludeAllNetworks() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.tunnelIncludeAllNetworks)
    }

    static func setTunnelIncludeAllNetworks(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.tunnelIncludeAllNetworks)
    }

    static func getTunnelExcludeLocalNetworks() -> Bool {
        if let value = userDefaults.object(forKey: UserDefaultsKey.tunnelExcludeLocalNetworks) as? Bool {
            return value
        }
        return true
    }

    static func setTunnelExcludeLocalNetworks(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.tunnelExcludeLocalNetworks)
    }

    static func getTunnelExcludeAPNs() -> Bool {
        if let value = userDefaults.object(forKey: UserDefaultsKey.tunnelExcludeAPNs) as? Bool {
            return value
        }
        return true
    }

    static func setTunnelExcludeAPNs(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.tunnelExcludeAPNs)
    }

    static func getTunnelExcludeCellularServices() -> Bool {
        if let value = userDefaults.object(forKey: UserDefaultsKey.tunnelExcludeCellularServices) as? Bool {
            return value
        }
        return true
    }

    static func setTunnelExcludeCellularServices(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.tunnelExcludeCellularServices)
    }

    static func getTunnelExcludeDeviceCommunication() -> Bool {
        if let value = userDefaults.object(forKey: UserDefaultsKey.tunnelExcludeDeviceCommunication) as? Bool {
            return value
        }
        return true
    }

    static func setTunnelExcludeDeviceCommunication(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.tunnelExcludeDeviceCommunication)
    }

    static func getTunnelIncludedRoutes() -> [String] {
        userDefaults.stringArray(forKey: UserDefaultsKey.tunnelIncludedRoutes) ?? []
    }

    static func setTunnelIncludedRoutes(_ routes: [String]) {
        userDefaults.set(routes, forKey: UserDefaultsKey.tunnelIncludedRoutes)
    }

    static func getTunnelExcludedRoutes() -> [String] {
        userDefaults.stringArray(forKey: UserDefaultsKey.tunnelExcludedRoutes) ?? []
    }

    static func setTunnelExcludedRoutes(_ routes: [String]) {
        userDefaults.set(routes, forKey: UserDefaultsKey.tunnelExcludedRoutes)
    }

    static func getSyntheticAddressExcludedDomainSuffixes() -> [String] {
        userDefaults.stringArray(forKey: UserDefaultsKey.syntheticAddressExcludedDomainSuffixes) ?? []
    }

    static func setSyntheticAddressExcludedDomainSuffixes(_ suffixes: [String]) {
        userDefaults.set(suffixes, forKey: UserDefaultsKey.syntheticAddressExcludedDomainSuffixes)
    }

    /// User-configured IPv4 addresses that the ordinary DNS interception must
    /// leave alone (on top of the automatically exempted plain upstreams and
    /// bootstrap seeds).
    static func getDNSExemptServers() -> [String] {
        userDefaults.stringArray(forKey: UserDefaultsKey.dnsExemptServers) ?? []
    }

    static func setDNSExemptServers(_ servers: [String]) {
        userDefaults.set(servers, forKey: UserDefaultsKey.dnsExemptServers)
    }
    
    static func getBlockUDP() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.blockUDP)
    }

    static func setBlockUDP(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.blockUDP)
    }

    static func getQUICPolicy() -> QUICPolicy {
        userDefaults.string(forKey: UserDefaultsKey.quicPolicy).flatMap(QUICPolicy.init(rawValue:)) ?? .blocked
    }

    static func setQUICPolicy(_ value: QUICPolicy) {
        userDefaults.set(value.rawValue, forKey: UserDefaultsKey.quicPolicy)
    }

    static func getBlockWebRTC() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.blockWebRTC)
    }

    static func setBlockWebRTC(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.blockWebRTC)
    }

    static func getPreventDNSLeak() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.preventDNSLeak)
    }

    static func setPreventDNSLeak(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.preventDNSLeak)
    }

    static func getTrustedSSIDs() -> [String] {
        userDefaults.stringArray(forKey: UserDefaultsKey.trustedSSIDs) ?? []
    }

    static func setTrustedSSIDs(_ ssids: [String]) {
        userDefaults.set(ssids, forKey: UserDefaultsKey.trustedSSIDs)
    }

    static func getAlwaysTrustCellular() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.alwaysTrustCellular)
    }

    static func setAlwaysTrustCellular(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.alwaysTrustCellular)
    }

    static func getAlwaysUntrustCellular() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.alwaysUntrustCellular)
    }

    static func setAlwaysUntrustCellular(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.alwaysUntrustCellular)
    }

    static func getExperimentalEnabled() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.experimentalEnabled)
    }

    static func setExperimentalEnabled(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.experimentalEnabled)
    }

    static func getHideVPNIcon() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.hideVPNIcon)
    }

    static func setHideVPNIcon(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.hideVPNIcon)
    }

    static func getReflectionEnabled() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.reflectionEnabled)
    }

    static func setReflectionEnabled(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.reflectionEnabled)
    }

    static func getSubscriptionDNSMode() -> DNSMode {
        userDefaults.string(forKey: UserDefaultsKey.subscriptionDNSMode).flatMap(DNSMode.init(rawValue:)) ?? .default
    }

    static func setSubscriptionDNSMode(_ value: DNSMode) {
        userDefaults.set(value.rawValue, forKey: UserDefaultsKey.subscriptionDNSMode)
    }

    static func getSubscriptionDNSPlainServer() -> String {
        userDefaults.string(forKey: UserDefaultsKey.subscriptionDNSPlainServer)!
    }

    static func setSubscriptionDNSPlainServer(_ value: String) {
        userDefaults.set(value, forKey: UserDefaultsKey.subscriptionDNSPlainServer)
    }

    static func getSubscriptionDNSDoHURL() -> String {
        userDefaults.string(forKey: UserDefaultsKey.subscriptionDNSDoHURL)!
    }

    static func setSubscriptionDNSDoHURL(_ value: String) {
        userDefaults.set(value, forKey: UserDefaultsKey.subscriptionDNSDoHURL)
    }

    static func getLocalRequestDNSMode() -> DNSMode {
        userDefaults.string(forKey: UserDefaultsKey.localRequestDNSMode).flatMap(DNSMode.init(rawValue:)) ?? .default
    }

    static func setLocalRequestDNSMode(_ value: DNSMode) {
        userDefaults.set(value.rawValue, forKey: UserDefaultsKey.localRequestDNSMode)
    }

    static func getLocalRequestDNSPlainServer() -> String {
        userDefaults.string(forKey: UserDefaultsKey.localRequestDNSPlainServer)!
    }

    static func setLocalRequestDNSPlainServer(_ value: String) {
        userDefaults.set(value, forKey: UserDefaultsKey.localRequestDNSPlainServer)
    }

    static func getLocalRequestDNSDoHURL() -> String {
        userDefaults.string(forKey: UserDefaultsKey.localRequestDNSDoHURL)!
    }

    static func setLocalRequestDNSDoHURL(_ value: String) {
        userDefaults.set(value, forKey: UserDefaultsKey.localRequestDNSDoHURL)
    }

    static func getHostMappingsData() -> Data? {
        userDefaults.data(forKey: UserDefaultsKey.hostMappings)
    }

    static func setHostMappingsData(_ data: Data?) {
        if let data {
            userDefaults.set(data, forKey: UserDefaultsKey.hostMappings)
        } else {
            userDefaults.removeObject(forKey: UserDefaultsKey.hostMappings)
        }
    }

    static func getBootstrapDNS() -> DNSBootstrapPolicy {
        DNSBootstrapPolicy.parse(userDefaults.string(forKey: "bootstrapDNS") ?? "system") ?? .system
    }
    static func setBootstrapDNS(_ policy: DNSBootstrapPolicy) {
        userDefaults.set(policy.rendered, forKey: "bootstrapDNS")
    }

    static func getFallbackDNSMode() -> FallbackDNSMode {
        userDefaults.string(forKey: UserDefaultsKey.fallbackDNSMode).flatMap(FallbackDNSMode.init(rawValue:)) ?? .default
    }

    static func setFallbackDNSMode(_ value: FallbackDNSMode) {
        userDefaults.set(value.rawValue, forKey: UserDefaultsKey.fallbackDNSMode)
    }

    static func getFallbackDNSServer() -> String {
        userDefaults.string(forKey: UserDefaultsKey.fallbackDNSServer)!
    }

    static func setFallbackDNSServer(_ value: String) {
        userDefaults.set(value, forKey: UserDefaultsKey.fallbackDNSServer)
    }

    static func getProxyDNSMode() -> DNSMode {
        userDefaults.string(forKey: UserDefaultsKey.proxyDNSMode).flatMap(DNSMode.init(rawValue:)) ?? .default
    }

    static func setProxyDNSMode(_ value: DNSMode) {
        userDefaults.set(value.rawValue, forKey: UserDefaultsKey.proxyDNSMode)
    }

    static func getProxyDNSPlainServer() -> String {
        userDefaults.string(forKey: UserDefaultsKey.proxyDNSPlainServer)!
    }

    static func setProxyDNSPlainServer(_ value: String) {
        userDefaults.set(value, forKey: UserDefaultsKey.proxyDNSPlainServer)
    }

    static func getProxyDNSDoHURL() -> String {
        userDefaults.string(forKey: UserDefaultsKey.proxyDNSDoHURL)!
    }

    static func setProxyDNSDoHURL(_ value: String) {
        userDefaults.set(value, forKey: UserDefaultsKey.proxyDNSDoHURL)
    }

    static func getECHDNSMode() -> DNSMode {
        userDefaults.string(forKey: UserDefaultsKey.echDNSMode).flatMap(DNSMode.init(rawValue:)) ?? .default
    }

    static func setECHDNSMode(_ value: DNSMode) {
        userDefaults.set(value.rawValue, forKey: UserDefaultsKey.echDNSMode)
    }

    static func getECHDNSPlainServer() -> String {
        userDefaults.string(forKey: UserDefaultsKey.echDNSPlainServer)!
    }

    static func setECHDNSPlainServer(_ value: String) {
        userDefaults.set(value, forKey: UserDefaultsKey.echDNSPlainServer)
    }

    static func getECHDNSDoHURL() -> String {
        userDefaults.string(forKey: UserDefaultsKey.echDNSDoHURL)!
    }

    static func setECHDNSDoHURL(_ value: String) {
        userDefaults.set(value, forKey: UserDefaultsKey.echDNSDoHURL)
    }

    static func getSubscriptionDNSUpstream() -> DNSUpstream {
        let capture = RuntimePreferenceContext.capture ?? RuntimePreferenceCapture(runtimePreferences())
        return RuntimePreferenceContext.$capture.withValue(capture) {
            DNSUpstream(
                mode: getSubscriptionDNSMode(),
                plainServer: getSubscriptionDNSPlainServer(),
                dohURL: getSubscriptionDNSDoHURL()
            )
        }
    }
    
    static func getLocalRequestDNSUpstream() -> DNSUpstream {
        let capture = RuntimePreferenceContext.capture ?? RuntimePreferenceCapture(runtimePreferences())
        return RuntimePreferenceContext.$capture.withValue(capture) {
            DNSUpstream(
                mode: getLocalRequestDNSMode(),
                plainServer: getLocalRequestDNSPlainServer(),
                dohURL: getLocalRequestDNSDoHURL()
            )
        }
    }
    
    static func getFallbackDNSUpstream() -> DNSUpstream {
        let capture = RuntimePreferenceContext.capture ?? RuntimePreferenceCapture(runtimePreferences())
        return RuntimePreferenceContext.$capture.withValue(capture) {
            switch getFallbackDNSMode() {
            case .default: return .defaultPlain
            case .plain: return DNSUpstream.parsePlain(getFallbackDNSServer()) ?? .defaultPlain
            }
        }
    }

    static func getProxyDNSUpstream() -> DNSUpstream {
        let capture = RuntimePreferenceContext.capture ?? RuntimePreferenceCapture(runtimePreferences())
        return RuntimePreferenceContext.$capture.withValue(capture) {
            DNSUpstream(
                mode: getProxyDNSMode(),
                plainServer: getProxyDNSPlainServer(),
                dohURL: getProxyDNSDoHURL()
            )
        }
    }

    static func getECHDNSUpstream() -> DNSUpstream {
        let capture = RuntimePreferenceContext.capture ?? RuntimePreferenceCapture(runtimePreferences())
        return RuntimePreferenceContext.$capture.withValue(capture) {
            DNSUpstream(
                mode: getECHDNSMode(),
                plainServer: getECHDNSPlainServer(),
                dohURL: getECHDNSDoHURL()
            )
        }
    }
    
    static func getRemnawaveHWID() -> String {
        let value = userDefaults.string(forKey: UserDefaultsKey.remnawaveHWID) ?? UUID().uuidString
        // Persist the registered fallback on first use so per-subscription opt-in
        // keeps the same device identity across application launches.
        userDefaults.set(value, forKey: UserDefaultsKey.remnawaveHWID)
        return value
    }

    static func getMITMEnabled() -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.mitmEnabled)
    }

    static func setMITMEnabled(_ value: Bool) {
        userDefaults.set(value, forKey: UserDefaultsKey.mitmEnabled)
    }
}
