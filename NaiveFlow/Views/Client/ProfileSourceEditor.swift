import SwiftUI

#if os(iOS)
import UIKit

/// Error decoration belongs to the editor, never to the saved configuration text.
struct ProfileSourceEditor: UIViewRepresentable {
    @Binding var text: String
    let errors: [ConfigurationDiagnostic]
    let focus: UUID

    func makeUIView(context: Context) -> SourceEditor {
        let view = SourceEditor()
        view.source.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: SourceEditor, context: Context) {
        context.coordinator.parent = self
        let changed = view.source.text != text
        if changed { view.source.text = text }
        if changed || view.errors != errors {
            view.errors = errors
            view.decorate()
        }
        if view.focus != focus {
            view.focus = focus
            if let range = errors.compactMap({ $0.line.flatMap { view.source.range(forLine: $0) } }).first {
                view.source.selectedRange = NSRange(location: range.location, length: 0)
                view.layoutIfNeeded()
                view.source.scrollRangeToVisible(range)
            }
        }
        view.updateMessage()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ProfileSourceEditor
        init(parent: ProfileSourceEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView.superview as? SourceEditor)?.updateMessage()
        }
    }

    final class SourceEditor: UIView {
        let source = NumberedTextView(usingTextLayoutManager: false)
        private let message = UILabel()
        var errors: [ConfigurationDiagnostic] = []
        var focus: UUID?

        override init(frame: CGRect) {
            super.init(frame: frame)
            source.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            source.backgroundColor = .clear
            source.contentMode = .redraw
            source.textColor = .label
            source.textContainerInset = UIEdgeInsets(top: 8, left: 34, bottom: 12, right: 4)
            source.autocorrectionType = .no
            source.autocapitalizationType = .none
            source.smartQuotesType = .no
            source.smartDashesType = .no
            source.smartInsertDeleteType = .no
            source.keyboardDismissMode = .interactive
            source.accessibilityLabel = "Profile Content"
            source.isAccessibilityElement = true
            message.font = .preferredFont(forTextStyle: .caption1)
            message.textColor = .systemRed
            message.numberOfLines = 0
            message.accessibilityIdentifier = "Profile Source Error"
            for child in [source, message] {
                child.translatesAutoresizingMaskIntoConstraints = false
                addSubview(child)
            }
            NSLayoutConstraint.activate([
                source.topAnchor.constraint(equalTo: topAnchor),
                source.leadingAnchor.constraint(equalTo: leadingAnchor),
                source.trailingAnchor.constraint(equalTo: trailingAnchor),
                source.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -6),
                message.leadingAnchor.constraint(equalTo: leadingAnchor),
                message.trailingAnchor.constraint(equalTo: trailingAnchor),
                message.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            message.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func decorate() {
            let storage = source.textStorage
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: whole)
            storage.removeAttribute(.underlineStyle, range: whole)
            storage.removeAttribute(.underlineColor, range: whole)
            storage.addAttributes([.font: source.font!, .foregroundColor: UIColor.label], range: whole)
            for error in errors {
                guard let line = error.line, let range = source.range(forLine: line) else { continue }
                storage.addAttributes([
                    .backgroundColor: UIColor.systemRed.withAlphaComponent(0.12),
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: UIColor.systemRed
                ], range: range)
            }
            storage.endEditing()
            source.typingAttributes = [.font: source.font!, .foregroundColor: UIColor.label]
            source.errorLines = Set(errors.compactMap(\.line))
            source.setNeedsDisplay()
        }

        func updateMessage() {
            let location = min(source.selectedRange.location, source.textStorage.length)
            let line = source.lineNumber(at: location)
            let selected = errors.filter { $0.line == line }
            // Errors without source locations still have a visible explanation.
            let visible = selected.isEmpty ? errors.filter { $0.line == nil } : selected
            message.text = visible.map { error in
                error.line.map { "Saved draft · Line \($0): \(error.message)" } ?? "Saved draft · \(error.message)"
            }.joined(separator: "\n")
            source.accessibilityHint = message.text?.isEmpty == false ? message.text : nil
        }
    }

    final class NumberedTextView: UITextView {
        var errorLines: Set<Int> = []

        func lineNumber(at location: Int) -> Int {
            let string = text as NSString
            var start = 0
            var number = 1
            while start < string.length {
                let end = NSMaxRange(string.lineRange(for: NSRange(location: start, length: 0)))
                if location < end { break }
                // Reaching the end of an unterminated last line isn't a new line.
                if end == string.length, !endsInNewline(string, at: end) { break }
                start = end
                number += 1
            }
            return number
        }

        func range(forLine line: Int) -> NSRange? {
            guard line > 0 else { return nil }
            let string = text as NSString
            var start = 0
            for _ in 1..<line {
                guard start < string.length else { return nil }
                let end = NSMaxRange(string.lineRange(for: NSRange(location: start, length: 0)))
                guard end < string.length || endsInNewline(string, at: end) else { return nil }
                start = end
            }
            guard start <= string.length else { return nil }
            return string.lineRange(for: NSRange(location: start, length: 0))
        }

        private func endsInNewline(_ string: NSString, at end: Int) -> Bool {
            guard end > 0 else { return false }
            return string.substring(with: NSRange(location: end - 1, length: 1)).rangeOfCharacter(from: .newlines) != nil
        }

        override func draw(_ rect: CGRect) {
            super.draw(rect)
            let string = text as NSString
            layoutManager.ensureLayout(for: textContainer)
            var start = 0
            var line = 1
            while start < string.length {
                let range = string.lineRange(for: NSRange(location: start, length: 0))
                let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: start, length: 1), actualCharacterRange: nil)
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
                let y = fragment.minY + textContainerInset.top
                if y + fragment.height >= rect.minY, y <= rect.maxY {
                    let label = errorLines.contains(line) ? "!\(line)" : "\(line)"
                    (label as NSString).draw(in: CGRect(x: 0, y: y, width: 32, height: fragment.height), withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: errorLines.contains(line) ? UIColor.systemRed : UIColor.secondaryLabel
                    ])
                }
                start = NSMaxRange(range)
                line += 1
            }
        }
    }
}

#else
import AppKit

struct ProfileSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let errors: [ConfigurationDiagnostic]
    let focus: UUID

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        if editor.string != text { editor.string = text }

        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let layout = editor.layoutManager
        layout?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        let errorLines = Set(errors.compactMap(\.line))
        var firstError: NSRange?
        var location = 0
        var line = 1
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            if errorLines.contains(line) {
                layout?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.15), forCharacterRange: range)
                if firstError == nil { firstError = range }
            }
            location = NSMaxRange(range)
            line += 1
        }
        if coordinator.focus != focus {
            coordinator.focus = focus
            if let firstError {
                editor.setSelectedRange(NSRange(location: firstError.location, length: 0))
                editor.scrollRangeToVisible(firstError)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProfileSourceEditor
        var focus: UUID?

        init(parent: ProfileSourceEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
#endif
