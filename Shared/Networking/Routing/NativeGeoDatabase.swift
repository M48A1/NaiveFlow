import Foundation

/// Explicit document-owned data, not an implicit external database. Prefixes
/// use longest-match precedence; named site lists contain domain suffixes.
nonisolated struct NativeGeoDatabase: Codable, Equatable, Sendable, GeoIPLookup, GeoSiteLookup {
    struct Network: Codable, Equatable, Sendable {
        let prefix: CIDRPrefix
        let country: String?
        let asn: Int?
    }
    var networks: [Network] = []
    var sites: [String: [String]] = [:]

    func countryCode(for address: String) -> String? {
        networks.filter { $0.country != nil && $0.prefix.contains(address) }
            .max { $0.prefix.prefixLength < $1.prefix.prefixLength }?.country
    }
    func asn(for address: String) -> Int? {
        networks.filter { $0.asn != nil && $0.prefix.contains(address) }
            .max { $0.prefix.prefixLength < $1.prefix.prefixLength }?.asn
    }
    func matches(host: String, tag: String) -> Bool {
        let name = OrderedRouteMatcher.normalizedHost(host) ?? ""
        return (sites[tag] ?? []).contains { name == $0 || name.hasSuffix("." + $0) }
    }
    func contains(tag: String) -> Bool { sites[tag] != nil }
}
