import Foundation
import JavaScriptCore

nonisolated enum RuntimeJavaScript {
    static let maximumScriptBytes = 4 * 1024 * 1024

    /// Ignore comments and literal text when recognizing legacy API usage.
    private static func codeTokens(_ source: String) -> String {
        source.replacingOccurrences(
            of: #"""
            "(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|//[^\n]*|/\*[\s\S]*?\*/
            """#,
            with: " ", options: .regularExpression)
    }

    static func validate(_ source: String) throws {
        guard source.utf8.count <= maximumScriptBytes else {
            throw RuntimeConfigurationFailure.rejected("A script exceeds 4 MB.")
        }
        guard let context = JSGlobalContextCreate(nil) else { throw RuntimeConfigurationFailure.invalidBundle }
        defer { JSGlobalContextRelease(context) }
        let script = JSStringCreateWithUTF8CString("(function(){\n\(source)\n})")!
        defer { JSStringRelease(script) }
        guard JSCheckScriptSyntax(context, script, nil, 1, nil) else {
            throw RuntimeConfigurationFailure.rejected("Script contains invalid JavaScript.")
        }
        let legacy = #"\b(?:function\s+process\s*\(|(?:const|let|var)\s+process\s*=|(?:Anywhere|NaiveFlow)\s*(?:\.|\[))"#
        guard codeTokens(source).range(of: legacy, options: .regularExpression) == nil else {
            throw RuntimeConfigurationFailure.rejected("Anywhere native scripts (process(ctx), Anywhere.*, NaiveFlow.*) are no longer supported. Use a Surge or Quantumult X script with $done.")
        }
    }
}
