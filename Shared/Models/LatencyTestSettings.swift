import Foundation

/// Shared defaults for manual and automatic probes. Explicit group URLs override
/// the default target; each group keeps its own interval.
nonisolated struct LatencyTestSettings: Codable, Equatable, Sendable {
    static let defaultURL = "http://captive.apple.com/"
    static let timeoutRange = 1...30
    static let concurrencyRange = 1...16
    static let storageKey = "manualLatencyTestSettings"
    static let `default` = LatencyTestSettings()

    var url = defaultURL
    var timeoutSeconds = 10
    var concurrency = 8

    var isValid: Bool {
        guard Self.timeoutRange.contains(timeoutSeconds), Self.concurrencyRange.contains(concurrency),
              let components = URLComponents(string: url),
              components.user == nil, components.password == nil, components.fragment == nil,
              let target = LatencyTarget(url: url), !target.host.contains(where: \.isWhitespace) else { return false }
        return target.port > 0
    }

    var effective: Self { isValid ? self : .default }
    var target: LatencyTarget { LatencyTarget(url: effective.url) ?? .captivePortal }
    var timeout: Duration { .seconds(effective.timeoutSeconds) }

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: AWCore.Identifier.appGroupSuite) ?? .standard
    }

    static func load(from defaults: UserDefaults? = nil, legacyDefaults: UserDefaults? = nil) -> Self {
        let store = defaults ?? sharedDefaults
        let legacy = legacyDefaults ?? (defaults == nil ? UserDefaults.standard : nil)
        // Preserve settings saved before preferences were shared with the tunnel.
        if store.data(forKey: storageKey) == nil, let data = legacy?.data(forKey: storageKey),
           let migrated = try? JSONDecoder().decode(Self.self, from: data), migrated.isValid {
            try? migrated.save(to: store)
        }
        guard let data = store.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return .default }
        return settings.effective
    }

    func save(to defaults: UserDefaults? = nil) throws {
        (defaults ?? Self.sharedDefaults).set(try JSONEncoder().encode(effective), forKey: Self.storageKey)
    }
}
