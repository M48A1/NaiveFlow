//
//  OneShotLatch.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/14/26.
//

import Synchronization

nonisolated final class OneShotLatch: Sendable {
    private let claimed = Atomic<Bool>(false)

    @discardableResult
    func claim() -> Bool {
        !claimed.exchange(true, ordering: .acquiringAndReleasing)
    }

    var isClaimed: Bool { claimed.load(ordering: .acquiring) }
}

