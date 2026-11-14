import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ClientAppearance {
#if os(macOS)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
#else
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let tertiaryLabel = Color(uiColor: .tertiaryLabel)
#endif
}

enum ClientSystem {
    static func copy(_ text: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#else
        UIPasteboard.general.string = text
#endif
    }

    static func openNotificationSettings() {
#if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
#else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
#endif
    }
}

#if os(macOS)
enum ClientKeyboardType {
    case URL, numberPad, decimalPad, numbersAndPunctuation
}
#else
typealias ClientKeyboardType = UIKeyboardType
#endif

extension ToolbarItemPlacement {
    static var clientToolbarTrailing: Self {
#if os(macOS)
        .primaryAction
#else
        .topBarTrailing
#endif
    }
}

extension View {
    @ViewBuilder func clientInlineTitle() -> some View {
#if os(macOS)
        self
#else
        navigationBarTitleDisplayMode(.inline)
#endif
    }

    @ViewBuilder func clientNoAutocapitalization() -> some View {
#if os(macOS)
        self
#else
        textInputAutocapitalization(.never)
#endif
    }

    @ViewBuilder func clientKeyboardType(_ type: ClientKeyboardType) -> some View {
#if os(macOS)
        self
#else
        keyboardType(type)
#endif
    }

    @ViewBuilder func clientInteractiveKeyboardDismissal() -> some View {
#if os(macOS)
        self
#else
        scrollDismissesKeyboard(.interactively)
#endif
    }

    @ViewBuilder func clientKeyboardDone() -> some View {
#if os(macOS)
        self
#else
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
#endif
    }

    @ViewBuilder func clientNavigationBar(visible: Bool) -> some View {
#if os(macOS)
        self
#else
        toolbar(visible ? .visible : .hidden, for: .navigationBar)
#endif
    }

    @ViewBuilder func clientNavigationLinkIndicators() -> some View {
#if os(macOS)
        self
#else
        navigationLinkIndicatorVisibility(.hidden)
#endif
    }

    @ViewBuilder func clientSettingsNavigationBar() -> some View {
#if os(macOS)
        self
#else
        toolbar(.visible, for: .navigationBar)
            .toolbarBackground(ClientAppearance.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
#endif
    }

    @ViewBuilder func clientEditorWindow() -> some View {
#if os(macOS)
        frame(minWidth: 520, idealWidth: 650, minHeight: 460, idealHeight: 620)
#else
        self
#endif
    }

    @ViewBuilder func clientSheetDetents() -> some View {
#if os(macOS)
        frame(minWidth: 480, minHeight: 400)
#else
        presentationDetents([.medium, .large])
#endif
    }

    @ViewBuilder func clientSheetDragIndicator() -> some View {
#if os(macOS)
        self
#else
        presentationDragIndicator(.visible)
#endif
    }
}

extension View {
    @ViewBuilder func clientSwipeActions<Actions: View>(
        edge: HorizontalEdge = .trailing,
        allowsFullSwipe: Bool = true,
        @ViewBuilder content: () -> Actions
    ) -> some View {
#if os(macOS)
        contextMenu { content() }
#else
        swipeActions(edge: edge, allowsFullSwipe: allowsFullSwipe) { content() }
#endif
    }
}
