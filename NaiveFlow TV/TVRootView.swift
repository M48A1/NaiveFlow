import SwiftUI

struct TVRootView: View {
    let container: AppContainer
    @State private var model: ClientModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reviewSubscriptionsOnOpen") private var reviewSubscriptionsOnOpen = false
    @AppStorage("lastSubscriptionReviewCheck") private var lastReviewCheck = 0.0

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
        .sheet(item: Binding(
            get: { model.subscriptionReview },
            set: { review in
                if let review { model.subscriptionReview = review }
                else { model.discardSubscriptionReview() }
            }
        )) { review in
            ClientSubscriptionReviewView(review: review)
        }
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
                .background(.regularMaterial)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            container.stats.setPresentationActive(phase == .active)
            if phase == .active { model.refresh() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, reviewSubscriptionsOnOpen, !model.isBusy, !model.hasSavedDraft, model.subscriptionReview == nil,
                  Date().timeIntervalSince1970 - lastReviewCheck > 86_400 else { return }
            if await model.prepareSubscriptionUpdate() { lastReviewCheck = Date().timeIntervalSince1970 }
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
