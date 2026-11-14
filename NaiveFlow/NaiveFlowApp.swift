//
//  NaiveFlowApp.swift
//  NaiveFlow
//
//  Created by NodePassProject on 1/23/26.
//

import SwiftUI
import NetworkExtension
import UserNotifications

@main
struct NaiveFlowApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("notifyConnectionEvents") private var notifyConnectionEvents = false
    @State private var container: AppContainer
    @State private var operations: Operations
    @State private var client: ClientModel
    @State private var mitmCertificateController = MITMCertificateController()
    @State private var deepLinkManager = DeepLinkManager()

    init() {
        let container = AppContainer()
        container.start()
        let operations = Operations(container: container)

        _container = State(initialValue: container)
        _operations = State(initialValue: operations)
        _client = State(initialValue: ClientModel(operations: operations))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
#if os(macOS)
                .frame(minWidth: 560, minHeight: 500)
                .formStyle(.grouped)
#endif
                .clientNavigationLinkIndicators()
                .preferredColorScheme(DesignSystem.appearance)
                .designText(.body)
                .tint(DesignSystem.Colors.accent)
                .environment(\.locale, Locale(identifier: "en"))
                .environment(operations)
                .environment(client)
                .environment(container.tunnel)
                .environment(container.selection)
                .environment(container.latency)
                .environment(mitmCertificateController)
                .environment(deepLinkManager)
        }
#if os(macOS)
        .defaultSize(width: 800, height: 760)
        .windowResizability(.contentMinSize)
#endif
        .onChange(of: container.tunnel.rawStatus) { _, status in
            guard scenePhase != .active, notifyConnectionEvents else { return }
            guard status == .connected || status == .disconnected else { return }
            let content = UNMutableNotificationContent()
            content.title = "NaiveFlow"
            content.body = status == .connected ? "Proxy connected" : container.tunnel.startError == nil ? "Proxy stopped" : "Proxy connection failed"
            content.sound = .default
            let request = UNNotificationRequest(identifier: "naiveflow.connection", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
