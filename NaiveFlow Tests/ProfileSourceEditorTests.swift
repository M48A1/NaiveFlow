import Testing
import UIKit
@testable import NaiveFlow

@MainActor
struct ProfileSourceEditorTests {
    @Test func diagnosticLineRangesHandleUnicodeAndWindowsLineEndings() throws {
        let editor = ProfileSourceEditor.NumberedTextView(usingTextLayoutManager: false)
        editor.text = "# 香港 🌏\r\n[Proxy Group]\r\nWork = select, Missing"
        let range = try #require(editor.range(forLine: 3))
        #expect((editor.text as NSString).substring(with: range) == "Work = select, Missing")
        #expect(editor.lineNumber(at: range.location) == 3)
        #expect(editor.lineNumber(at: (editor.text as NSString).length) == 3)
        #expect(editor.range(forLine: 4) == nil)
        #expect(editor.range(forLine: 0) == nil)
        editor.text = "🌏"
        #expect(editor.range(forLine: 2) == nil)
        #expect(editor.lineNumber(at: 2) == 1)
        editor.text = "first\n\n"
        #expect(editor.range(forLine: 3) == NSRange(location: 7, length: 0))
        #expect(editor.lineNumber(at: 7) == 3)
        #expect(editor.range(forLine: 4) == nil)
    }

    @Test func savedErrorsDecorateOriginalLinesWithoutChangingConfiguration() throws {
        let text = "[Proxy]\nLocal = direct\n[Proxy Group]\nWork = select, Missing\n"
        let errors = TextConfigurationPipeline.process(text: text).diagnostics.errors.sorted
        let error = try #require(errors.first)
        let line = try #require(error.line)
        let editor = ProfileSourceEditor.SourceEditor()
        editor.source.text = text
        editor.errors = errors
        editor.decorate()
        let range = try #require(editor.source.range(forLine: line))
        #expect(editor.source.textStorage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil)
        #expect(editor.source.errorLines.contains(line))
        #expect(editor.source.text == text)
        editor.source.selectedRange = NSRange(location: range.location, length: 0)
        editor.updateMessage()
        #expect(editor.source.accessibilityHint?.contains(error.message) == true)
        editor.errors = []
        editor.decorate()
        editor.updateMessage()
        #expect(editor.source.errorLines.isEmpty)
        #expect(editor.source.textStorage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) == nil)
        #expect(editor.source.accessibilityHint == nil)
        #expect(editor.source.text == text)
    }
}
