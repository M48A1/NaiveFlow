import SwiftUI
import UniformTypeIdentifiers
import NetworkExtension

struct ClientConfigurationStatusView: View {
    @Environment(ClientModel.self) private var model
    @Environment(TunnelController.self) private var tunnel
    @State private var reviewing = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                Label(status, systemImage: model.hasSavedDraft ? "doc.badge.ellipsis" : "checkmark.shield")
                    .font(.caption.weight(.medium)).foregroundStyle(model.hasSavedDraft ? .orange : .secondary)
                if model.hasSavedDraft {
                    Button("Review Saved Changes") { reviewing = true }.font(.caption)
                }
            }
        }
        .sheet(isPresented: $reviewing) { ClientDraftReviewView() }
    }
    private var status: String {
        if model.hasSavedDraft { return "Saved changes · Not applied" }
        if !model.hasApplied { return "Saved · Not applied" }
        if tunnel.rawStatus == .connecting || tunnel.rawStatus == .reasserting { return "Connecting · Waiting for tunnel confirmation" }
        if tunnel.rawStatus == .connected { return model.isRuntimeConfirmed ? "Running · Configuration confirmed" : "Waiting for tunnel confirmation" }
        return "Applied · VPN stopped"
    }
}

struct ClientDraftReviewView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var restore = false
    private var changes: [ClientTextChange] { ClientTextChange.compare(model.operatingText, model.profile?.text ?? "") }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Apply Saved Profile") { Task { if let profile = model.profile, await model.saveProfile(profile, apply: true) { dismiss() } } }
                    Button("Restore Applied Content", role: .destructive) { restore = true }
                } footer: { Text("Restoring replaces the saved draft with the currently applied text. It does not change the VPN.") }
                Section {
                    if changes.isEmpty { Text("No text changes") }
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Line \(change.line)").font(.caption).foregroundStyle(.secondary)
                            if let before = change.before { Text("− " + before).foregroundStyle(.red) }
                            if let after = change.after { Text("+ " + after).foregroundStyle(.green) }
                        }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                } header: { Text("Changed Lines") } footer: { Text("Compares the same line numbers in each version. Up to 400 changed lines are shown; inserting a line can shift later comparisons.") }
            }
            .navigationTitle("Saved vs Applied").clientInlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Replace Saved Draft?", isPresented: $restore, titleVisibility: .visible) {
                Button("Restore Applied Content", role: .destructive) { Task { if await model.restoreRunningDraft() { dismiss() } } }
            }
            .disabled(model.isBusy)
            .alert("Could Not Apply", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

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
            .navigationTitle("Review Subscription Update").clientInlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.discardSubscriptionReview(); dismiss() } } }
            .disabled(model.isBusy)
            .interactiveDismissDisabled(model.isBusy)
            .alert("Could Not Apply Update", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
    private func names(_ title: String, _ values: [String]) -> some View {
        Section("\(title) (\(values.count))") {
            if values.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(Array(values.enumerated()), id: \.offset) { _, name in Text(name) }
        }
    }
}

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
                    Text(resource.source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
        }.navigationTitle("Resource Updates").clientInlineTitle()
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

