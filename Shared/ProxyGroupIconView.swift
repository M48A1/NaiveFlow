#if canImport(SwiftUI)
import SwiftUI

struct ProxyGroupIconView: View {
    let iconURL: String?
    var size: CGFloat = 28

    var body: some View {
        AsyncImage(url: ProxyGroupIconURL.parse(iconURL)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "folder")
                    .resizable().scaledToFit()
                    .padding(size * 0.12)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .accessibilityHidden(true)
    }
}
#endif
