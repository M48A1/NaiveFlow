import Foundation

/// Version-owned IPv4 data. Runtime-only indexes are rebuilt once on decode.
nonisolated struct NativeGeoDatabase: Codable, Equatable, Sendable, GeoIPLookup, GeoSiteLookup {
    struct Network: Codable, Equatable, Sendable {
        let prefix: CIDRPrefix
        let country: String?
        let asn: Int?
    }
    struct Domain: Codable, Equatable, Hashable, Sendable {
        enum Kind: String, Codable, Hashable, Sendable { case suffix, full, keyword, regex }
        let kind: Kind
        let value: String
    }
    struct Source: Codable, Equatable, Sendable {
        let url: String
        let sha256: String
        let loadedAt: Date
        let format: String
    }
    static let maximumEntries = 2_000_000
    var networks: [Network] = [] { didSet { index = nil } }
    var sites: [String: [String]] = [:] { didSet { index = nil } }
    var domains: [String: [Domain]] = [:] { didSet { index = nil } }
    var sources: [Source] = []
    private var index: GeoLookupIndex?

    init() {}
    private enum CodingKeys: String, CodingKey { case networks, sites, domains, sources }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        networks = try c.decodeIfPresent([Network].self, forKey: .networks) ?? []
        sites = try c.decodeIfPresent([String: [String]].self, forKey: .sites) ?? [:]
        domains = try c.decodeIfPresent([String: [Domain]].self, forKey: .domains) ?? [:]
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        try validate()
        prepareIndex()
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.networks == rhs.networks && lhs.sites == rhs.sites && lhs.domains == rhs.domains && lhs.sources == rhs.sources
    }
    mutating func prepareIndex() { index = GeoLookupIndex(self) }
    var entryCount: Int { networks.count + sites.values.reduce(0) { $0 + $1.count } + domains.values.reduce(0) { $0 + $1.count } }
    func validate() throws {
        guard entryCount <= Self.maximumEntries, sources.count <= 32 else { throw NativeGeoFailure("Geo database exceeds resource limits.") }
        for n in networks {
            guard n.prefix.bytes.count == 4, (0...32).contains(n.prefix.prefixLength),
                  n.country != nil || n.asn != nil, n.asn.map({ $0 > 0 }) ?? true else { throw NativeGeoFailure("Invalid GeoIP network.") }
        }
        for (tag, values) in sites {
            guard !tag.isEmpty else { throw NativeGeoFailure("Empty GeoSite tag.") }
            for value in values { guard DNSName.normalizedHost(value) == value else { throw NativeGeoFailure("Invalid GeoSite suffix.") } }
        }
        for (tag, values) in domains {
            guard !tag.isEmpty else { throw NativeGeoFailure("Empty GeoSite tag.") }
            for d in values {
                guard !d.value.isEmpty, d.value.utf8.count <= 4096 else { throw NativeGeoFailure("Invalid GeoSite domain.") }
                switch d.kind {
                case .full, .suffix:
                    guard DNSName.normalizedHost(d.value) == d.value else { throw NativeGeoFailure("Invalid GeoSite hostname.") }
                case .regex: _ = try NSRegularExpression(pattern: d.value)
                case .keyword: break
                }
            }
        }
    }
    func countryCode(for address: String) -> String? { (index ?? GeoLookupIndex(self)).lookup(address).country }
    func asn(for address: String) -> Int? { (index ?? GeoLookupIndex(self)).lookup(address).asn }
    func matches(host: String, tag: String) -> Bool { (index ?? GeoLookupIndex(self)).matches(host: host, tag: tag) }
    func evaluate(host: String, tag: String, regexDeadline: ContinuousClock.Instant) -> RoutingRegex.Result {
        (index ?? GeoLookupIndex(self)).evaluate(host: host, tag: tag, regexDeadline: regexDeadline)
    }
    func contains(tag: String) -> Bool { sites[tag] != nil || domains[tag] != nil }
    func hasCountry(_ country: String) -> Bool { (index ?? GeoLookupIndex(self)).countries.contains(country) }
    func hasASN(_ asn: Int) -> Bool { (index ?? GeoLookupIndex(self)).asns.contains(asn) }
}

