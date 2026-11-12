import Foundation
import Testing
@testable import NaiveFlow

struct ScriptDialectTests {
    private let source = "$done({body:'ok'});"

    private func profile(_ option: String = "") -> String {
        """
        [MITM]
        enable = false
        hostname = example.com
        [Script]
        test = type=http-response, pattern=., source=base64:\(Data(source.utf8).base64EncodedString())\(option)
        """
    }

    @Test func omittedDialectDefaultsToSurge() async throws {
        let result = TextConfigurationPipeline.process(text: profile())
        #expect(result.isActivatable)
        #expect(result.compiled.textMITM.scripts.first?.dialect == .surge)
        let sets = try await result.compiled.textMITM.resolveScripts()
        guard case .script(_, let dialect) = sets.first?.rules.first?.operation else {
            Issue.record("Expected a script operation"); return
        }
        #expect(dialect == .surge)
    }

    @Test(arguments: ["surge", "quantumult-x"])
    func explicitDialectSurvivesResolutionAndProfileExport(name: String) async throws {
        let dialect = try #require(MITMScriptDialect(rawValue: name))
        let result = TextConfigurationPipeline.process(text: profile(", dialect=\(name)"))
        #expect(result.isActivatable)
        let sets = try await result.compiled.textMITM.resolveScripts()
        #expect(sets.first?.rules.first?.operation == .script(scriptBase64: Data(source.utf8).base64EncodedString(), dialect: dialect))
        let exported = ConfigurationExporter.export(.init(mitmEnabled: false, mitmRuleSets: sets))
        let restored = TextConfigurationPipeline.process(text: exported.text)
        #expect(restored.isActivatable)
        let restoredSets = try await restored.compiled.textMITM.resolveScripts()
        #expect(restoredSets.first?.rules.first?.operation == sets.first?.rules.first?.operation)
    }

    @Test(arguments: ["", "native", "quantumult", "automatic"])
    func unsupportedDialectIsRejected(name: String) {
        let result = TextConfigurationPipeline.process(text: profile(", dialect=\(name)"))
        #expect(!result.isActivatable)
        #expect(result.diagnostics.contains { $0.message.contains("dialect") })
    }

    @Test func oldJSONDefaultsToSurgeAndExplicitQXRoundTrips() throws {
        let old = Data(#"{"kind":"script","script":"JGRvbmUoe30pOw=="}"#.utf8)
        let decoded = try JSONDecoder().decode(MITMOperation.self, from: old)
        #expect(decoded == .script(scriptBase64: "JGRvbmUoe30pOw==", dialect: .surge))
        let qx = MITMOperation.script(scriptBase64: Data(source.utf8).base64EncodedString(), dialect: .quantumultX)
        #expect(try JSONDecoder().decode(MITMOperation.self, from: JSONEncoder().encode(qx)) == qx)
        let invalid = Data(#"{"kind":"script","script":"JGRvbmUoe30pOw==","dialect":"native"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MITMOperation.self, from: invalid) }
    }

    @Test func missingDialectNeverInfersQXFromSource() throws {
        let encoded = Data("$task.fetch({url:'https://example.com'});".utf8).base64EncodedString()
        let json = try JSONSerialization.data(withJSONObject: ["kind": "script", "script": encoded])
        #expect(try JSONDecoder().decode(MITMOperation.self, from: json) == .script(scriptBase64: encoded, dialect: .surge))
    }

    @MainActor @Test func legacyRuleImportAcceptsExplicitQXAndDefaultsToSurge() {
        let encoded = Data(source.utf8).base64EncodedString()
        let defaultSet = MITMRuleSetParser.parse("hostname = example.com\n1, 100, ., \(encoded)")
        let qxSet = MITMRuleSetParser.parse("hostname = example.com\n1, 100, ., \(encoded), quantumult-x")
        #expect(defaultSet.rules.first?.operation == .script(scriptBase64: encoded, dialect: .surge))
        #expect(qxSet.rules.first?.operation == .script(scriptBase64: encoded, dialect: .quantumultX))
    }
    @Test func dialectOnlyEditTriggersMITMReload() {
        let before = TextConfigurationPipeline.process(text: profile()).compiled
        let after = TextConfigurationPipeline.process(text: profile(", dialect=quantumult-x")).compiled
        let plan = ConfigurationCoordinator().plan(from: before, to: after, running: before.settings)
        #expect(plan.change(for: .mitm)?.payloadChanged == true)
    }

    @Test func immutableVersionsKeepTheirOwnDialect() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RuntimeBundleStore(directory: directory)
        let node = ProxyConfiguration(name: "Direct", serverAddress: "", serverPort: 0, outbound: .direct(DirectConfiguration()))
        var versions: [(UUID, MITMScriptDialect)] = []
        for dialect in MITMScriptDialect.allCases {
            let set = MITMRuleSet(name: "Scripts", domainSuffixes: ["example.com"], rules: [
                MITMRule(phase: .httpResponse, urlPattern: ".", operation: .script(scriptBase64: Data(source.utf8).base64EncodedString(), dialect: dialect))
            ])
            let bundle = RuntimeConfigurationBundle(id: UUID(), snapshotID: nil, parentID: nil,
                preferences: Dictionary(uniqueKeysWithValues: AWCore.runtimePreferenceKeys.map { ($0, RuntimePreferenceValue.absent) }), nodes: [node], selectedNodeID: node.id, rules: [], finalAction: .direct,
                mitmRuleSets: [set], legacyRouting: nil, legacyMITM: nil)
            try store.save(bundle)
            versions.append((bundle.id, dialect))
        }
        for (id, dialect) in versions {
            let loaded = try store.load(id)
            #expect(loaded.mitmRuleSets.first?.rules.first?.operation == .script(scriptBase64: Data(source.utf8).base64EncodedString(), dialect: dialect))
        }
    }

}
