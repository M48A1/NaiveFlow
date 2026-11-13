import Foundation

nonisolated enum RouteMatching {

    /// Returns the input unchanged (no allocation) when already lowercase ASCII;
    /// otherwise falls back to `lowercased()` to match load-time folding.
    static func asciiLowercasedIfNeeded(_ input: String) -> String {
        for b in input.utf8 where (b >= 0x41 && b <= 0x5A) || b >= 0x80 {
            return input.lowercased()
        }
        return input
    }

    /// Parses "A.B.C.D/prefix" into (network, prefixLen) with host bits zeroed.
    static func parseIPv4CIDR(_ cidr: String) -> (network: UInt32, prefixLen: Int)? {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefixLen = Int(parts[1]),
              prefixLen >= 0, prefixLen <= 32,
              let ip = parseIPv4(String(parts[0])) else { return nil }
        let mask: UInt32 = prefixLen == 0 ? 0 : ~UInt32(0) << (32 - prefixLen)
        return (network: ip & mask, prefixLen: prefixLen)
    }

    /// Parses a dotted-quad IPv4 string to host-order UInt32.
    static func parseIPv4(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            result = result << 8 | UInt32(byte)
        }
        return result
    }

}
