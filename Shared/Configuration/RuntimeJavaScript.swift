import Foundation
import JavaScriptCore

nonisolated enum RuntimeJavaScript {
    static func validate(_ source: String) throws {
        guard let context = JSGlobalContextCreate(nil) else { throw RuntimeConfigurationFailure.invalidBundle }
        defer { JSGlobalContextRelease(context) }
        let script = JSStringCreateWithUTF8CString("(function(){\n\(source)\n})")!
        defer { JSStringRelease(script) }
        var declaration = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if declaration.hasPrefix("const $argument = "), let end = declaration.firstIndex(of: "\n") {
            declaration = String(declaration[declaration.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while declaration.hasPrefix("//") || declaration.hasPrefix("/*") {
            if declaration.hasPrefix("//"), let end = declaration.firstIndex(of: "\n") {
                declaration = String(declaration[declaration.index(after: end)...])
            } else if declaration.hasPrefix("/*"), let end = declaration.range(of: "*/") {
                declaration = String(declaration[end.upperBound...])
            } else { break }
            declaration = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard JSCheckScriptSyntax(context, script, nil, 1, nil),
              declaration.range(of: #"^(?:async\s+)?function\s+process\s*\("#, options: .regularExpression) != nil
        else { throw RuntimeConfigurationFailure.rejected("A script must contain valid JavaScript and declare process(context).") }
    }
}
