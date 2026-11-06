import Foundation
import Synchronization
import Testing
@testable import RuleProxy

nonisolated private final class RuleSetFixture: Sendable {
    let calls = Mutex(0)
    let body = Mutex("DOMAIN,example.com")
}

@Suite(.serialized)
@MainActor
struct NativeRuleSetTests {
    private let source = "https://rules.example.test/direct.list"

    private func compile(_ text: String, contents: [String: String]) -> TextConfigurationPipeline.Result {
        ConfigurationCoordinator().compile(text: text, ruleSetContents: contents)
    }

    @Test func expandsAtReferencePositionAndPreservesPolicy() {
        let result = compile("""
            [Rule]
            DOMAIN, first.example, REJECT
            RULE-SET, \(source), DIRECT
            DOMAIN-SUFFIX, example.com, REJECT
            FINAL, REJECT
            """, contents: [source: "DOMAIN, first.example\nDOMAIN-SUFFIX, example.com\n"])
        #expect(result.isActivatable)
        #expect(result.compiled.orderedRules.count == 4)
        #expect(result.route(host: "first.example").action == .reject)
        #expect(result.route(host: "api.example.com").action == .direct)
        #expect(result.route(host: "other.test").action == .reject)
        #expect(result.decidingLine(host: "api.example.com") == 3)
    }

    @Test func sameSourceCanHaveDifferentPoliciesAtDifferentPositions() {
        let result = compile("[Rule]\nRULE-SET, \(source), REJECT\nRULE-SET, \(source), DIRECT\nFINAL, DIRECT",
            contents: [source: "DOMAIN, example.com"])
        #expect(result.isActivatable)
        #expect(result.compiled.orderedRules.map(\.action) == [.reject, .direct])
        #expect(result.route(host: "example.com").action == .reject)
    }

    @Test func referenceNoResolveIsInheritedByIPConditionsOnly() {
        let result = compile("[Rule]\nRULE-SET, \(source), REJECT, no-resolve\nFINAL, DIRECT",
            contents: [source: "IP-CIDR, 10.0.0.0/8\nDOMAIN, example.com"])
        #expect(result.isActivatable)
        #expect(result.compiled.orderedRules.map(\.noResolve) == [true, false])
        let matcher = OrderedRouteMatcher(rules: result.compiled.orderedRules, finalAction: result.compiled.finalAction)
        if case .matched(let found) = matcher.evaluate(RouteQuery(host: "other.test")) {
            #expect(found.action == .direct)
        } else { Issue.record("Provider no-resolve must not request DNS") }
    }

    @Test func providerSupportsCommentsBOMCRLFAndNativeLogicalConditions() throws {
        let rules = try NativeRuleSet.parse("\u{FEFF}# test\r\n; comment\r\n// comment\r\nAND,((PROTOCOL,TCP),(DEST-PORT,443))\r\nIP-CIDR6,2001:db8::/32,no-resolve # note\r\n", source: source)
        #expect(rules.count == 2)
        #expect(rules[0].kind == .logicalAnd)
        #expect(rules[1].hasOption(.noResolve))
    }

    @Test func refusesProviderPoliciesNestedReferencesFinalAndInvalidExpressions() {
        for invalid in ["DOMAIN,example.com,DIRECT", "RULE-SET,https://rules.example.test/nested", "FINAL,DIRECT",
                        "PROCESS-NAME,App", "DOMAIN-REGEX,[", "IP-CIDR,invalid", "PROTOCOL,ICMP",
                        "AND,((RULE-SET,https://rules.example.test/nested))", "# empty"] {
            #expect(throws: (any Error).self) { try NativeRuleSet.parse(invalid, source: source) }
        }
    }

