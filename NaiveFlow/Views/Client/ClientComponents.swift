import SwiftUI

struct ClientCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .designCard()
    }
}

struct ClientSectionIcon: View {
    var symbol: String
    var color: Color = .blue
    var body: some View {
        Image(systemName: symbol).font(.system(size: DesignSystem.Icon.regular, weight: .semibold))
            .foregroundStyle(color).frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

struct ClientNodeRow: View {
    let node: ProxyConfiguration
    var selected = false
    var latency: LatencyResult?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: DesignSystem.Icon.regular)).foregroundStyle(selected ? DesignSystem.Colors.accent : ClientAppearance.tertiaryLabel)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName).designText(.contentTitle, weight: selected ? .semibold : .medium)
                        .foregroundStyle(selected ? DesignSystem.Colors.accent : .primary).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(node.outboundProtocol.name.uppercased()).designText(.micro, weight: .medium)
                        if case .vless(let vless) = node.outbound {
                            if vless.flow != nil { badge("V") }
                            badge("TLS")
                        }
                    }.foregroundStyle(DesignSystem.Colors.secondaryText)
                }
                Spacer(minLength: 4)
                latencyView
            }.frame(minHeight: 52).padding(.horizontal, DesignSystem.Card.padding).padding(.vertical, 7)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(node.name), \(node.outboundProtocol.name)\(selected ? ", selected" : "")")
    }

    private var displayName: String {
        let cleaned = node.name.unicodeScalars.filter { !(0x1F1E6...0x1F1FF).contains($0.value) }
        let value = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? node.name : value
    }
    private func badge(_ text: String) -> some View {
        Text(text).designText(.micro, weight: .semibold).padding(.horizontal, 3).padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
    }
    @ViewBuilder private var latencyView: some View {
        switch latency {
        case .success(let ms):
            Text("\(ms) ms").designText(.caption, weight: .medium).monospacedDigit()
                .foregroundStyle(ms < 150 ? DesignSystem.Colors.success : ms < 400 ? DesignSystem.Colors.warning : DesignSystem.Colors.error)
            Image(systemName: "cellularbars").font(.system(size: DesignSystem.Icon.small)).foregroundStyle(ms < 150 ? DesignSystem.Colors.success : DesignSystem.Colors.warning)
        case .testing: ProgressView().controlSize(.small)
        case .failed: Text("Timed Out").designText(.caption).foregroundStyle(DesignSystem.Colors.error)
        case .insecure: Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(DesignSystem.Colors.warning)
        case nil: Text("—").designText(.caption).foregroundStyle(DesignSystem.Colors.tertiaryLabel)
        }
    }
}

nonisolated enum ClientPalette {
    static let colors = DesignSystem.Colors.policyPalettes
    static func index(for name: String) -> Int { name.utf8.reduce(0) { ($0 + Int($1)) % colors.count } }
}

struct ClientPolicyCard: View {
    var name: String
    var selected: String
    var style: ClientGroupStyle
    var iconURL: String? = nil
    @ScaledMetric(relativeTo: .body) private var cardHeight = DesignSystem.Card.policyHeight
    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: ClientPalette.colors[abs(style.palette) % ClientPalette.colors.count], startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                Circle().fill(.white.opacity(0.10)).frame(width: geo.size.width * 0.94)
                    .offset(x: geo.size.width * 0.55, y: -geo.size.height * 0.25)
                RoundedRectangle(cornerRadius: 36).fill(.white.opacity(0.09))
                    .frame(width: geo.size.width, height: geo.size.height * 1.3)
                    .rotationEffect(.degrees(-38)).offset(x: geo.size.width * 0.60, y: geo.size.height * 0.48)
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let url = ProxyGroupIconURL.parse(iconURL) {
                        AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: style.symbol) }
                    } else { Image(systemName: style.symbol).font(.system(size: DesignSystem.Icon.preview, weight: .medium)) }
                }.frame(width: 34, height: 34).foregroundStyle(.white.opacity(0.98))
                Spacer(minLength: 17)
                Text(name).designText(.cardTitle).lineLimit(1)
                HStack(spacing: 4) {
                    Text(selected).designText(.caption, weight: .medium).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.top, 4).foregroundStyle(.white.opacity(0.88))
            }.padding(DesignSystem.Card.policyPadding)
        }
        .frame(height: cardHeight).clipShape(RoundedRectangle(cornerRadius: DesignSystem.Card.policyRadius, style: .continuous))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

struct ClientNewGroupCard: View {
    @ScaledMetric(relativeTo: .body) private var cardHeight = DesignSystem.Card.policyHeight
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.compact) {
            Image(systemName: "plus.circle.fill").font(.system(size: DesignSystem.Icon.add))
            Text("New Group").designText(.contentTitle)
        }
        .frame(maxWidth: .infinity).frame(height: cardHeight)
        .foregroundStyle(DesignSystem.Colors.accent)
        .background(DesignSystem.Colors.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: DesignSystem.Card.policyRadius))
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Card.policyRadius))
    }
}
