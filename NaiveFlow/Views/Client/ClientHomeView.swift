import SwiftUI
import NetworkExtension
import UniformTypeIdentifiers

struct ClientHomeView: View {
    @Environment(ClientModel.self) private var model
    @Environment(TunnelController.self) private var tunnel
    @Environment(ConnectionStats.self) private var stats
    @Environment(LatencyCenter.self) private var latency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var configurationsExpanded = false
    @State private var modeExpanded = false
    @State private var proxiesExpanded = false
    @State private var rulesExpanded = false
    @State private var editor: ClientProfile?
    @State private var showURL = false
    @State private var remoteURL = ""
    @State private var importingFile = false
    @State private var pendingDelete: ClientProfile?
    @State private var autoChoosing = false
    @State private var showNodeEditor = false
    @State private var nodeToEdit: ProxyConfiguration?

    private var connected: Bool { tunnel.rawStatus == .connected }
    private var canToggle: Bool { tunnel.isManagerReady && !tunnel.rawStatus.isTransitioning && (connected || model.hasApplied) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                runningCard
                configurationCard
                modeCard
                proxyCard
                rulesCard
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editor) { ClientProfileEditorView(profile: $0) }
        .sheet(isPresented: $showNodeEditor) {
            ProxyEditorView(configuration: nodeToEdit) { node in Task { await model.saveNode(node, replacing: nodeToEdit?.name) } }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let text = try model.operations.configurationDocument.read(contentsOf: url)
                editor = model.createProfile(name: url.deletingPathExtension().lastPathComponent, text: text)
            } catch { model.report(error) }
        }
        .alert("Import Profile from URL", isPresented: $showURL) {
            TextField("https://example.com/config.conf", text: $remoteURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Import") { Task {
                do {
                    let text = try await model.fetchText(remoteURL)
                    editor = model.createProfile(name: URL(string: remoteURL)?.deletingPathExtension().lastPathComponent ?? "Remote Profile", text: text, sourceURL: remoteURL)
                } catch { model.report(error) }
            } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete Profile?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let pendingDelete { model.deleteProfile(pendingDelete.id) }; pendingDelete = nil }
        }
        .onChange(of: latency.latencyResults) { _, results in
            guard autoChoosing else { return }
            let targets = model.nodes
            guard !targets.contains(where: { results[$0.id] == .testing }) else { return }
            autoChoosing = false
            let fastest = targets.compactMap { node -> (String, Int)? in
                if case .success(let ms) = results[node.id] { return (node.name, ms) }; return nil
            }.min { $0.1 < $1.1 }
            if let fastest { Task { await model.selectNode(fastest.0) } }
            else { model.error = "No latency results are available. Check your connection and try again." }
        }
        .alert("VPN Error", isPresented: Binding(get: { tunnel.startError != nil }, set: { if !$0 { tunnel.startError = nil } })) {
            Button("OK") { tunnel.startError = nil }
        } message: { Text(tunnel.startError ?? "") }
    }

    private var configurationCard: some View {
        ClientHomeCard(colors: [Color(red: 0.43, green: 0.28, blue: 0.77), Color(red: 0.64, green: 0.39, blue: 0.87)]) {
            cardHeader("Profiles", symbol: "doc.text.fill", summary: model.activeName, expanded: $configurationsExpanded)
            if configurationsExpanded {
            ForEach(model.library.profiles) { profile in
                HStack(spacing: 10) {
                    Button { Task { await model.activate(profile) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.displayName).font(.body.weight(.medium))
                                Text("Last updated: \(profile.updatedAt.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "en"))))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if model.library.selectedID == profile.id { Image(systemName: "checkmark").font(.title3.weight(.semibold)) }
                        }.frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.isBusy)
                    Menu {
                        Button("Edit / Rename", systemImage: "pencil") { editor = profile }
                        if profile.sourceURL != nil { Button("Update Remote Profile", systemImage: "arrow.clockwise") { Task { await model.updateProfile(profile) } } }
                        Button("DuplicateProfile", systemImage: "doc.on.doc") { editor = model.createProfile(name: profile.name + " Copy", text: profile.text) }
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = profile }
                            .disabled(profile.id == model.library.selectedID)
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(model.library.selectedID == profile.id ? Color.primary.opacity(0.045) : .clear)
            }
            HStack(spacing: 8) { configurationActions }
                .buttonStyle(ClientHomeActionStyle()).padding(16)
            }
        }
    }

    @ViewBuilder private var configurationActions: some View {
        Button("New") { editor = model.createProfile() }.frame(maxWidth: .infinity)
        Menu {
            Button("Import from URL", systemImage: "link") { showURL = true }
            Button("Import from File", systemImage: "folder") { importingFile = true }
        } label: { Text("Import").frame(maxWidth: .infinity).frame(minHeight: 44).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
        NavigationLink("Manage") { ClientProfilesView().toolbar(.visible, for: .navigationBar) }.frame(maxWidth: .infinity)
    }

    private var runningCard: some View {
        ClientHomeCard(colors: [Color(red: 0.06, green: 0.47, blue: 0.43), Color(red: 0.13, green: 0.65, blue: 0.51)]) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    if tunnel.rawStatus.isTransitioning { ProgressView() }
                    else { Image(systemName: connected ? "power.circle.fill" : "power.circle").font(.title2) }
                    Text("NaiveFlow")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(connected ? Color.green : Color.red)
                        .accessibilityValue(connected ? "Connected" : tunnel.rawStatus.isTransitioning ? "Connecting" : "Disconnected")
                    Spacer()
                    Toggle("Proxy Connection", isOn: Binding(get: { connected }, set: { _ in model.operations.tunnel.toggle() }))
                        .labelsHidden().tint(.teal).disabled(!canToggle || model.isBusy)
                }
                HStack(spacing: 30) {
                    traffic(symbol: "arrow.up", total: stats.bytesOut, rate: stats.uploadBytesPerSecond)
                    traffic(symbol: "arrow.down", total: stats.bytesIn, rate: stats.downloadBytesPerSecond)
                }
                if !model.hasApplied { Text("Select and apply a profile to connect.").font(.caption).foregroundStyle(.secondary) }
            }.padding(20)
        }
    }

    private func traffic(symbol: String, total: Int64, rate: Int64?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.body.weight(.medium))
            VStack(alignment: .leading, spacing: 4) {
                Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)).font(.subheadline.weight(.medium))
                if connected, let rate { Text(ByteCountFormatter.string(fromByteCount: rate, countStyle: .binary) + "/s").font(.caption) }
            }.monospacedDigit()
        }.foregroundStyle(.secondary)
    }

    private var modeCard: some View {
        ClientHomeCard(colors: [Color(red: 0.25, green: 0.31, blue: 0.81), Color(red: 0.20, green: 0.56, blue: 0.88)]) {
            cardHeader("Outbound Mode", symbol: "arrow.triangle.branch", summary: modeTitle(model.mode), expanded: $modeExpanded)
            if modeExpanded {
            ForEach([ProxyMode.direct, .global, .rule], id: \.rawValue) { mode in
                Button { Task { await model.setSetting("proxy-mode", value: mode.rawValue) } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark").font(.title3.weight(.semibold))
                            .opacity(model.mode == mode ? 1 : 0).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(modeTitle(mode)).font(.body.weight(model.mode == mode ? .semibold : .regular))
                            if model.mode == mode {
                                Text(mode == .rule ? "Use routing rules to handle requests." : mode == .global ? "Route all requests through the proxy." : "Connect all requests directly.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 20).padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.mode == mode ? Color.blue.opacity(0.09) : .clear).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.isBusy)
                    .accessibilityAddTraits(model.mode == mode ? [.isSelected] : [])
            }
            }
        }
    }
    private func modeTitle(_ mode: ProxyMode) -> String { mode == .rule ? "Rule" : mode == .global ? "Global Proxy" : "Direct" }

    private var proxyCard: some View {
        ClientHomeCard(colors: [Color(red: 0.70, green: 0.31, blue: 0.11), Color(red: 0.85, green: 0.48, blue: 0.18)]) {
            cardHeader("PROXY", symbol: "paperplane.fill", summary: "\(model.selectedNodeName) · Nodes: \(model.nodes.count)", expanded: $proxiesExpanded)
            if proxiesExpanded {
            if model.nodes.isEmpty {
                VStack(spacing: 8) {
                    Text("No Nodes Yet").font(.subheadline.weight(.medium))
                    Text("Add a node or import a profile containing nodes.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(20)
            } else {
                ForEach(model.nodes) { node in
                    Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5).padding(.horizontal, 20)
                    ClientNodeRow(node: node, selected: model.selectedNodeName == node.name, latency: latency.latencyResults[node.id]) {
                        Task { await model.selectNode(node.name) }
                    }.disabled(model.isBusy)
                    .background(model.selectedNodeName == node.name ? Color.primary.opacity(0.045) : .clear)
                    .contextMenu { Button("Edit Node", systemImage: "pencil") { nodeToEdit = node; showNodeEditor = true } }
                }
            }
            HStack(spacing: 8) { proxyActions }
                .buttonStyle(ClientHomeActionStyle()).padding(16)
            }
        }
    }

    @ViewBuilder private var proxyActions: some View {
        Menu {
            Button("Latency Test", systemImage: "bolt.fill") { latency.testLatencies(for: model.nodes, transport: tunnel) }
                .disabled(model.nodes.isEmpty)
            Button("Test and Auto Select", systemImage: "shuffle") { autoChoosing = true; latency.testLatencies(for: model.nodes, transport: tunnel) }
                .disabled(model.nodes.isEmpty || autoChoosing)
        } label: { Text(autoChoosing ? "Testing…" : "Test").frame(maxWidth: .infinity).frame(minHeight: 44).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)) }
        NavigationLink("Manage Nodes") { ClientNodesView().toolbar(.visible, for: .navigationBar) }.frame(maxWidth: .infinity)
    }
    private var ruleSetCount: Int { model.parsed.rules.filter { $0.kind == .ruleSet }.count }
    private var localRuleCount: Int { model.parsed.rules.filter { $0.kind != .ruleSet }.count }

    private var rulesCard: some View {
        ClientHomeCard(colors: [Color(red: 0.60, green: 0.30, blue: 0.48), Color(red: 0.79, green: 0.46, blue: 0.56)]) {
            cardHeader("Routing Rules", symbol: "line.3.horizontal.decrease.circle", summary: "RuleSet · \(ruleSetCount)   Local · \(localRuleCount)", expanded: $rulesExpanded)
            if rulesExpanded {
                HStack(spacing: 12) {
                    ruleTile("RuleSet", symbol: "square.stack.3d.up", count: ruleSetCount, color: .indigo, ruleSets: true)
                    ruleTile("Local", symbol: "doc.text", count: localRuleCount, color: .teal, ruleSets: false)
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }

    private func ruleTile(_ title: String, symbol: String, count: Int, color: Color, ruleSets: Bool) -> some View {
        NavigationLink { ClientRoutingRulesView(ruleSets: ruleSets).toolbar(.visible, for: .navigationBar) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(color)
                Text(title).font(.headline)
                Text("\(ruleSets ? "Rule sets" : "Local rules"): \(count)").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

    private func toggleDetails(_ expanded: Binding<Bool>) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            expanded.wrappedValue.toggle()
        }
    }

    private func cardHeader(_ title: String, symbol: String, summary: String, expanded: Binding<Bool>) -> some View {
        Button { toggleDetails(expanded) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.title3.weight(.semibold))
                    if !expanded.wrappedValue { Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if title == "Profiles", model.isBusy { ProgressView() }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            .accessibilityHint("Tap to expand or collapse details.")
    }
}

private struct ClientHomeCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var colors: [Color]
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .foregroundStyle(.primary).tint(.primary)
            .background {
                GeometryReader { geometry in
                    ZStack {
                        Color(uiColor: .secondarySystemGroupedBackground)
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            .opacity(colorScheme == .dark ? 0.18 : 0.12)
                        Rectangle().fill(.white.opacity(0.10))
                            .frame(width: geometry.size.width * 1.5, height: geometry.size.height * 0.5)
                            .rotationEffect(.degrees(-30)).offset(x: geometry.size.width * 0.12, y: -geometry.size.height * 0.3)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct ClientHomeActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium))
            .lineLimit(1).frame(maxWidth: .infinity).frame(minHeight: 44)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.primary)
    }
}

private struct ClientRoutingRulesView: View {
    @Environment(ClientModel.self) private var model
    let ruleSets: Bool
    @State private var editing = false
    @State private var ruleEditor: ClientRuleSetDraft?

    private var rules: [ParsedRule] {
        model.parsed.rules.filter { ($0.kind == .ruleSet) == ruleSets }
    }

    var body: some View {
        List {
            Section {
                if rules.isEmpty {
                    ContentUnavailableView(ruleSets ? "No Rule Sets" : "No Local Rules", systemImage: ruleSets ? "square.stack.3d.up" : "doc.text", description: Text(ruleSets ? "Tap + to add a rule set and choose its policy." : "Add routing rules to the current profile."))
                } else {
                    ForEach(rules) { rule in
                        Button {
                            if ruleSets { ruleEditor = ClientRuleSetDraft(rule: rule) }
                        } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(rule.kind.token).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Text(rule.policy.token).font(.caption.weight(.medium)).foregroundStyle(.blue)
                            }
                            Text(rule.value ?? "Final Match").font(.subheadline).textSelection(.enabled)
                            if !rule.options.isEmpty {
                                Text(rule.options.map(\.token).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!ruleSets)
                    }
                }
            } header: {
                Text("\(ruleSets ? "Rule sets" : "Local rules"): \(rules.count)")
            } footer: {
                Text(ruleSets ? "Rule set references and their policies. Contents are loaded when the profile is applied." : "Shown in matching order, including the final rule.")
            }
        }
        .navigationTitle(ruleSets ? "RuleSet" : "Local")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if ruleSets {
                    Button { ruleEditor = ClientRuleSetDraft() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New RuleSet")
                        .disabled(model.profile == nil || model.isBusy)
                } else {
                    Button { editing = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add Local Rule")
                        .disabled(model.profile == nil || model.isBusy)
                }
            }
        }
        .sheet(isPresented: $editing) { ClientActiveProfileEditor() }
        .sheet(item: $ruleEditor) { draft in
            ClientRuleSetEditorView(draft: draft)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct ClientRuleSetDraft: Identifiable {
    let id = UUID()
    var original: ParsedRule?
    var source = ""
    var policy = "PROXY"
    var noResolve = false

    init(rule: ParsedRule? = nil) {
        original = rule
        if let rule {
            source = rule.value ?? ""
            policy = rule.policy.token
            noResolve = rule.hasOption(.noResolve)
        }
    }
}

private struct ClientRuleSetEditorView: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: ClientRuleSetDraft
    @State private var saving = false
    @State private var error: String?

    private var policies: [String] {
        var names = ["PROXY", "DIRECT", "REJECT"]
        for group in model.groups where !names.contains(group.name) { names.append(group.name) }
        if !names.contains(draft.policy) { names.append(draft.policy) }
        return names
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rule Set URL") {
                    TextField("https://example.com/rules.list", text: $draft.source)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Rule Set URL")
                }
                Section {
                    Picker("Policy", selection: $draft.policy) {
                        ForEach(policies, id: \.self) { policy in Text(policy).tag(policy) }
                    }
                    Toggle("No Resolve", isOn: $draft.noResolve)
                } footer: {
                    Text("Choose a group, DIRECT, or REJECT. Saving downloads and validates the rule set before applying it to the current profile.")
                }
            }
            .navigationTitle(draft.original == nil ? "New RuleSet" : "Edit RuleSet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("Save") }
                    }.disabled(saving || model.isBusy || draft.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
            .alert("Could Not Save Rule Set", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    @MainActor private func save() async {
        saving = true
        defer { saving = false }
        do {
            let text = try ClientDocumentEditing.saveRuleSet(model.operatingText, original: draft.original,
                source: draft.source, policy: draft.policy, noResolve: draft.noResolve)
            if await model.commit(text) { dismiss() }
            else {
                error = model.error ?? "Could not save. Try again later."
                model.error = nil
            }
        } catch { self.error = error.localizedDescription }
    }
}
