import Foundation
import Synchronization

/// A bounded, in-memory history shared by all request producers.
nonisolated final class RequestLog: Sendable {
    typealias Entry = TunnelRequestEntry
    static let retentionInterval: TimeInterval = 300
    static let maxEntries = 50
    static let duplicateInterval: TimeInterval = 10

    private struct StoredEntry {
        let entry: Entry
        let deduplicationKey: String?
    }
    private let entries = Mutex<[StoredEntry]>([])
    private let defaultRouteTarget = Mutex<RouteTarget>(.direct)

    func setDefaultRouteTarget(_ target: RouteTarget) {
        defaultRouteTarget.withLock { $0 = target }
    }

    func record(
        protocol: TunnelRequestProtocol,
        host: String,
        port: UInt16,
        routeTarget: RouteTarget,
        ruleSetName: String? = nil,
        outbound: TunnelRequestOutbound? = nil,
        blockReason: TunnelRequestBlockReason? = nil,
        isQUIC: Bool? = nil,
        deduplicationKey: String? = nil,
        now: TimeInterval = CFAbsoluteTimeGetCurrent()
    ) {
        let reason = blockReason ?? (routeTarget == .reject ? .rule : nil)
        let entry = Entry(timestamp: now, protocol: `protocol`, host: host, port: port,
            routeTarget: routeTarget, ruleSetName: ruleSetName,
            defaultRouteTarget: defaultRouteTarget.withLock { $0 },
            outbound: outbound, blockReason: reason, isQUIC: isQUIC)
        entries.withLock { entries in
            Self.compact(&entries, now: now)
            // Only visible, recent entries suppress duplicates. Eviction or expiration
            // must never leave a separate suppression cache hiding new requests.
            if let key = deduplicationKey, entries.contains(where: {
                $0.deduplicationKey == key && $0.entry.blockReason == reason &&
                $0.entry.routeTarget == routeTarget &&
                ($0.entry.ruleSetName == nil || ruleSetName == nil || $0.entry.ruleSetName == ruleSetName) &&
                now >= $0.entry.timestamp && now - $0.entry.timestamp < Self.duplicateInterval
            }) { return }
            entries.append(StoredEntry(entry: entry, deduplicationKey: deduplicationKey))
            Self.compact(&entries, now: now)
        }
    }

    func snapshot(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> [Entry] {
        entries.withLock { entries in
            Self.compact(&entries, now: now)
            return entries.map(\.entry)
        }
    }

    private static func compact(_ entries: inout [StoredEntry], now: TimeInterval) {
        entries.removeAll { $0.entry.timestamp < now - retentionInterval }
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }
}
