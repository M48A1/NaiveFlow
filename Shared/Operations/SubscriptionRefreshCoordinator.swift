//
//  SubscriptionRefreshCoordinator.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation

/// Serialises refresh commits per resource so a slow, older fetch can never
/// overwrite the content a newer request has already written.
///
/// Each `begin` hands out a monotonically increasing ticket and makes it the
/// current one for that resource key; only the holder of the current ticket may
/// commit. `end` forgets the key once its latest refresh finishes, so the table
/// stays bounded by the resources actually being refreshed.
///
/// Runs on the main actor alongside the stores it guards, so the `isCurrent`
/// check and the synchronous commit that follows it cannot interleave with
/// another refresh. Refreshing the *same* resource from two pages (e.g. "Update
/// All" on the data page plus a detail-page refresh) therefore resolves to the
/// newest result instead of whichever response happens to land last. The key is
/// generic so proxy subscriptions, modules and rule sets share one primitive.
@MainActor
final class RefreshTicketCoordinator<Key: Hashable> {
    private var nextTicket: UInt64 = 0
    private var current: [Key: UInt64] = [:]

    /// Claims the next ticket for `key`, superseding any refresh already in
    /// flight for the same resource.
    func begin(_ key: Key) -> UInt64 {
        nextTicket &+= 1
        current[key] = nextTicket
        return nextTicket
    }

    /// Whether `ticket` is still the newest refresh for `key`.
    func isCurrent(_ key: Key, ticket: UInt64) -> Bool {
        current[key] == ticket
    }

    /// Releases `ticket` after it commits or is superseded. A ticket that has
    /// already lost to a newer one leaves the newer entry untouched.
    func end(_ key: Key, ticket: UInt64) {
        if current[key] == ticket {
            current.removeValue(forKey: key)
        }
    }
}

/// Proxy-subscription refresh coordination (keyed by subscription id).
typealias SubscriptionRefreshCoordinator = RefreshTicketCoordinator<UUID>

