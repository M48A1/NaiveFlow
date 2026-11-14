import SwiftUI

struct ClientCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(ClientAppearance.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.025), lineWidth: 1))
    }
}

struct ClientSectionIcon: View {
    var symbol: String
    var color: Color = .blue
    var body: some View {
        Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
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
                    .font(.system(size: 22)).foregroundStyle(selected ? Color.blue : ClientAppearance.tertiaryLabel)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName).font(.system(size: 16, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.blue : .primary).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(node.outboundProtocol.name.uppercased()).font(.system(size: 10, weight: .medium))
                        if case .vless(let vless) = node.outbound {
                            if vless.flow != nil { badge("V") }
                            badge("TLS")
                        }
                    }.foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                latencyView
            }.frame(minHeight: 52).padding(.horizontal, 20).padding(.vertical, 7)
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
        Text(text).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 3).padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
    }
    @ViewBuilder private var latencyView: some View {
        switch latency {
        case .success(let ms):
            Text("\(ms) ms").font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(ms < 150 ? Color.green : ms < 400 ? .orange : .red)
            Image(systemName: "cellularbars").font(.system(size: 14)).foregroundStyle(ms < 150 ? Color.green : .orange)
        case .testing: ProgressView().controlSize(.small)
        case .failed: Text("Timed Out").font(.caption).foregroundStyle(.red)
        case .insecure: Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
        case nil: Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

nonisolated enum ClientPalette {
    static let colors: [[Color]] = [
        [Color(red: 0.08, green: 0.75, blue: 0.64), Color(red: 0.66, green: 0.94, blue: 0.23)],
        [Color(red: 0.04, green: 0.28, blue: 0.73), Color(red: 0.02, green: 0.78, blue: 0.86)],
        [Color(red: 0.35, green: 0.25, blue: 0.92), Color(red: 0.90, green: 0.23, blue: 0.80)],
        [Color(red: 0.03, green: 0.43, blue: 0.96), Color(red: 0.02, green: 0.76, blue: 0.97)],
        [Color(red: 0.17, green: 0.13, blue: 0.47), Color(red: 0.63, green: 0.17, blue: 0.87)],
        [Color(red: 0.12, green: 0.37, blue: 0.48), Color(red: 0.05, green: 0.68, blue: 0.65)],
        [Color(red: 0.73, green: 0.24, blue: 0.96), Color(red: 0.99, green: 0.39, blue: 0.68)],
        [Color(red: 0.41, green: 0.35, blue: 0.89), Color(red: 0.22, green: 0.52, blue: 0.98)],
        [Color(red: 1.0, green: 0.36, blue: 0.33), Color(red: 1.0, green: 0.79, blue: 0.22)],
        [Color(red: 0.12, green: 0.69, blue: 0.91), Color(red: 0.75, green: 0.24, blue: 0.97)]
    ]
    static func index(for name: String) -> Int { name.utf8.reduce(0) { ($0 + Int($1)) % colors.count } }
}

struct ClientPolicyCard: View {
    var name: String
    var selected: String
    var style: ClientGroupStyle
    var iconURL: String? = nil
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
                    } else { Image(systemName: style.symbol).font(.system(size: 27, weight: .medium)) }
                }.frame(width: 34, height: 34).foregroundStyle(.white.opacity(0.98))
                Spacer(minLength: 17)
                Text(name).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(selected).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.top, 4).foregroundStyle(.white.opacity(0.88))
            }.padding(18)
        }
        .frame(height: 146).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

private struc
