//
//  AWNotificationCenter.swift
//  NaiveFlow
//
//  Created by NodePassProject on 6/26/26.
//

import Foundation

actor AWNotificationCenter {
    
    // MARK: - Darwin Notification Names

    enum Notification {
        nonisolated(unsafe) static let configurationVersionChanged = "\(AWCore.Identifier.bundle).configurationVersion" as CFString
        nonisolated(unsafe) static let certificatePolicyChanged = "\(AWCore.Identifier.bundle).certificatePolicyChanged" as CFString
    }

    // MARK: - Public API

    static func notifyConfigurationVersionChanged() { post(Notification.configurationVersionChanged) }







    static func notifyCertificatePolicyChanged() {
        post(Notification.certificatePolicyChanged)
    }



    // MARK: - Throttled Posting

    private static let shared = AWNotificationCenter()
    private static let throttleInterval: Duration = .seconds(1)

    private var lastPostTimes: [String: ContinuousClock.Instant] = [:]
    private var pendingTasks: [String: Task<Void, Never>] = [:]

    private static func post(_ name: CFString) {
        let key = name as String
        Task { await shared.schedule(key) }
    }

    private func schedule(_ name: String) {
        pendingTasks[name]?.cancel()
        pendingTasks[name] = nil

        let now = ContinuousClock.now
        if let last = lastPostTimes[name], now - last < Self.throttleInterval {
            // Within the throttle window: coalesce into a single trailing post.
            let delay = Self.throttleInterval - (now - last)
            pendingTasks[name] = Task {
                try? await Task.sleep(for: delay, precision: .relaxed)
                guard !Task.isCancelled else { return }
                self.fire(name)
            }
        } else {
            lastPostTimes[name] = now
            Self.emit(name)
        }
    }

    private func fire(_ name: String) {
        lastPostTimes[name] = ContinuousClock.now
        pendingTasks[name] = nil
        Self.emit(name)
    }

    private static func emit(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }
}
