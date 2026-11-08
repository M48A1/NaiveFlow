import Foundation
import Synchronization
import Testing
@testable import NaiveFlow

@MainActor
struct LiveRequestMonitorTests {
    private func connection(_ id: UUID, state: TunnelActivityState = .established,
                            failure: String? = nil, bytes: Int64 = 42) -> TunnelActivityEntry {
        .init(id: id, host: "same.test", port: 443, routeTarget: .direct, defaultRouteTarget: .direct,
              ruleSetName: nil, state: state, startedAt: 10, endedAt: state == .closed ? 30 : nil,
              bytesIn: bytes, bytesOut: 24, establishedAt: 12, failure: failure)
    }

    @Test func sameDestinationConnectionsKeepDistinctMetricsAndUpdateByIdentity() async throws {
        let a = UUID(), b = UUID()
        let rows = [a, b].map {
            TunnelRequestEntry(timestamp: 20, protocol: .tcp, host: "same.test", port: 443,
                               routeTarget: .direct, activityID: $0)
        }
        let provider = ScriptedTunnelProvider()
        let tunnel = TunnelController(provider: provider)
        let model = RequestsModel(now: { Date(timeIntervalSinceReferenceDate: 31) })
        var payload = try JSONEncoder().encode(RequestsResponse(requests: rows, activities: [
            connection(a), connection(b, state: .closed, failure: "Refused", bytes: 99)
        ]))
        provider.onMessage = { _ in payload }
        await model.poll(using: tunnel)
        #expect(model.requests.map(\.state) == [.established, .failed])
        #expect(model.requests.map { $0.activity?.bytesIn } == [42, 99])
        #expect(model.requests[0].connectDuration == 2)
        #expect(model.requests[1].duration(at: Date(timeIntervalSinceReferenceDate: 100)) == 20)
        // An evicted active snapshot must not masquerade as still connected.
        // Closed metrics can safely be retained until the request itself expires.
        payload = try JSONEncoder().encode(RequestsResponse(requests: rows, activities: []))
        await model.poll(using: tunnel)
        #expect(model.requests.map(\.state) == [.unknown, .failed])
        #expect(model.requests.map(\.id) == rows.map(\.id))
    }

    @Test func filtersSearchAndExportDescribeExactlyTheVisibleRows() async throws {
        let activeID = UUID(), failedID = UUID()
        let rows = [
            TunnelRequestEntry(timestamp: 10, protocol: .tcp, host: "api.example", port: 443,
                               routeTarget: .direct, ruleSetName: "Work", outbound: .direct, activityID: activeID),
            TunnelRequestEntry(timestamp: 11, protocol: .udp, host: "video.example", port: 8443,
                               routeTarget: .direct, isQUIC: true, activityID: failedID),
            TunnelRequestEntry(timestamp: 12, protocol: .udp, host: "blocked.example", port: 443,
                               routeTarget: .reject, blockReason: .quicPolicy)
        ]
        let provider = ScriptedTunnelProvider()
        let payload = try JSONEncoder().encode(RequestsResponse(requests: rows, activities: [
            connection(activeID), connection(failedID, state: .closed, failure: "Connection refused")
        ]))
        provider.onMessage = { _ in payload }
        let model = RequestsModel(now: { Date(timeIntervalSinceReferenceDate: 20) })
        await model.poll(using: TunnelController(provider: provider))
        #expect(model.visibleRequests().map(\.id) == rows.reversed().map(\.id))
        #expect(model.visibleRequests(query: "API work direct 443").map(\.id) == [rows[0].id])
        #expect(model.visibleRequests(query: "no-match").isEmpty)
        #expect(model.visibleRequests(filter: .active).map(\.id) == [rows[0].id])
        #expect(model.visibleRequests(query: "refused", filter: .failed, protocol: .quic).map(\.id) == [rows[1].id])
        let rejected = model.visibleRequests(filter: .rejected)
        let exported = try #require(JSONSerialization.jsonObject(with: Data(model.export(rejected).utf8)) as? [[String: Any]])
        #expect(exported.count == 1)
        #expect(exported[0]["host"] as? String == "blocked.example")
        #expect(exported[0]["blockReason"] as? String == "quicPolicy")
        let empty = try #require(JSONSerialization.jsonObject(with: Data(model.export([]).utf8)) as? [Any])
        #expect(empty.isEmpty)
    }

