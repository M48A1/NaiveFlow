import SwiftUI

@main
struct NaiveFlowMacApp: App {
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
                .environment(container.stats)
                .environment(container.configurationStore)
                .environment(container.groupStore)
                .environment(container.subscriptionStore)
                .environment(container.routingRuleSetStore)
                .environment(container.mitmRuleSetStore)
                .environment(container.moduleStore)
                .environment(container.certificateStore)
        }
        .windowResizability(.contentSize)
    }
}
