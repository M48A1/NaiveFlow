//
//  SubscriptionRefreshCoordinator.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation

/// Serialises refresh commits per subscription so a slow, older fetch can never
/// overwrite the nodes or metadata a newer request has already written.
///
/// Each `begin` hands out a monotonically increasing ticket and makes it the
/// current one for that subscription id; only the holder of the current ticket
/// may commit. `end` forgets the id once its latest refresh finishes, so the
/// table stays bounded by the subscriptions actually being refreshed.
///
/// Runs on the main actor alongside the stores it guards, so the `isCurrent`
/// check and the synchronous commit that follows it cannot interleave with
/// another refresh. Refreshing the *same* subscription from two pages (the
/// proxies list and the data page) therefore resolves to the newest result
/// instead of whichever response happens to land last.
@MainActor
final class SubscriptionRefreshCoordinator {
    private var nextTicket: UInt64 = 0
    private var current: [UUID: UInt64] = [:]

    /// Claims the next ticket for `subscriptionId`, superseding any refresh
    /// already in flight for the same subscription.
    func begin(_ subscriptionId: UUID) -> UInt64 {
        nextTicket &+= 1
        current[subscriptionId] = nextTicket
        return nextTicket
    }

    /// Whether `ticket` is still the newest refresh for `subscriptionId`.
    func isCurrent(_ subscriptionId: UUID, ticket: UInt64) -> Bool {
        current[subscriptionId] == ticket
    }

    /// Releases `ticket` after it commits or is superseded. A ticket that has
    /// already lost to a newer one leaves the newer entry untouched.
    func end(_ subscriptionId: UUID, ticket: UInt64) {
        if current[subscriptionId] == ticket {
            current.removeValue(forKey: subscriptionId)
        }
    }
}
