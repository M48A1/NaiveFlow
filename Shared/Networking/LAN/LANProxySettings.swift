import Foundation
import Darwin

/// Device-local settings; changes take effect when the VPN reconnects.
nonisolated struct LANProxySettings: Codable, Equatable, Sendable {
    var enabled = false
    var port: UInt16 = 8080
    var allowedClients: [String] = []

    static func load() -> Self {
        guard let data = AWCore.getLANProxySettingsData() else { return Self() }
        // Invalid stored settings must never broaden access.
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }

    func save() throws {
        guard port >= 1024, allowedClients.allSatisfy({ IPRoute($0) != nil }) else {
            throw LANProxyError.invalidConfiguration
        }
        AWCore.setLANProxySettingsData(try JSONEncoder().encode(self))
    }
}

nonisolated enum LANProxyError: Error {
    case invalidConfiguration, malformedRequest, unsupportedCommand, closed, timedOut, unavailable
}

/// Both the local binding and the peer must be private IPv4 addresses.
/// Empty/invalid ACLs deny access; no DNS lookup is performed for ACL entries.
nonisolated struct LANProxyACL: Sendable {
    private let routes: [IPRoute]
    private let valid: Bool

    init(_ entries: [String]) {
        routes = entries.compactMap(IPRoute.init)
        valid = routes.count == entries.count
    }

    static func isPrivate(_ address: String) -> Bool {
        guard let ip = IPRoute(address), ip.prefixLength == 32 else { return false }
        return ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].contains {
            let range = IPRoute($0)!
            return ip.network & range.mask == range.network
        }
    }

    func allows(_ address: String) -> Bool {
        guard valid, Self.isPrivate(address), let ip = IPRoute(address) else { return false }
        return routes.contains { ip.network & $0.mask == $0.network }
    }

    static func wifiAddress() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == "en0",
                  let address = entry.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_INET,
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            if isPrivate(value) { return value }
        }
        return nil
    }
}

nonisolated enum LANProxyRequest {
    static func connectTarget(_ header: Data) throws -> (String, UInt16) {
        guard let text = String(data: header, encoding: .utf8),
              let first = text.components(separatedBy: "\r\n").first else {
            throw LANProxyError.malformedRequest
        }
        let words = first.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[0] == "CONNECT",
              words[2] == "HTTP/1.1" || words[2] == "HTTP/1.0" else {
            throw LANProxyError.unsupportedCommand
        }
        let authority = words[1].split(separator: ":", omittingEmptySubsequences: false)
        guard authority.count == 2, let port = UInt16(authority[1]), port > 0 else {
            throw LANProxyError.malformedRequest
        }
        let host = String(authority[0])
        try validateHost(host)
        return (host, port)
    }

    static func validateHost(_ host: String) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              !host.hasPrefix("."), !host.hasSuffix("..") else {
            throw LANProxyError.malformedRequest
        }
    }
}
