import Foundation
import Darwin

/// Device-local settings; changes take effect when the VPN reconnects.
nonisolated struct LANProxySettings: Codable, Equatable, Sendable {
    var enabled = false
    var port: UInt16 = 8080

    static func load() -> Self {
        guard let data = AWCore.getLANProxySettingsData() else { return Self() }
        // Invalid stored settings must never broaden access.
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }

    func save() throws {
        guard port >= 1024 else {
            throw LANProxyError.invalidConfiguration
        }
        AWCore.setLANProxySettingsData(try JSONEncoder().encode(self))
    }
}

nonisolated enum LANProxyError: Error {
    case invalidConfiguration, malformedRequest, unsupportedCommand, closed, timedOut, unavailable
}

/// Fixed Wi-Fi/private IPv4 scope; no user-maintained address list.
nonisolated enum LANProxyNetwork {
    static func isPrivate(_ address: String) -> Bool {
        guard let ip = IPRoute(address), ip.prefixLength == 32 else { return false }
        return ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].contains {
            let range = IPRoute($0)!
            return ip.network & range.mask == range.network
        }
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
    static func validateHost(_ host: String) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              !host.hasPrefix("."), !host.hasSuffix("..") else {
            throw LANProxyError.malformedRequest
        }
    }
}
