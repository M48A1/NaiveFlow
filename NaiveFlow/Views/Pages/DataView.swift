//
//  DataView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/21/26.
//

import SwiftUI

struct DataView: View {
    @Environment(AppSettings.self) private var appSettings
    @Environment(Operations.self) private var operations
    @Environment(SubscriptionStore.self) private var subscriptionStore

    @State private var isUpdating = false
    @State private var updateSucceeded = false
    @State private var updateError: String?

    var body: some View {
        NavigationStack {
            @Bindable var appSettings = appSettings
            Form {
                Section {
                    Toggle(isOn: $appSettings.iCloudSyncEnabled) {
                        TextWithColorfulIcon(title: "iCloud Sync", systemName: "icloud.fill", foregroundStyle: .blue, backgroundStyle: .white.gradient)
                    }
                }
                
                Section {
                    Button {
                        updateAllSubscriptions()
                    } label: {
                        HStack {
                            Label("Update All Subscriptions", systemImage: updateSucceeded ? "checkmark" : "arrow.clockwise")
                                .contentTransition(.symbolEffect(.replace))
                            if isUpdating {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isUpdating || subscriptionStore.subscriptions.isEmpty)
                } footer: {
                    Text("Re-fetches every proxy subscription.")
                }
            }
            .navigationTitle("Data")
            .alert("Update Failed", isPresented: Binding(
                get: { updateError != nil },
                set: { if !$0 { updateError = nil } }
            )) {
                Button("OK") { updateError = nil }
            } message: {
                Text(updateError ?? "")
            }
        }
    }

    private func updateAllSubscriptions() {
        guard !isUpdating else { return }
        let items = subscriptionStore.subscriptions
        guard !items.isEmpty else { return }
        isUpdating = true
        Task {
            var failures: [String] = []
            await withTaskGroup(of: String?.self) { group in
                for item in items {
                    let name = item.name
                    group.addTask {
                        do {
                            try await operations.subscriptions.refresh(item)
                            return nil
                        } catch {
                            return "\(name): \(error.localizedDescription)"
                        }
                    }
                }
                for await failure in group {
                    if let failure {
                        failures.append(failure)
                    }
                }
            }
            isUpdating = false
            if failures.isEmpty {
                updateSucceeded = true
                try? await Task.sleep(for: .seconds(2))
                updateSucceeded = false
            } else {
                updateError = failures.joined(separator: "\n")
            }
        }
    }
}
