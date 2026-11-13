import SwiftUI

struct HomeView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("首页", systemImage: "house.fill", value: 0) {
                NavigationStack { ClientHomeView() }
            }
            Tab("策略组", systemImage: "square.grid.2x2.fill", value: 1) {
                NavigationStack { ClientGroupsView() }
            }
            Tab("设置", systemImage: "gearshape.fill", value: 2) {
                NavigationStack { ClientSettingsView() }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .tint(.blue)
        .environment(model)
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
    }
}
