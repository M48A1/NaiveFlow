import Foundation
import Testing
@testable import NaiveFlow

@MainActor
struct ResourceRefreshRaceTests {
    @Test func coordinatorSupersedesAndScopesPerKey() {
        let coordinator = RefreshTicketCoordinator<UUID>()
        let a = UUID(), b = UUID()
        let stale = coordinator.begin(a)
        let fresh = coordinator.begin(a)
        #expect(!coordinator.isCurrent(a, ticket: stale))
        #expect(coordinator.isCurrent(a, ticket: fresh))
        let other = coordinator.begin(b)
        #expect(coordinator.isCurrent(b, ticket: other))
        #expect(coordinator.isCurrent(a, ticket: fresh))
        coordinator.end(a, ticket: stale)
        #expect(coordinator.isCurrent(a, ticket: fresh))
        coordinator.end(a, ticket: fresh)
        #expect(!coordinator.isCurrent(a, ticket: fresh))
    }

}
