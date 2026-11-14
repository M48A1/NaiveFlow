import SwiftUI

struct LANProxySettingsView: View {
    @State private var enabled = false
    @State private var port = "8080"
    @State private var message: String?

    private var valid: Bool {
        guard let value = UInt16(port), value >= 1024 else { return false }
        return true
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable LAN Proxy", isOn: $enabled)
                LabeledContent("Port") {
                    TextField("8080", text: $port)
#if !os(tvOS)
                        .clientKeyboardType(.numberPad)
#endif
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("SOCKS5 TCP only. Requires the VPN to be running. Reconnect the VPN after saving changes.")
            }
            Section("Connection") {
                if !AWCore.getLANProxyAllowed() {
                    Text("LAN proxy is disabled by the active profile.")
                        .foregroundStyle(.secondary)
                }
                Text("Up to 3 devices by IPv4 address, 4 connections each and 4 simultaneous handshakes.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("The first 3 private Wi-Fi client addresses can connect. A device slot is freed when its last connection closes.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Idle connections close after 2 minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let address = LANProxyNetwork.wifiAddress() {
                    LabeledContent("Wi-Fi Address", value: address)
                } else {
                    Text("No private Wi-Fi IPv4 address available.")
                }
                Text("Uses the VPN’s current node or proxy chain for new connections. UDP relay is unavailable. Connections close after one hour.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("Save") {
                    do {
                        try LANProxySettings(enabled: enabled, port: UInt16(port)!).save()
                        message = String(localized: "Saved. Reconnect the VPN to apply.")
                    } catch { message = error.localizedDescription }
                }.disabled(!valid)
                if !valid { Text("Enter a port from 1024 to 65535.").foregroundStyle(.red) }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("LAN Proxy")
        .onAppear {
            let settings = LANProxySettings.load()
            enabled = settings.enabled
            port = String(settings.port)
        }
    }
}
