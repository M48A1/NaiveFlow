import SwiftUI

struct ClientSubscriptionReviewView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let review: ClientSubscriptionReview
    @State private var removeMissing = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Apply Update") { Task { if await model.applySubscriptionReview(review, removeMissing: removeMissing) { dismiss() } } }
                    if !review.removable.isEmpty { Toggle("Remove Missing Unedited Nodes", isOn: $removeMissing) }
                } footer: { Text("Nothing changes until you apply. Missing nodes are kept by default. Nodes referenced by rules or proxy chains cannot be removed.") }
                names("New Nodes", review.added)
                names("Changed Nodes", review.modified)
                names("Missing from Subscription", review.missing)
                names("Manual Edits Preserved", review.preserved)
            }
            .navigationTitle("Review Subscription Update")
#if !os(tvOS)
            .clientInlineTitle()
#endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.discardSubscriptionReview(); dismiss() } } }
            .disabled(model.isBusy)
#if !os(tvOS)
            .interactiveDismissDisabled(model.isBusy)
#endif
            .alert("Could Not Apply Update", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
    private func names(_ title: String, _ values: [String]) -> some View {
        Section("\(title) (\(values.count))") {
            if values.isEmpty { Text("None").foregroundStyle(DesignSystem.Colors.secondaryText) }
            ForEach(Array(values.enumerated()), id: \.offset) { _, name in Text(name) }
        }
    }
}
