//
//  DNSHosts.swift
//  NaiveFlow
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

    private struct Table {
        var exact: [String: Entry] = [:]
        var wildcards: [String: Entry] = [:]
    }

    private let table = Mutex<Table?>(nil)

    func addresses(for host: String, family: DNSAddressFamily) -> [String]? {
        var key = DNSName.cacheKey(for: host)
        if key.hasSuffix(".") { key.removeLast() }
        return table.withLock { table -> [String]? in
            if table == nil { table = Self.build(HostMapping.load()) }
            guard let table else { return nil }
            if let entry = table.exact[key] { return entry.ipv4 }
            for (suffix, entry) in table.wildcards {
                if key == suffix || key.hasSuffix("." + suffix) {
                    return entry.ipv4
                }
            }
            return nil
        }
    }

    func invalidate() {
        table.withLock { $0 = nil }
    }

    private static func build(_ mappings: [HostMapping]) -> Table {
        var table = Table()
        for mapping in mappings {
            guard let address = HostMapping.canonicalAddress(mapping.address) else { continue }
            var host = mapping.host.trimmingCharacters(in: .whitespaces).lowercased()
            if host.hasSuffix(".") { host.removeLast() }
            if host.hasPrefix("*.") {
                guard let suffix = DNSName.normalizedHost(String(host.dropFirst(2))) else { continue }
                var entry = table.wildcards[suffix, default: Entry()]
                if !entry.ipv4.contains(address) { entry.ipv4.append(address) }
                table.wildcards[suffix] = entry
            } else {
                guard let normalized = DNSName.normalizedHost(host) else { continue }
                var entry = table.exact[normalized, default: Entry()]
                if !entry.ipv4.contains(address) { entry.ipv4.append(address) }
                table.exact[normalized] = entry
            }
        }
        return table
    }
}
