//
//  TunnelStartSequencer.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation

/// Serializes tunnel start/stop so a `stop` that lands while a `start` is
/// awaiting `saveToPreferences` / `loadFromPreferences` cannot be followed by a
/// late `startVPNTunnel` (the "stop then start" race), and so two preference
/// writes never mutate the same manager concurrently.
///
/// `begin()` reserves a start generation; `stop()` invalidates it. Start work
/// runs serialized behind any earlier preference mutation and re-checks its
/// generation after every `await` before dialing the tunnel, because cancelling
/// the Task does not by itself stop later plain Swift statements.
@MainActor
final class TunnelStartSequencer {
    private var generation: UInt64 = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Reserves a new start generation (and invalidates any previous start).
    @discardableResult
    func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Invalidates any in-flight start and reserves a stop generation.
    @discardableResult
    func stop() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// `true` while `token` is still the newest start/stop intent.
    func isCurrent(_ token: UInt64) -> Bool { token == generation }

    /// Runs `work` serialized behind any earlier preference mutation. Callers
    /// re-check `isCurrent(token)` after each `await` and bail before issuing the
    /// tunnel dial when a stop superseded them.
    func perform(_ work: @MainActor () async throws -> Void) async rethrows {
        if busy {
            // Ownership is handed over by the current holder's `defer`; `busy`
            // stays true across the hand-off so no third mutation can interleave.
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        try await work()
    }
}
