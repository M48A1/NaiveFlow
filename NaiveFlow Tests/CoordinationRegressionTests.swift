import Foundation
import Testing
@testable import NaiveFlow

struct CoordinationRegressionTests {
    private func compile(_ text: String) -> CompiledConfiguration {
        ConfigurationCoordinator().compile(text: text).compiled
    }

    @Test func malformedEntryCannotDisappearDuringCompilation() {
        let result = ConfigurationCoordinator().compile(text: "[Proxy]\nNode = direct\nNode = direct\n")
        #expect(result.diagnostics.contains { $0.code == .duplicateName && $0.severity == .error })
        #expect(!result.isActivatable)
    }

    @Test func unsupportedNativeSettingsBlockActivationButRemainEditable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = RuleManager(activation: ConfigurationActivation(store: ConfigurationSnapshotStore(directory: directory)))
        let text = "[General]\nloglevel = debug\n"
        try manager.saveDraft(text)
        #expect(manager.draft() == text)
        #expect(!manager.preview(text).isActivatable)
        #expect(throws: (any Error).self) { try manager.activate(text: text) }
        #expect(manager.history().isEmpty)
    }

    @Test func managerUsesOneStoreForHistoryAndRollback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationSnapshotStore(directory: directory)
        let manager = RuleManager(activation: ConfigurationActivation(store: store))
        let first = try manager.activate(text: "[Host]\nexample.com = 10.0.0.1\n")
        _ = try manager.activate(text: "[Host]\nexample.com = 10.0.0.2\n")
        let restored = try manager.rollback()
        #expect(restored.snapshot.id == first.snapshot.id)
        #expect(manager.draft() == first.text)
        #expect(manager.history().count == 2)
        #expect(store.manifest().activeSnapshotId == first.snapshot.id)
    }

    @Test func hostOnlyEditsAndDeletionAnnounceDNSRefresh() {
        let before = compile("[Host]\nexample.com = 10.0.0.1\n")
        for text in ["[Host]\nexample.com = 10.0.0.2\n", ""] {
            let plan = ConfigurationCoordinator().plan(from: before, to: compile(text), running: CompiledSettings())
            #expect(plan.modules == [.dns])
            #expect(plan.reload.isEmpty)
            #expect(plan.announcements == [.configurationVersion])
            #expect(RuntimeCoordinator.plan(forAnnouncement: .configurationVersion)?.contains(.reloadConfigurationVersion) == true)
        }
    }

    @Test func liveHostTableOverridesStaleSnapshotWhenPlanning() {
        let document = compile("[Host]\nexample.com = 10.0.0.1\n")
        let plan = ConfigurationCoordinator().plan(
            from: document, to: document, running: CompiledSettings(),
            currentHosts: [HostMapping(host: "example.com", address: "10.0.0.9")]
        )
        #expect(plan.announcements == [.configurationVersion])
    }

    @Test func freshNodeIDsAndCommentLinesAreNotSemanticChanges() {
        let text = "[Proxy]\nNode = direct\n[Rule]\nDOMAIN-SUFFIX, example.com, Node\n"
        let first = compile(text)
        let second = compile("# comment\n" + text)
        let plan = ConfigurationCoordinator().plan(from: first, to: second, running: CompiledSettings())
        #expect(plan.isEmpty)
    }

    @Test func passwordOnlyChangeIsAnOutboundChange() {
        let before = compile("[Proxy]\nNode = socks5, example.com, 1080, username=alice, password=old\n")
        let after = compile("[Proxy]\nNode = socks5, example.com, 1080, username=alice, password=new\n")
        #expect(before.isActivatable && after.isActivatable)
        #expect(before.proxies.count == 1 && after.proxies.count == 1)
        let plan = ConfigurationCoordinator().plan(from: before, to: after, running: CompiledSettings())
        #expect(plan.modules == [.outbound])
        #expect(plan.announcements == [.configurationVersion])
    }

    @Test func emptyInitialDocumentDoesNotInventModuleChanges() {
        let plan = ConfigurationCoordinator().plan(from: nil, to: compile(""), running: CompiledSettings())
        #expect(plan.isEmpty)
    }

    @Test func stopAndRestartRejectLateModuleCompletion() {
        var state = RuntimeCoordinator.State()
        let toStarting = state.transition(to: .starting)
        #expect(toStarting)
        let toRunning = state.transition(to: .running)
        #expect(toRunning)
        let old = state.begin(.rule)
        let toStopping = state.transition(to: .stopping)
        #expect(toStopping)
        let completeOldWhileStopping = state.complete(old)
        #expect(!completeOldWhileStopping)
        let toStopped = state.transition(to: .stopped)
        #expect(toStopped)
        let backToStarting = state.transition(to: .starting)
        #expect(backToStarting)
        let current = state.begin(.rule)
        let completeOldAgain = state.complete(old)
        #expect(!completeOldAgain)
        let completeCurrent = state.complete(current)
        #expect(completeCurrent)
    }

    @Test func newerReloadSupersedesOlderWorkWithinSameSession() {
        var state = RuntimeCoordinator.State()
        let toStarting = state.transition(to: .starting)
        #expect(toStarting)
        let toRunning = state.transition(to: .running)
        #expect(toRunning)
        let first = state.begin(.rule)
        let next = state.begin(.rule)
        #expect(!state.accepts(first))
        let completeNext = state.complete(next)
        #expect(completeNext)
        #expect(state.modules.contains(.rule))
        let backToStarting = state.transition(to: .starting)
        #expect(!backToStarting)
    }

    @Test func lifecyclePreservesTeardownAndModuleDependencies() {
        #expect(RuntimeCoordinator.lifecyclePlan(for: .restart) == [.stopDataPlane, .configureModules, .startDataPlane])
        #expect(RuntimeCoordinator.lifecyclePlan(for: .sleep) == [.discardDataPlane, .startDataPlane])
        #expect(RuntimeCoordinator.lifecyclePlan(for: .stop) == [.stopDataPlane, .releaseModules])
        #expect(RuntimeCoordinator.configurationOrder == [.dns, .mitm, .outbound, .rule])
    }

    @Test func nativeTemplateCanActivateWithoutUnsupportedFields() {
        #expect(ConfigurationCoordinator().compile(text: TextConfigurationPipeline.template).isActivatable)
    }
}
