import Foundation
import Synchronization

/// Property-list values used by the kernel. Missing values are explicit, so a
/// pinned version never falls through to preferences from a newer document.
nonisolated enum RuntimePreferenceValue: Codable, Equatable, Sendable {
    case absent, boolean(Bool), string(String), strings([String]), data(Data)

    init(_ value: Any?) {
        switch value {
        case let value as Data: self = .data(value)
        case let value as String: self = .string(value)
        case let value as [String]: self = .strings(value)
        case let value as Bool: self = .boolean(value)
        default: self = .absent
        }
    }

    var object: Any? {
        switch self {
        case .absent: nil
        case .boolean(let value): value
        case .string(let value): value
        case .strings(let value): value
        case .data(let value): value
        }
    }
}

nonisolated final class RuntimePreferenceCapture: Sendable {
    let values: Mutex<[String: RuntimePreferenceValue]>
    init(_ values: [String: RuntimePreferenceValue]) { self.values = Mutex(values) }
}

nonisolated enum RuntimePreferenceContext {
    @TaskLocal static var capture: RuntimePreferenceCapture?
}

/// A pinned read view for the extension, and a task-local recording target for
/// the host compiler. Existing AWCore getters/setters remain the module adapters.
nonisolated final class RuntimePreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private let pinned = Mutex<[String: RuntimePreferenceValue]?>(nil)

    init(defaults: UserDefaults) { self.defaults = defaults }

    func install(_ values: [String: RuntimePreferenceValue]?) {
        pinned.withLock { $0 = values }
    }

    /// Installs a version's read view: pinned when the bundle is an immutable
    /// text version, and unpinned (`nil`) for a manual baseline so live
    /// UserDefaults drive reads again after a rollback to manual mode.
    func install(pins: Bool, values: [String: RuntimePreferenceValue]) {
        install(pins ? values : nil)
    }

    func snapshot(keys: [String]) -> [String: RuntimePreferenceValue] {
        let version = RuntimePreferenceContext.capture?.values.withLock { $0 } ?? pinned.withLock { $0 }
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, version?[key] ?? RuntimePreferenceValue(defaults.object(forKey: key)))
        })
    }

    func object(forKey key: String) -> Any? {
        if let capture = RuntimePreferenceContext.capture,
           let value = capture.values.withLock({ $0[key] }) { return value.object }
        if let value = pinned.withLock({ $0?[key] }) { return value.object }
        return defaults.object(forKey: key)
    }

    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }

    func set(_ value: Any?, forKey key: String) {
        if let capture = RuntimePreferenceContext.capture {
            capture.values.withLock { $0[key] = RuntimePreferenceValue(value) }
        } else {
            defaults.set(value, forKey: key)
        }
    }

    func removeObject(forKey key: String) { set(nil, forKey: key) }
}
