import Foundation

/// App-wide preferences for manual probes. Automatic policy-group probes keep
/// their own targets and scheduling from the configuration file.
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

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return .default }
        return settings.effective
    }

    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(effective), forKey: Self.storageKey)
    }
}
