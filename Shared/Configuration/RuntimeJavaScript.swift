import Foundation
import JavaScriptCore

nonisolated enum RuntimeJavaScript {
    static let maximumScriptBytes = 4 * 1024 * 1024

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
    }
}
