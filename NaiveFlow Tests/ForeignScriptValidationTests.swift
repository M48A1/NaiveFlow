import Foundation
import Testing
@testable import NaiveFlow

struct ForeignScriptValidationTests {
    @Test func acceptsSurgeWithoutNativeEntryPoint() throws {
        try RuntimeJavaScript.validate("$done({body: JSON.stringify({ok:true})});")
    }

    @Test func acceptsQuantumultXSource() throws {
        let source = "$task.fetch({url:'https://example.com'}).then(r => $done({body:r.body}));"
        try RuntimeJavaScript.validate(source)
    }

    @Test func unknownScriptOptionsAreRejectedBeforeDownloading() {
        let result = TextConfigurationPipeline.process(text: """
        [MITM]
        hostname = example.com
        [Script]
        legacy = type=http-response, pattern=., source=https://example.com/legacy.js, stream=true
        """)
        #expect(!result.isActivatable)
        #expect(result.diagnostics.contains { $0.message.contains("Unsupported script parameter") })
    }

    @Test func invalidForeignJavaScriptIsRejected() {
        #expect(throws: (any Error).self) { try RuntimeJavaScript.validate("$done({") }
    }
}
