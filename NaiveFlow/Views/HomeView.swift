//
//  HomeView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/1/26.
//

import SwiftUI
import NetworkExtension

struct HomeView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedTab: Page = .launchpad
    @State private var toolboxPath: [Page] = []
    @State private var preferredColumn = NavigationSplitViewColumn.detail

    // Keep the same view hierarchy across folds. Sidebar destinations share the
    // Toolbox navigation stack, so they remain reachable when the sidebar collapses.
    private var sidebarSelection: Binding<Page?> {
        Binding {
            selectedTab == .toolbox ? (toolboxPath.first ?? .toolbox) : selectedTab
        } set: { page in
            guard let page else { return }
            switch page {
            case .launchpad, .dashboard:
                selectedTab = page
            case .toolbox:
                toolboxPath = []
                selectedTab = .toolbox
            default:
                if toolboxPath.first != page {
                    toolboxPath = [page]
                }
                selectedTab = .toolbox
            }
            preferredColumn = .detail
        }
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            List(selection: sidebarSelection) {
                Section {
                    Label(Page.launchpad.name, image: Page.launchpad.symbol)
                        .tag(Page.launchpad)
                    sidebarRow(.dashboard)
                    sidebarRow(.toolbox)
                }
                Section("App") {
                    sidebarRow(.data)
                    sidebarRow(.personalization)
                }
                Section("VPN") {
                    sidebarRow(.tunnel)
                    sidebarRow(.purify)
                    sidebarRow(.routing)
                    sidebarRow(.mitm)
                    sidebarRow(.modules)
                    sidebarRow(.configuration)
                }
                Section("Security") {
                    sidebarRow(.trustedCertificates)
                    sidebarRow(.trustedNetwork)
                }
                Section("More") {
                    sidebarRow(.diagnosis)
                    sidebarRow(.about)
                }
            }
        } detail: {
            TabView(selection: $selectedTab) {
                Tab(Page.launchpad.name, image: Page.launchpad.symbol, value: Page.launchpad) {
                    LaunchpadView()
                }
                Tab(Page.dashboard.name, systemImage: Page.dashboard.symbol, value: Page.dashboard) {
                    DashboardView()
                }
                Tab(Page.toolbox.name, systemImage: Page.toolbox.symbol, value: Page.toolbox) {
                    ToolboxView(path: $toolboxPath)
                }
            }
            .toolbar(horizontalSizeClass == .regular ? .hidden : .visible, for: .tabBar)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func sidebarRow(_ page: Page) -> some View {
        Label(page.name, systemImage: page.symbol)
            .tag(page)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Connected") {
    let container = AppContainer.preview()
    container.selection.select(ProxyConfiguration(
        name: "🇺🇸 Los Angeles",
        serverAddress: "203.0.113.10",
        serverPort: 443,
        outbound: .socks5(SOCKS5Configuration())
    ))
    container.tunnel.setStatusForPreview(.connected)

    return HomeView()
        .environment(AppSettings())
        .environment(Operations(container: container))
        .environment(container.tunnel)
        .environment(container.selection)
        .environment(container.latency)
        .environment(container.configurationStore)
        .environment(container.chainStore)
        .environment(container.groupStore)
        .environment(container.subscriptionStore)
        .environment(ConnectionStats.previewSeeded())
}
#endif
