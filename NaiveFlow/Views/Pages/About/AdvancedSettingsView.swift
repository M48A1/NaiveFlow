import SwiftUI

struct AdvancedSettingsView: View {
    var body: some View {
        List {
            NavigationLink("LAN Proxy") { LANProxySettingsView() }
            NavigationLink("Subscription Requests") { ClientSubscriptionRequestSettingsView() }
        }
        .navigationTitle("Advanced Settings")
    }
}
