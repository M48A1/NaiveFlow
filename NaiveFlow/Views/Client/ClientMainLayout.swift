import SwiftUI

/// Shared spacing for the three main tabs, inside each page's scrollable content.
enum ClientMainLayout {
    static var horizontalInset: CGFloat { DesignSystem.Layout.horizontalInset }
    static var topInset: CGFloat { DesignSystem.Layout.topInset }
}

private struct ClientMainContentModifier: ViewModifier {
    var maximumWidth: CGFloat
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
#endif

    private var topInset: CGFloat {
#if os(iOS)
        sizeClass == .compact ? DesignSystem.Layout.compactTopInset : ClientMainLayout.topInset
#else
        ClientMainLayout.topInset
#endif
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maximumWidth)
            .padding(.horizontal, ClientMainLayout.horizontalInset)
            .padding(.top, topInset)
            .padding(.bottom, DesignSystem.Layout.bottomInset)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension View {
    func clientMainContent(maximumWidth: CGFloat = DesignSystem.Layout.readingWidth) -> some View {
        modifier(ClientMainContentModifier(maximumWidth: maximumWidth))
    }
}
