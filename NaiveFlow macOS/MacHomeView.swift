import SwiftUI

struct MacHomeView: View {
    @Environment(TunnelController.self) private var tunnel
    @Environment(ConfigurationStore.self) private var configurationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("NaiveFlow").font(.title.bold())
                    Text("原生 macOS 客户端").foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            Divider()

            Text("网络核心已复用现有配置与代理协议。")
                .foregroundStyle(.secondary)
            Text("当前配置：\(configurationStore.configurations.count) 个节点")
                .font(.callout)

            HStack {
                Button(tunnel.hasRunningTunnel ? "断开连接" : "连接") {
                    if tunnel.hasRunningTunnel {
                        tunnel.disconnect()
                    } else if let configuration = configurationStore.configurations.first {
                        tunnel.connect(using: configuration)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!tunnel.isManagerReady && !tunnel.hasRunningTunnel)

                if let error = tunnel.startError {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 520, minHeight: 300)
    }

    private var statusBadge: some View {
        Text(tunnel.status.localizedText)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tunnel.hasRunningTunnel ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
            .clipShape(Capsule())
    }
}
