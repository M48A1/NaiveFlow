import SwiftUI

struct ClientResourceCenterView: View {
    @Environment(ClientModel.self) private var model
    @AppStorage("reviewSubscriptionsOnOpen") private var reviewOnOpen = false
    var body: some View {
        List {
            Section {
                Toggle("Review Subscriptions on Open", isOn: $reviewOnOpen)
            } footer: { Text("When enabled, check subscriptions on entering the foreground, at most once every 24 hours. Downloads are staged for review and never applied automatically.") }
            Section("Batch Updates") {
                Button("Review All Subscription Updates") {
                    Task { _ = await model.prepareSubscriptionUpdate() }
                }
                .disabled(model.subscriptionReview != nil || !hasResource("Subscription"))
                Button("Update All Modules") { Task { _ = await model.refreshAllModules() } }
                    .disabled(!hasResource("Module"))
                Button("Update All Rule Sets") {
                    Task { _ = await model.manageResource(.update(.ruleSets())) }
                }
                .disabled(!hasResource("Rule Set"))
                Button("Update GeoIP Sources") { Task { _ = await model.manageResource(.update(.geo(site: false))) } }
                    .disabled(!hasResource("GeoIP"))
                Button("Update GeoSite Sources") { Task { _ = await model.manageResource(.update(.geo(site: true))) } }
                    .disabled(!hasResource("GeoSite"))
            }
            .disabled(model.isBusy || model.activeResourceTitle != nil)
            ForEach(model.resources) { resource in
                Section(resource.kind + " · " + resource.name) {
                    Text(resource.source).designText(.caption).foregroundStyle(DesignSystem.Colors.secondaryText)
#if !os(tvOS)
                        .textSelection(.enabled)
#endif
                    if let activity = model.resourceActivity[resource.id] {
                        if let date = activity.attemptedAt { LabeledContent("Last Attempt") { Text(date, style: .relative) } }
                        if let date = activity.succeededAt { LabeledContent("Last Successful Update") { Text(date, style: .relative) } }
                        if activity.awaitingReview { Label("Downloaded · Awaiting Review", systemImage: "doc.text.magnifyingglass") }
                        if let version = activity.version { LabeledContent("Applied Version", value: String(version.prefix(8))) }
                        if let error = activity.error { Text(error).designText(.caption).foregroundStyle(DesignSystem.Colors.error) }
                    } else { Text("No update recorded yet").foregroundStyle(DesignSystem.Colors.secondaryText) }
                    Button("Update") { Task { await update(resource) } }.disabled(model.isBusy)
                }
            }
            if model.resources.isEmpty { ContentUnavailableView("No Remote Resources", systemImage: "arrow.down.circle") }
            if model.activeResourceTitle != nil { Button("Cancel Current Download", role: .destructive) { model.cancelResourceOperation() } }
        }
        .navigationTitle("Resource Updates")
#if !os(tvOS)
        .clientInlineTitle()
#endif
    }
    private func hasResource(_ kind: String) -> Bool {
        model.resources.contains { $0.kind == kind }
    }

    private func update(_ resource: ClientResourceDescriptor) async {
        switch resource.kind {
        case "Subscription":
            if let id = UUID(uuidString: String(resource.id.dropFirst(13))) { _ = await model.prepareSubscriptionUpdate(ids: [id]) }
        case "Module":
            if let id = UUID(uuidString: String(resource.id.dropFirst(7))) { _ = await model.manageResource(.update(.modules(ids: [id]))) }
        case "Rule Set": _ = await model.manageResource(.update(.ruleSets(sources: [resource.source])))
        default: _ = await model.manageResource(.update(.geo(site: resource.kind == "GeoSite")))
        }
    }
}
