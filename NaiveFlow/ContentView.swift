import SwiftUI

struct ContentView: View {
    @Environment(Operations.self) private var operations
    @Environment(DeepLinkManager.self) private var deepLinkManager
    @State private var showingDeepLinkAddSheet = false
    @State private var showingManualAddSheet = false
    @State private var pendingDeepLinkURL: String?

    var body: some View {
        HomeView()
            .sheet(isPresented: $showingDeepLinkAddSheet, onDismiss: { pendingDeepLinkURL = nil }) {
                DynamicSheet(animation: .snappy(duration: 0.3, extraBounce: 0)) {
                    AddProxyView(showingManualAddSheet: $showingManualAddSheet, deepLinkURL: pendingDeepLinkURL)
                        .environment(operations)
                }
            }
            .sheet(isPresented: $showingManualAddSheet) {
                ProxyEditorView { configuration in
                    operations.configurations.add(configuration)
                }
            }
            .onChange(of: deepLinkManager.url) { _, newValue in
                if let url = newValue {
                    pendingDeepLinkURL = url
                    deepLinkManager.url = nil
                    showingDeepLinkAddSheet = true
                }
            }
            .onOpenURL { deepLinkManager.handle(url: $0) }
    }
}
