import Foundation
import Synchronization

/// A bounded, in-memory history shared by all request producers.
nonisolated final class RequestLog: Sendable {
    typealias Entry = TunnelRequestEntry
    static let retentionInterval: TimeInterval = 300
    static let maxEntries = 500
    static let maxStoredBytes = 512 * 1024
    static let duplicateInterval: TimeInterval = 10

    private struct StoredEntry {
        let entry: Entry
        let deduplicationKey: String?
        let byteCost: Int
    }
    private struct State {
        var entries: [StoredEntry] = []
        var bytes = 0
    }
    private let state = Mutex(State())
    private let byteLimit: Int

    init(byteLimit: Int = RequestLog.maxStoredBytes) {
        self.byteLimit = max(0, byteLimit)
    }

    /// Payload accounting, not a measurement of allocator/process footprint.
    var storedBytes: Int { state.withLock { $0.bytes } }
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
        activityID: UUID? = nil,
        resolvedAddress: String? = nil,
        resolutionPurpose: String? = nil,
        now: TimeInterval = CFAbsoluteTimeGetCurrent()
    ) {
        let reason = blockReason ?? (routeTarget == .reject ? .rule : nil)
        let entry = Entry(timestamp: now, protocol: `protocol`, host: host, port: port,
            routeTarget: routeTarget, ruleSetName: ruleSetName,
            defaultRouteTarget: defaultRouteTarget.withLock { $0 },
            outbound: outbound, blockReason: reason, isQUIC: isQUIC, activityID: activityID,
            resolvedAddress: resolvedAddress, resolutionPurpose: resolutionPurpose)
        let byteCost = MemoryLayout<StoredEntry>.stride
            + host.utf8.count + (ruleSetName?.utf8.count ?? 0)
            + (outbound?.name.utf8.count ?? 0) + (resolvedAddress?.utf8.count ?? 0)
            + (resolutionPurpose?.utf8.count ?? 0) + (deduplicationKey?.utf8.count ?? 0)
        state.withLock { state in
            Self.compact(&state, now: now)
            // Do not let a single oversized diagnostic displace the whole history.
            guard byteCost <= byteLimit else { return }
            // Only visible, recent entries suppress duplicates. Eviction or expiration
            // must never leave a separate suppression cache hiding new requests.
            if let key = deduplicationKey, state.entries.contains(where: {
                $0.deduplicationKey == key && $0.entry.blockReason == reason &&
                $0.entry.routeTarget == routeTarget &&
                ($0.entry.ruleSetName == nil || ruleSetName == nil || $0.entry.ruleSetName == ruleSetName) &&
                now >= $0.entry.timestamp && now - $0.entry.timestamp < Self.duplicateInterval
            }) { return }
            state.entries.append(StoredEntry(entry: entry, deduplicationKey: deduplicationKey, byteCost: byteCost))
            state.bytes += byteCost
            var removeCount = 0
            while state.entries.count - removeCount > Self.maxEntries || state.bytes > byteLimit {
                state.bytes -= state.entries[removeCount].byteCost
                removeCount += 1
            }
            if removeCount > 0 { state.entries.removeFirst(removeCount) }
        }
    }

    func snapshot(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> [Entry] {
        state.withLock { state in
            Self.compact(&state, now: now)
            return state.entries.map(\.entry)
        }
    }

    private static func compact(_ state: inout State, now: TimeInterval) {
        var removedBytes = 0
        state.entries.removeAll {
            guard $0.entry.timestamp < now - retentionInterval else { return false }
            removedBytes += $0.byteCost
            return true
        }
        state.bytes -= removedBytes
        if state.entries.isEmpty {
            state.entries = []
            state.bytes = 0
        }
    }
}
