import Foundation

nonisolated enum DNSAddressFamily: Sendable, Hashable {
    case ipv4
    func admits(_ address: String) -> Bool { DNSUpstream.canonicalIPv4(address) != nil }
}
