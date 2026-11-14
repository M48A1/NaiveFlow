import SwiftUI

struct AdvancedSettingsView: View {
    var body: some View {
        List {
            NavigationLink("LAN Proxy") { LANProxySettingsView() }
        }
        .navigationTitle("Advanced Settings")
    }
}
