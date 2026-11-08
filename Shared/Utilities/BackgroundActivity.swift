//
//  BackgroundActivity.swift
//  NaiveFlow
//
//  Created by NodePassProject on 9/1/26.
//

import Foundation

nonisolated final class BackgroundActivity: Sendable {
    private let release = DispatchSemaphore(value: 0)

    init(reason: String) {
        #if !os(macOS)
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { [release] expired in
            guard !expired else { return }
            release.wait()
        }
        #else
        // macOS does not expose the iOS expiring-activity API. The activity
        // remains a lightweight lifetime marker for call-site symmetry.
        _ = reason
        #endif
    }

    func end() {
        release.signal()
    }
}
