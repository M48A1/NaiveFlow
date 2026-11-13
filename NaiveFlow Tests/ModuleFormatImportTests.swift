import Foundation
import Testing
@testable import NaiveFlow

@MainActor
struct ModuleFormatImportTests {
    @Test func surgeModuleImportsMetadataAndRewrite() async throws {
        let made = try await ModuleImporter.makeModule(from: """
            #!name=Example
            #!desc=Example rewrite
            [URL Rewrite]
            ^https://example.com/ https://example.org/ 302
            [MITM]
            hostname = %APPEND% *.example.com
            [Script]
            test = type=http-response,pattern=.,script-path=https://example.com/test.js,requires-body=true
            """, fallbackName: "Fallback", format: .surge, fetchResource: { _ in "$done({body:'ok'});" })
        #expect(made.module.name == "Example")
        #expect(made.module.sourceFormat == .surge)
        #expect(made.module.mitmRuleSets.first?.domainSuffixes == ["example.com"])
        #expect(made.module.mitmRuleSets.first?.rules.count == 2)
        #expect(made.warnings.isEmpty)
    }

    @Test(arguments: ["", "[rewrite_local]\n"])
    func quantumultSnippetImportsRulesAndScripts(prefix: String) async throws {
        let made = try await ModuleImporter.makeModule(from: prefix + """
            ^https://example.com/ad url reject
            ^https://example.com/script url script-response-body https://example.com/test.js
            hostname = *.example.com
            """, fallbackName: "Snippet", format: .quantumultX, fetchResource: { _ in "$done({body:'ok'});" })
        #expect(made.module.name == "Snippet")
        #expect(made.module.mitmRuleSets.first?.domainSuffixes == ["example.com"])
        #expect(made.module.mitmRuleSets.first?.rules.count == 2)
        #expect(made.warnings.isEmpty)
    }

    @Test func formatsPersist() throws {
        let original = Module(name: "Test", sourceFormat: .quantumultX)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Module.self, from: data).sourceFormat == .quantumultX)
    }

    @Test func fileTypesAreDistinctAndCaseInsensitive() {
        #expect(ModuleFormat.allCases == [.surge, .quantumultX])
        for format in ModuleFormat.allCases {
            let url = URL(fileURLWithPath: "/tmp/test.\(format.fileExtension.uppercased())")
            #expect(format.acceptsFile(url))
            for other in ModuleFormat.allCases where other != format {
                #expect(!other.acceptsFile(url))
            }
        }
        #expect(Module.validSubscriptionURL(from: "https://example.com/test.sgmodule") != nil)
        #expect(Module.validSubscriptionURL(from: "https://example.com/test.snippet") != nil)
        #expect(Module.validSubscriptionURL(from: "file:///tmp/test.sgmodule") == nil)
    }
}
