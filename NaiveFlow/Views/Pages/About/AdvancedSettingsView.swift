import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        List {
            NavigationLink("LAN Proxy") { LANProxySettingsView() }
            Toggle("Remnawave HWID", isOn: $settings.remnawaveHWIDEnabled)
        }
        .navigationTitle("Advanced Settings")
    }
}
