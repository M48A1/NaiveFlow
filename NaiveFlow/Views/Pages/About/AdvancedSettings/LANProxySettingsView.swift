import SwiftUI

struct LANProxySettingsView: View {
    @State private var enabled = false
    @State private var port = "8080"
    @State private var clients = ""
    @State private var message: String?

    private var entries: [String] {
        clients.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private var valid: Bool {
        guard let value = UInt16(port), value >= 1024 else { return false }
        return entries.allSatisfy { IPRoute($0) != nil }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable LAN Proxy", isOn: $enabled)
                LabeledContent("Port") {
                    TextField("8080", text: $port).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("HTTP CONNECT and SOCKS5 CONNECT share this port. Requires the VPN to be running. Reconnect the VPN after saving changes.")
            }
            Section {
                TextEditor(text: $clients).frame(minHeight: 120)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: {
                Text("Allowed Client Addresses")
            } footer: {
                Text("One IPv4 address or CIDR per line, for example 192.168.1.20 or 192.168.1.0/24. Only private Wi-Fi clients are accepted. An empty list denies everyone.")
            }
            Section("Connection") {
                if let address = LANProxyACL.wifiAddress() {
                    LabeledContent("Wi-Fi Address", value: address)
                } else {
                    Text("No private Wi-Fi IPv4 address available.")
                }
                Text("Uses the VPN’s current node or proxy chain for new connections. HTTP CONNECT and SOCKS5 TCP only; UDP relay is unavailable. Connections close after one hour.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("Save") {
                    do {
                        try LANProxySettings(enabled: enabled, port: UInt16(port)!, allowedClients: entries).save()
                        message = String(localized: "Saved. Reconnect the VPN to apply.")
                    } catch { message = error.localizedDescription }
                }.disabled(!valid)
                if !valid { Text("Enter a port from 1024 to 65535 and valid IPv4 addresses or CIDRs.").foregroundStyle(.red) }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("LAN Proxy")
        .onAppear {
            let settings = LANProxySettings.load()
            enabled = settings.enabled
            port = String(settings.port)
            clients = settings.allowedClients.joined(separator: "\n")
        }
    }
}
