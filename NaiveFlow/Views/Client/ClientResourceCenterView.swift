import SwiftUI

struct ClientResourceCenterView: View {
    @Environment(ClientModel.self) private var model
    @AppStorage("reviewSubscriptionsOnOpen") private var reviewOnOpen = false
    var body: some View {
        List {
            Section {
                Toggle("Review Subscriptions on Open", isOn: $reviewOnOpen)
            } footer: { Text("When enabled, check subscriptions on entering the foreground, at most once every 24 hours. Downloads are staged for review and never applied automatically.") }
            ForEach(model.resources) { resource in
                Section(resource.kind + " · " + resource.name) {
                    Text(resource.source).font(.caption).foregroundStyle(.secondary)
#if !os(tvOS)
                        .textSelection(.enabled)
#endif
                    if let activity = model.resourceActivity[resource.id] {
                        if let date = activity.attemptedAt { LabeledContent("Last Attempt") { Text(date, style: .relative) } }
                        if let date = activity.succeededAt { LabeledContent("Last Successful Update") { Text(date, style: .relative) } }
                        if activity.awaitingReview { Label("Downloaded · Awaiting Review", systemImage: "doc.text.magnifyingglass") }
                        if let version = activity.version { LabeledContent("Applied Version", value: String(version.prefix(8))) }
                        if let error = activity.error { Text(error).font(.caption).foregroundStyle(.red) }
                    } else { Text("No update recorded yet").foregroundStyle(.secondary) }
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