nonisolated struct NativeGeoFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Prefix-length hash buckets use at most 33 probes, independent of DB size.
/// Domain suffixes use label probes; keywords use Aho-Corasick. Regexes are
/// compiled once and evaluated only after indexed conditions fail.
nonisolated private final class GeoLookupIndex: Sendable {
    struct Value: Sendable { var country: String?; var asn: Int? }
    struct Sites: Sendable {
        var suffixes: Set<String> = []
        var exact: Set<String> = []
        var keywords = GeoKeywordIndex([])
        var regexes: [NSRegularExpression] = []
    }
    let countries: Set<String>
    let asns: Set<Int>
    let prefixes: [Int: [UInt32: Value]]
    let lengths: [Int]
    let tags: [String: Sites]
    init(_ database: NativeGeoDatabase) {
        countries = Set(database.networks.compactMap(\.country))
        asns = Set(database.networks.compactMap(\.asn))
        var buckets: [Int: [UInt32: Value]] = [:]
        for n in database.networks {
            guard n.prefix.bytes.count == 4, (0...32).contains(n.prefix.prefixLength) else { continue }
            let key = Self.number(n.prefix.bytes) & Self.mask(n.prefix.prefixLength)
            var v = buckets[n.prefix.prefixLength]?[key] ?? Value()
            // First declaration wins for equal-length ties, as in legacy lookup.
            if v.country == nil { v.country = n.country }
            if v.asn == nil { v.asn = n.asn }
            buckets[n.prefix.prefixLength, default: [:]][key] = v
        }
        prefixes = buckets
        lengths = buckets.keys.sorted(by: >)
        var result: [String: Sites] = [:]
        for tag in Set(database.sites.keys).union(database.domains.keys) {
            var entry = Sites()
            entry.suffixes = Set(database.sites[tag] ?? [])
            var keywords: [String] = []
            for d in database.domains[tag] ?? [] {
                switch d.kind {
                case .suffix: entry.suffixes.insert(d.value)
                case .full: entry.exact.insert(d.value)
                case .keyword: keywords.append(d.value)
                case .regex: if let regex = try? NSRegularExpression(pattern: d.value) { entry.regexes.append(regex) }
                }
            }
            entry.keywords = GeoKeywordIndex(keywords)
            result[tag] = entry
        }
        tags = result
    }
    static func number(_ b: [UInt8]) -> UInt32 { UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]) }
    static func mask(_ length: Int) -> UInt32 { length == 0 ? 0 : UInt32.max << (32 - length) }
    func lookup(_ address: String) -> Value {
        guard let p = CIDRPrefix.parse(address), !address.contains("/") else { return Value() }
        let ip = Self.number(p.bytes)
        var result = Value()
        for length in lengths {
            guard let v = prefixes[length]?[ip & Self.mask(length)] else { continue }
            if result.country == nil { result.country = v.country }
            if result.asn == nil { result.asn = v.asn }
            if result.country != nil && result.asn != nil { break }
        }
        return result
    }
    func matches(host: String, tag: String) -> Bool {
        evaluate(host: host, tag: tag, regexDeadline: ContinuousClock.now + RoutingRegex.matchBudget) == .matched
    }
    func evaluate(host: String, tag: String, regexDeadline: ContinuousClock.Instant) -> RoutingRegex.Result {
        guard let entry = tags[tag], let name = OrderedRouteMatcher.normalizedHost(host) else { return .noMatch }
        if entry.exact.contains(name) { return .matched }
        var suffix = name[...]
        while !suffix.isEmpty {
            if entry.suffixes.contains(String(suffix)) { return .matched }
            guard let dot = suffix.firstIndex(of: ".") else { break }
            suffix = suffix[suffix.index(after: dot)...]
        }
        if entry.keywords.matches(name) { return .matched }
        for regex in entry.regexes {
            let result = RoutingRegex.evaluate(regex, in: name, deadline: regexDeadline)
            if result != .noMatch { return result }
        }
        return .noMatch
    }
}

nonisolated private struct GeoKeywordIndex: Sendable {
    struct Node: Sendable { var edges: [UInt8: Int] = [:]; var failure = 0; var terminal = false }
    let nodes: [Node]
    init(_ words: [String]) {
        var tree = [Node()]
        for word in words {
            var state = 0
            for byte in word.utf8 {
                if let next = tree[state].edges[byte] { state = next }
                else { let next = tree.count; tree.append(Node()); tree[state].edges[byte] = next; state = next }
            }
            tree[state].terminal = true
        }
        var queue = Array(tree[0].edges.values); var head = 0
        while head < queue.count {
            let state = queue[head]; head += 1
            for (byte, child) in tree[state].edges {
                var failure = tree[state].failure
                while failure != 0 && tree[failure].edges[byte] == nil { failure = tree[failure].failure }
                tree[child].failure = tree[failure].edges[byte] ?? 0
                tree[child].terminal = tree[child].terminal || tree[tree[child].failure].terminal
                queue.append(child)
            }
        }
        nodes = tree
    }
    func matches(_ text: String) -> Bool {
        var state = 0
        for byte in text.utf8 {
            while state != 0 && nodes[state].edges[byte] == nil { state = nodes[state].failure }
            state = nodes[state].edges[byte] ?? 0
            if nodes[state].terminal { return true }
        }
        return false
    }
}
