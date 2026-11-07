//
//  TunnelStartSequencerTests.swift
//  NaiveFlow Tests
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation
import Testing
@testable import NaiveFlow

/// Drives the serialized start/stop ordering primitive that `LiveTunnelProvider`
/// uses. The bug the review confirmed: `start` awaits `saveToPreferences` /
/// `loadFromPreferences`, and a `stop` that lands during that window used to be
/// followed by a late `startVPNTunnel` (a "stop then start"). Cancelling the Task
/// does not stop the remaining plain statements, so the generation must be
/// re-checked after every await.
@MainActor
struct TunnelStartSequencerTests {
    /// Ordered event log shared across the interleaved tasks (all on MainActor).
    @MainActor private final class Recorder {
        var events: [String] = []
    }

    /// One-shot async gate used to hold the "save" in flight while a stop lands.
    @MainActor private final class Gate {
        private var reachedWaiter: CheckedContinuation<Void, Never>?
        private var openWaiter: CheckedContinuation<Void, Never>?
        private var reached = false
        private var opened = false

        func wait() async {
            if !reached {
                reached = true
                reachedWaiter?.resume()
                reachedWaiter = nil
            }
            if opened { return }
            await withCheckedContinuation { openWaiter = $0 }
        }

        func waitReached() async {
            if reached { return }
            await withCheckedContinuation { reachedWaiter = $0 }
        }

        func open() {
            opened = true
            openWaiter?.resume()
            openWaiter = nil
        }
    }

    @Test func stopDuringStartSavePreventsLateTunnelStart() async {
        let sequencer = TunnelStartSequencer()
        let gate = Gate()
        let recorder = Recorder()

        let token = sequencer.begin()
        let startTask = Task { @MainActor in
            try await sequencer.perform {
                recorder.events.append("save")
                await gate.wait()  // the save is still in flight here
                guard sequencer.isCurrent(token) else { return }
                recorder.events.append("start")  // must NOT run after a stop
            }
        }
        await gate.waitReached()

        // The user disconnects while the save is suspended.
        sequencer.stop()
        let stopTask = Task { @MainActor in
            try await sequencer.perform { recorder.events.append("stop") }
        }

        gate.open()
        _ = try? await stopTask.value
        _ = try? await startTask.value

        #expect(recorder.events == ["save", "stop"], "a stop must pre-empt the pending start; got \(recorder.events)")
        #expect(!recorder.events.contains("start"))
    }

    @Test func newerStartSupersedesInFlightStart() async {
        let sequencer = TunnelStartSequencer()
        let gate = Gate()
        let recorder = Recorder()

        let firstToken = sequencer.begin()
        let first = Task { @MainActor in
            try await sequencer.perform {
                recorder.events.append("save1")
                await gate.wait()
                guard sequencer.isCurrent(firstToken) else { return }
                recorder.events.append("start1")
            }
        }
        await gate.waitReached()

        // A newer connect replaces the pending one before it starts.
        sequencer.begin()
        let second = Task { @MainActor in
            try await sequencer.perform { recorder.events.append("save2") }
        }

        gate.open()
        _ = try? await second.value
        _ = try? await first.value

        #expect(recorder.events == ["save1", "save2"], "the superseded start must not dial; got \(recorder.events)")
        #expect(!recorder.events.contains("start1"))
    }
}