    @Test func clearSuppressesOldSnapshotsIncludingAnInflightReplyButAllowsNewRecords() async throws {
        var now = Date(timeIntervalSinceReferenceDate: 20)
        let model = RequestsModel(now: { now })
        let provider = ScriptedTunnelProvider()
        let tunnel = TunnelController(provider: provider)
        let old = TunnelRequestEntry(timestamp: 10, protocol: .tcp, host: "old", port: 443, routeTarget: .direct)
        let fresh = TunnelRequestEntry(timestamp: 21, protocol: .tcp, host: "new", port: 443, routeTarget: .direct)
        let before = try JSONEncoder().encode(RequestsResponse(requests: [old]))
        provider.onMessage = { _ in model.clear(); return before }
        await model.poll(using: tunnel)
        #expect(model.requests.isEmpty)
        now = Date(timeIntervalSinceReferenceDate: 22)
        let after = try JSONEncoder().encode(RequestsResponse(requests: [old, fresh]))
        provider.onMessage = { _ in after }
        await model.poll(using: tunnel)
        #expect(model.requests.map(\.id) == [fresh.id])
    }

    @Test func cancelledPollKeepsLastSnapshotAndResumeFetchesCurrentMetrics() async throws {
        let id = UUID()
        let row = TunnelRequestEntry(timestamp: 20, protocol: .tcp, host: "same.test", port: 443,
                                     routeTarget: .direct, activityID: id)
        let provider = ScriptedTunnelProvider()
        let tunnel = TunnelController(provider: provider)
        let model = RequestsModel(now: { Date(timeIntervalSinceReferenceDate: 31) })
        let initial = try JSONEncoder().encode(RequestsResponse(requests: [row], activities: [connection(id)]))
        provider.onMessage = { _ in initial }
        await model.poll(using: tunnel)
        let snapshot = model.requests

        let updated = try JSONEncoder().encode(RequestsResponse(requests: [row], activities: [
            connection(id, state: .closed, bytes: 99)
        ]))
        provider.onMessage = { _ in
            // Pausing cancels the polling task even if its provider reply is already in flight.
            withUnsafeCurrentTask { $0?.cancel() }
            return updated
        }
        let polling = Task { await model.poll(using: tunnel) }
        await polling.value
        #expect(model.requests == snapshot)
        #expect(model.refreshState == .current)

        provider.onMessage = { _ in updated }
        await model.poll(using: tunnel)
        #expect(model.requests.first?.id == row.id)
        #expect(model.requests.first?.state == .closed)
        #expect(model.requests.first?.activity?.bytesIn == 99)
    }

    @Test func callbackTimeoutAndCancellationReturnWithoutWaitingForTheProvider() async throws {
        let callback = Mutex<(@Sendable (Data?) -> Void)?>(nil)
        let start = ContinuousClock.now
        let result = await ProviderMessageConcurrencyBridge.send(timeout: .milliseconds(20)) {
            reply in callback.withLock { $0 = reply }
        }
        #expect(result == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
        callback.withLock { $0 }?(Data([1])) // A late callback cannot resume twice.
        let task = Task {
            await ProviderMessageConcurrencyBridge.send(timeout: .seconds(60)) { reply in
                callback.withLock { $0 = reply }
            }
        }
        task.cancel()
        #expect(await task.value == nil)
        callback.withLock { $0 }?(Data([2]))
    }

    @Test func duplicateCallbacksAndErrorsCompleteOnlyOnce() async {
        struct Failure: Error {}
        let expected = Data([1, 2, 3])
        let result = await ProviderMessageConcurrencyBridge.send { reply in
            reply(expected)
            reply(Data([4]))
            throw Failure()
        }
        #expect(result == expected)
        let failure = await ProviderMessageConcurrencyBridge.send { _ in throw Failure() }
        #expect(failure == nil)
    }

    @Test func routeDiagnosticsSurviveLegacyEncodingAndExport() async throws {
        let id = UUID()
        let entry = TunnelRequestEntry(timestamp: 1, protocol: .tcp, host: "example.test", port: 443,
                                       routeTarget: .direct, activityID: id,
                                       resolvedAddress: "203.0.113.8", resolutionPurpose: "ruleEvaluation")
        let decoded = try JSONDecoder().decode(TunnelRequestEntry.self,
            from: JSONEncoder().encode(entry))
        #expect(decoded.resolvedAddress == "203.0.113.8")
        #expect(decoded.resolutionPurpose == "ruleEvaluation")
        let model = RequestsModel(now: { Date(timeIntervalSinceReferenceDate: 2) })
        let provider = ScriptedTunnelProvider()
        provider.onMessage = { _ in try? JSONEncoder().encode(RequestsResponse(requests: [entry])) }
        await model.poll(using: TunnelController(provider: provider))
        let json = model.export(model.requests)
        #expect(json.contains("203.0.113.8"))
        #expect(json.contains("ruleEvaluation"))
    }
}