    @Test func invalidProviderReportsSourceLine() {
        do {
            _ = try NativeRuleSet.parse("# comment\nDOMAIN,example.com\nIP-CIDR,invalid", source: source)
            Issue.record("Invalid provider should fail")
        } catch { #expect(error.localizedDescription.contains("\(source):3:")) }
    }

    @Test func sourceValidationAndPendingPreviewAreExplicit() {
        for invalid in ["http://rules.example.test/list", "relative.list", "ftp://rules.example.test/list", "https://user:password@rules.example.test/list"] {
            let result = ConfigurationCoordinator().compile(text: "[Rule]\nRULE-SET, \(invalid), DIRECT")
            #expect(!result.isActivatable)
        }
        let pending = ConfigurationCoordinator().compile(text: "[Rule]\nRULE-SET, \(source), DIRECT")
        #expect(pending.isActivatable)
        #expect(pending.diagnostics.contains { $0.code == .notApplied && $0.message.contains("preview is incomplete") })
    }

    @Test func resolvedReferenceStillRejectsUnsupportedOptionsAndTooManySources() {
        let badOption = compile("[Rule]\nRULE-SET, \(source), DIRECT, extended-matching",
            contents: [source: "DOMAIN,example.com"])
        #expect(!badOption.isActivatable)
        let references = (0...NativeRuleSet.maximumSources).map { "RULE-SET, https://rules.example.test/\($0).list, DIRECT" }
        let tooMany = ConfigurationCoordinator().compile(text: "[Rule]\n" + references.joined(separator: "\n"))
        #expect(!tooMany.isActivatable)
    }

    @Test func deduplicatesDownloadsWithinPublication() async throws {
        let fixture = RuleSetFixture()
        let parsed = RuleManager.parse("[Rule]\nRULE-SET, \(source), DIRECT\nRULE-SET, \(source), REJECT").configuration
        let contents = try await NativeRuleSet.resolve(parsed, loader: { _ in
            fixture.calls.withLock { $0 += 1 }
            return Data("DOMAIN,example.com".utf8)
        })
        #expect(contents.count == 1)
        #expect(fixture.calls.withLock { $0 } == 1)
    }

    @Test func readsAppAccessibleLocalFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".list")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("DOMAIN-SUFFIX,example.com".utf8).write(to: file)
        let text = "[Rule]\nRULE-SET, \(file.absoluteString), DIRECT\nFINAL, REJECT"
        let parsed = RuleManager.parse(text).configuration
        let contents = try await NativeRuleSet.resolve(parsed)
        #expect(compile(text, contents: contents).route(host: "example.com").action == .direct)
    }

    @Test func rejectsOversizedAndNonUTF8Downloads() async {
        let parsed = RuleManager.parse("[Rule]\nRULE-SET, \(source), DIRECT").configuration
        await #expect(throws: (any Error).self) {
            try await NativeRuleSet.resolve(parsed, loader: { _ in Data(repeating: 65, count: NativeRuleSet.maximumSourceBytes + 1) })
        }
        await #expect(throws: (any Error).self) {
            try await NativeRuleSet.resolve(parsed, loader: { _ in Data([0xff]) })
        }
    }

    @Test func failedRefreshLeavesPublishedVersionUntouchedAndRollbackDoesNotFetch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activation = ConfigurationActivation(store: ConfigurationSnapshotStore(directory: directory))
        let fixture = RuleSetFixture()
        var publisher = ConfigurationPublisher(activation: activation, tunnel: nil, ruleSetLoader: { _ in
            fixture.calls.withLock { $0 += 1 }
            return Data(fixture.body.withLock { $0 }.utf8)
        }, preferencesSink: { _ in })
        let text = "[Rule]\nRULE-SET, \(source), REJECT\nFINAL, DIRECT"
        _ = try await publisher.publish(text: text)
        let first = try #require(publisher.bundleStore.head())
        fixture.body.withLock { $0 = "DOMAIN-REGEX,[" }
        await #expect(throws: (any Error).self) { try await publisher.publish(text: text) }
        #expect(try publisher.bundleStore.head() == first)
        fixture.body.withLock { $0 = "DOMAIN,new.example" }
        _ = try await publisher.publish(text: text)
        publisher.ruleSetLoader = { _ in throw NativeRuleSet.Failure(message: "Network unavailable") }
        let second = try #require(publisher.bundleStore.head())
        await #expect(throws: (any Error).self) { try await publisher.publish(text: text) }
        #expect(try publisher.bundleStore.head() == second)
        _ = try await publisher.rollback()
        let restored = try #require(publisher.bundleStore.head())
        #expect(restored.current == first.current)
        let bundle = try publisher.bundleStore.load(restored.current)
        let matcher = OrderedRouteMatcher(rules: bundle.rules ?? [], finalAction: bundle.finalAction)
        #expect(matcher.match(RouteQuery(host: "example.com")).action == .reject)
        #expect(matcher.match(RouteQuery(host: "new.example")).action == .direct)
        #expect(fixture.calls.withLock { $0 } == 3)
    }
}
