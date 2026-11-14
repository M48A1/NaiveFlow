import SwiftUI

struct HomeView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @AppStorage("reviewSubscriptionsOnOpen") private var reviewSubscriptionsOnOpen = false
    @AppStorage("lastSubscriptionReviewCheck") private var lastReviewCheck = 0.0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: 0) {
                NavigationStack { ClientHomeView() }
            }
            Tab("Groups", systemImage: "square.grid.2x2.fill", value: 1) {
                NavigationStack { ClientGroupsView() }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: 2) {
                NavigationStack { ClientSettingsView() }
            }
        }
#if os(iOS)
        .tabViewStyle(.tabBarOnly)
#endif
        .tint(.blue)
        .environment(model)
        .alert("Operation Failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(item: Binding(get: { model.subscriptionReview }, set: { value in if let value { model.subscriptionReview = value } else { model.discardSubscriptionReview() } })) { review in
            ClientSubscriptionReviewView(review: review)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let title = model.activeResourceTitle {
                HStack { ProgressView(); Text(title).font(.caption); Spacer(); Button("Cancel") { model.cancelResourceOperation() } }
                    .padding(12).background(.bar)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, reviewSubscriptionsOnOpen, !model.isBusy, !model.hasSavedDraft, model.subscriptionReview == nil,
                  Date().timeIntervalSince1970 - lastReviewCheck > 86_400 else { return }
            if await model.prepareSubscriptionUpdate() { lastReviewCheck = Date().timeIntervalSince1970 }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
    }
}
