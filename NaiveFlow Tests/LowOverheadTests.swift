import Foundation
import Testing
@testable import NaiveFlow

@MainActor
struct SnapshotLifetimeTests {
    @Test func releasingRequestSnapshotDoesNotEraseHistoryOnReturn() async throws {
        let model = RequestsModel(now: { Date(timeIntervalSinceReferenceDate: 20) })
        let provider = ScriptedTunnelProvider()
        let tunnel = TunnelController(provider: provider)
        let entry = TunnelRequestEntry(timestamp: 10, protocol: .tcp, host: "example.com", port: 443, routeTarget: .direct)
        let data = try JSONEncoder().encode(RequestsResponse(requests: [entry]))
        provider.onMessage = { _ in data }
        await model.poll(using: tunnel)
        #expect(model.requests.count == 1)
        model.releaseSnapshot()
        #expect(model.requests.isEmpty)
        await model.poll(using: tunnel)
        #expect(model.requests.first?.id == entry.id)
        provider.onMessage = { _ in model.releaseSnapshot(); return data }
        await model.poll(using: tunnel)
        #expect(model.requests.isEmpty)
    }

    @Test func lateLogResponseCannotRefillReleasedSnapshot() async throws {
        let model = LogsModel()
        let provider = ScriptedTunnelProvider()
        let data = try JSONEncoder().encode(LogsResponse(logs: [
            TunnelLogEntry(timestamp: 10, level: .info, message: "test")
        ]))
        provider.onMessage = { _ in model.clear(); return data }
        await model.poll(using: TunnelController(provider: provider))
        #expect(model.logs.isEmpty)
    }
}
