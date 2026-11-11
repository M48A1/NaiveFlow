import SwiftUI

@main
struct NaiveFlowMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var container: AppContainer

    init() {
        let container = AppContainer()
        container.start()
        _container = State(initialValue: container)
    }

    var body: some Scene {
        WindowGroup("NaiveFlow") {
            MacHomeView()
                .environment(container.appState)
                .environment(container.tunnel)
                .environment(container.selection)
                .environment(container.chainStore)
                .environment(container.stats)
                .environment(container.configurationStore)
                .environment(container.groupStore)
                .environment(container.subscriptionStore)
                .environment(container.routingRuleSetStore)
                .environment(container.mitmRuleSetStore)
                .environment(container.moduleStore)
                .environment(container.certificateStore)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            container.stats.setPresentationActive(phase == .active)
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)
    }
}
