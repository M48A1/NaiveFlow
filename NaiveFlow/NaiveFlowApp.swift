//
//  NaiveFlowApp.swift
//  NaiveFlow
//
//  Created by NodePassProject on 1/23/26.
//

import SwiftUI

@main
struct NaiveFlowApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: AppContainer
    @State private var operations: Operations
    @State private var settings: AppSettings
    @State private var mitmCertificateController = MITMCertificateController()
    @State private var deepLinkManager = DeepLinkManager()

    init() {
        let container = AppContainer()
        container.start()
        let operations = Operations(container: container)

        let settings = AppSettings()
        Task { await CloudSync.shared.start { keys in await operations.reload(keys) } }

        _container = State(initialValue: container)
        _operations = State(initialValue: operations)
        _settings = State(initialValue: settings)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .dynamicTypeSize(...DynamicTypeSize.large)
                .environment(operations)
                .environment(container.tunnel)
                .environment(container.selection)
                .environment(container.latency)
                .environment(container.stats)
                .environment(container.configurationStore)
                .environment(container.chainStore)
                .environment(container.groupStore)
                .environment(container.subscriptionStore)
                .environment(settings)
                .environment(mitmCertificateController)
                .environment(deepLinkManager)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            container.stats.setPresentationActive(phase == .active)
        }
    }
}
