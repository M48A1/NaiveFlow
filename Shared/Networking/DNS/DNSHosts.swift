//
//  DNSHosts.swift
//  RuleProxy
//
//  Created by NodePassProject on 10/10/26.
//

import Foundation
import Synchronization

nonisolated final class DNSHosts: Sendable {
    static let shared = DNSHosts()

    private struct Entry {
        var ipv4: [String] = []
    }

    private let table = Mutex<[String: Entry]?>(nil)

    func addresses(for host: String, family: DNSAddressFamily) -> [String]? {
        var key = DNSName.cacheKey(for: host)
        if key.hasSuffix(".") { key.removeLast() }
        return table.withLock { table -> [String]? in
            if table == nil { table = Self.build(HostMapping.load()) }
            guard let entry = table?[key] else { return nil }
            return entry.ipv4
        }
    }

    func invalidate() {
        table.withLock { $0 = nil }
    }

    private static func build(_ mappings: [HostMapping]) -> [String: Entry] {
        var table: [String: Entry] = [:]
        for mapping in mappings {
            guard let host = DNSName.normalizedHost(mapping.host),
                  let address = HostMapping.canonicalAddress(mapping.address)
            else { continue }
            var entry = table[host, default: Entry()]
            if !entry.ipv4.contains(address) { entry.ipv4.append(address) }
            table[host] = entry
        }
        return table
    }
}