private struct ClientBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ClientBackupView: View {
    @Environment(ClientModel.self) private var model
    @State private var exporting = false
    @State private var importing = false
    @State private var document = ClientBackupDocument(data: Data())
    @State private var incoming: ClientBackup?
    @State private var replaceMatches = false
    @State private var notice: String?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Button("Export Complete Profile Backup") {
                    do {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        let data = try encoder.encode(ClientBackup(library: model.library))
                        guard data.count <= ClientBackup.maximumBytes else { throw ClientFailure("The backup exceeds 64 MiB.") }
                        document = ClientBackupDocument(data: data); exporting = true
                    } catch { self.error = error.localizedDescription }
                }
                Button("Import Backup") { importing = true }
            } footer: { Text("Includes all named profiles, subscription sources, modules and group styles. Backups contain node credentials and subscription URLs; keep them private. System VPN permissions and CA private keys are not included.") }
            if let incoming {
                Section {
                    LabeledContent("Profiles in Backup", value: String(incoming.library.profiles.count))
                    LabeledContent("Matching Profile IDs", value: String(incoming.library.profiles.filter { source in model.library.profiles.contains { $0.id == source.id } }.count))
                    Toggle("Replace Matching Profiles", isOn: $replaceMatches)
                    ForEach(incoming.library.profiles) { profile in Text(profile.displayName) }
                    Button("Restore Profiles") { Task {
                        if await model.restoreBackup(incoming, replaceMatches: replaceMatches) {
                            self.incoming = nil; notice = "Restored. The running VPN was not changed. Apply a profile when ready."
                        } else { error = model.error; model.error = nil }
                    } }
                    Button("Cancel Restore", role: .cancel) { self.incoming = nil }
                } header: { Text("Restore Preview") } footer: { Text("Matching IDs are kept unless replacement is enabled. Newly restored profiles are added. Nothing is applied to the VPN automatically.") }
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        .navigationTitle("Backup and Restore").clientInlineTitle()
        .disabled(model.isBusy)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "NaiveFlow-backup") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                let data = try file.read(upToCount: ClientBackup.maximumBytes + 1) ?? Data()
                incoming = try ClientBackup.decode(data); replaceMatches = false; notice = nil
            } catch { self.error = error.localizedDescription }
        }
        .alert("Backup Operation Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}

struct ClientRuleTestView: View {
    @Environment(ClientModel.self) private var model
    @State private var host = ""
    @State private var ip = ""
    @State private var port = "443"
    @State private var sourceIP = ""
    @State private var sourcePort = ""
    @State private var network = "TCP"
    @State private var resolve = false
    @State private var testing = false
    @State private var result: String?
    var body: some View {
        Form {
            Section("Target") {
                TextField("Domain (optional with IPv4)", text: $host)
                TextField("Resolved IPv4 (optional)", text: $ip).clientKeyboardType(.numbersAndPunctuation)
                TextField("Destination Port", text: $port).clientKeyboardType(.numberPad)
                Picker("Protocol", selection: $network) { Text("TCP").tag("TCP"); Text("UDP").tag("UDP") }
                Toggle("Resolve Domain if Needed", isOn: $resolve)
            }
            Section("Source (Optional)") {
                TextField("Source IPv4", text: $sourceIP)
                TextField("Source Port", text: $sourcePort).clientKeyboardType(.numberPad)
            }
            Section {
                Button("Test Applied Rules") { Task { await test() } }.disabled(testing || (host.isEmpty && ip.isEmpty))
                if testing { ProgressView() }
                if let result { Text(result).textSelection(.enabled) }
            } footer: { Text("Uses the applied version, including its pinned rule sets and Geo data. Does not send target traffic. DNS runs only when enabled and required; missing source metadata may prevent a decision. Automatic groups choose a member at connection time.") }
        }
        .clientNoAutocapitalization().autocorrectionDisabled().clientKeyboardDone()
        .navigationTitle("Rule Test").clientInlineTitle()
    }
    private func test() async {
        testing = true; defer { testing = false }
        do {
            guard let destinationPort = UInt16(port), destinationPort > 0,
                  ip.isEmpty || !ip.contains("/") && CIDRPrefix.parse(ip)?.prefixLength == 32,
                  sourceIP.isEmpty || !sourceIP.contains("/") && CIDRPrefix.parse(sourceIP)?.prefixLength == 32,
                  sourcePort.isEmpty || UInt16(sourcePort).map({ $0 > 0 }) == true else { throw ClientFailure("Enter valid IPv4 addresses and ports between 1 and 65535.") }
            let store = RuntimeBundleStore(directory: model.document.activation.store.directory.appendingPathComponent("runtime-v2"))
            guard let head = try store.head() else { throw ClientFailure("Apply a profile before testing rules.") }
            let bundle = try store.load(head.current)
            let matcher = OrderedRouteMatcher(rules: bundle.rules, finalAction: bundle.finalAction, geoIP: bundle.geo, geoSite: bundle.geo)
            var query = RouteQuery(host: host.isEmpty ? nil : host.lowercased(), ip: ip.isEmpty ? nil : ip,
                sourceIP: sourceIP.isEmpty ? nil : sourceIP, sourcePort: UInt16(sourcePort), destinationPort: destinationPort, protocolName: network)
            var evaluation = matcher.evaluate(query, deferOnHostUnknown: false)
            if case .needsAddress = evaluation, resolve, let host = query.host {
                guard let address = await DNSResolver.localRequests.resolveForRuleEvaluation(host) else { throw ClientFailure("DNS resolution failed. No route decision was made.") }
                query.ip = address; evaluation = matcher.evaluate(query, deferOnHostUnknown: false)
            }
            switch evaluation {
            case .needsAddress: result = "DNS is required before a rule can be selected. Enter an IPv4 address or enable resolution."
            case .deferred: result = "More flow metadata is required. Enter the source address and port to continue."
            case .matched(let match):
                let target: String
                switch match.action {
                case .direct: target = "DIRECT"
                case .reject: target = "REJECT"
                case .defaultProxy: target = "PROXY · " + (bundle.selectedNode?.name ?? "Unknown")
                case .proxy(let id): target = bundle.nodes.first { $0.id == id }?.name ?? "Unknown node"
                }
                result = "Version: \(bundle.snapshotID.uuidString.prefix(8))\nRule: \(match.ruleLine.map { "Line \($0)" } ?? "FINAL")\nOutbound: \(target)\nIPv4: \(query.ip ?? "Not resolved")"
            }
        } catch { result = error.localizedDescription }
    }
}
