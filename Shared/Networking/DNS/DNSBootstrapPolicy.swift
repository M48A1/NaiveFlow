import Foundation

/// Only resolves names of encrypted DNS endpoints. Numeric seed servers cannot
/// depend on another resolver, so the bootstrap path cannot recurse into DoH.
nonisolated enum DNSBootstrapPolicy: Equatable, Sendable {
    case system
    case servers([String])

    var rendered: String {
        switch self { case .system: "system"; case .servers(let values): values.joined(separator: ", ") }
    }
    var isSystem: Bool { if case .system = self { true } else { false } }
    static func parse(_ source: String) -> Self? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased() == "system" { return .system }
        let values = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !values.isEmpty, values.count <= 8 else { return nil }
        var servers: [String] = []
        for value in values {
            guard let address = DNSUpstream.canonicalIPv4(value) else { return nil }
            if !servers.contains(address) { servers.append(address) }
        }
        return .servers(servers)
    }

    func endpointAddresses(for host: String,
        lookup: @Sendable (String, String) async throws -> [String]) async throws -> [String] {
        try IPv4Only.requireHost(host)
        let bare = host
        if DNSName.isIPAddress(bare) { return [bare] }
        guard case .servers(let seeds) = self else { return [bare] }
        var lastFailure: (any Error)?
        for seed in seeds {
            try Task.checkCancellation()
            do {
                let addresses = Array(try await lookup(bare, seed).filter { DNSName.isIPAddress($0) }.prefix(8))
                if !addresses.isEmpty { return addresses }
            } catch is CancellationError { throw CancellationError() }
            catch { lastFailure = error }
        }
        throw lastFailure ?? RuleProxyError.dns(.noAddresses(host: bare))
    }
}
