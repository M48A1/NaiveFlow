import Foundation

/// Explicit per-script API contract. Missing metadata defaults to Surge.
nonisolated enum MITMScriptDialect: String, Codable, Sendable, CaseIterable {
    case surge
    case quantumultX = "quantumult-x"

    var binaryValue: UInt8 { self == .surge ? 0 : 1 }
    init?(binaryValue: UInt8) {
        switch binaryValue {
        case 0: self = .surge
        case 1: self = .quantumultX
        default: return nil
        }
    }
}
