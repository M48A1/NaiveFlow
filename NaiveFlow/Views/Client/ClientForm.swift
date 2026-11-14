import SwiftUI

/// Apply the desktop layout at the form itself, including forms presented in sheets.
struct ClientForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
#if os(macOS)
            .formStyle(.grouped)
#endif
    }
}
