import SwiftUI

struct TVRootView: View {
    let container: AppContainer
    @State private var model: ClientModel
    @Environment(\.scenePhase) private var scenePhase

    init(container: AppContainer) {
        self.container = container
        _model = State(initialValue: ClientModel(operations: Operations(container: container)))
    }

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                NavigationStack {
                    TVClientHomeView(tunnel: container.tunnel, stats: container.stats,
                                     latency: container.latency)
                }
            }
            Tab("Groups", systemImage: "square.grid.2x2.fill") {
                NavigationStack { TVClientGroupsView(latency: container.latency, tunnel: container.tunnel) }
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                NavigationStack { TVClientSettingsView(container: container) }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .environment(model)
        .safeAreaInset(edge: .bottom) {
            if let title = model.activeResourceTitle {
                HStack {
                    ProgressView()
                    Text(title)
                    Spacer()
                    Button("Cancel") { model.cancelResourceOperation() }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            container.stats.setPresentationActive(phase == .active)
            if phase == .active { model.refresh() }
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
