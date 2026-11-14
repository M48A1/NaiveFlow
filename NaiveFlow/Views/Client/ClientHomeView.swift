import SwiftUI

struct ClientHomeView: View {
    @Environment(ClientModel.self) private var model
    @Environment(TunnelController.self) private var tunnel
    @Environment(LatencyCenter.self) private var latency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var configurationsExpanded = false
    @State private var modeExpanded = false
    @State private var proxiesExpanded = false
    @State private var rulesExpanded = false
    @State private var editor: ClientProfile?
    @State private var pendingDelete: ClientProfile?
    @State private var autoChoosing = false
    @State private var showNodeEditor = false
    @State private var nodeToEdit: ProxyConfiguration?

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.regular) {
                modeCard
                configurationCard
                proxyCard
                rulesCard
            }
            .clientMainContent()
        }
        .background(ClientAppearance.background)
        .clientNavigationBar(visible: false)
        .sheet(item: $editor) { ClientProfileEditorView(profile: $0).clientEditorWindow() }
        .sheet(isPresented: $showNodeEditor) {
            ProxyEditorView(configuration: nodeToEdit) { node in Task { await model.saveNode(node, replacing: nodeToEdit?.name) } }
        }
        .confirmationDialog("Delete Profile?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let pendingDelete { model.deleteProfile(pendingDelete.id) }; pendingDelete = nil }
        }
        .onChange(of: latency.latencyResults) { _, results in
            guard autoChoosing else { return }
            let targets = model.nodes
            guard !targets.contains(where: { results[$0.id] == .testing }) else { return }
            autoChoosing = false
            Task { await model.selectFastestNode(from: results, testedIDs: Set(targets.map(\.id))) }
        }
        .alert("VPN Error", isPresented: Binding(get: { tunnel.startError != nil }, set: { if !$0 { tunnel.startError = nil } })) {
            Button("OK") { tunnel.startError = nil }
        } message: { Text(tunnel.startError ?? "") }
    }

    private var configurationCard: some View {
        ClientHomeCard(colors: DesignSystem.CardTheme.profiles.colors) {
            cardHeader("Profiles", symbol: "doc.text.fill", iconColor: DesignSystem.CardTheme.profiles.tint, summary: model.activeName, expanded: $configurationsExpanded, menu: .profiles)
            if configurationsExpanded {
            ForEach(model.library.profiles) { profile in
                HStack(spacing: 10) {
                    Button { Task { await model.activate(profile) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.displayName).designText(.body, weight: .medium)
                                Text("Last updated: \(profile.updatedAt.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "en"))))")
                                    .designText(.caption).foregroundStyle(DesignSystem.Colors.secondaryText)
                            }
                            Spacer(minLength: 8)
                            if model.library.selectedID == profile.id { Image(systemName: "checkmark").designText(.cardTitle, weight: .semibold) }
                        }.frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.isBusy)
                    Menu {
                        Button("Edit / Rename", systemImage: "pencil") { editor = profile }
                        if profile.sourceURL != nil { Button("Update Remote Profile", systemImage: "arrow.clockwise") { Task { await model.updateProfile(profile) } } }
                        Button("DuplicateProfile", systemImage: "doc.on.doc") { editor = model.createProfile(name: profile.name + " Copy", text: profile.text) }
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = profile }
                            .disabled(profile.id == model.library.selectedID)
                    } label: { Image(systemName: "ellipsis").frame(width: DesignSystem.Interaction.minimumHitSize, height: DesignSystem.Interaction.minimumHitSize).contentShape(Rectangle()) }
                    .clientIconMenu()
                }
                .padding(.horizontal, DesignSystem.Card.padding).padding(.vertical, 8)
                .background(model.library.selectedID == profile.id ? Color.primary.opacity(0.045) : .clear)
            }
            }
        }
    }

    private var modeCard: some View {
        ClientHomeCard(colors: DesignSystem.CardTheme.outbound.colors) {
            cardHeader("Outbound Mode", symbol: "arrow.triangle.branch", iconColor: DesignSystem.CardTheme.outbound.tint, summary: modeTitle(model.mode), expanded: $modeExpanded, menu: .connection)
            if modeExpanded {
            ForEach([ProxyMode.direct, .global, .rule], id: \.rawValue) { mode in
                Button { Task { await model.setSetting("proxy-mode", value: mode.rawValue) } } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark").designText(.cardTitle, weight: .semibold)
                            .opacity(model.mode == mode ? 1 : 0).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(modeTitle(mode)).designText(.contentTitle, weight: model.mode == mode ? .semibold : .regular)
                            if model.mode == mode {
                                Text(mode == .rule ? "Use routing rules to handle requests." : mode == .global ? "Route all requests through the proxy." : "Connect all requests directly.")
                                    .designText(.caption).foregroundStyle(DesignSystem.Colors.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, DesignSystem.Card.padding).padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.mode == mode ? DesignSystem.Colors.accent.opacity(0.09) : .clear).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(model.isBusy)
                    .accessibilityAddTraits(model.mode == mode ? [.isSelected] : [])
            }
            }
        }
    }
    private func modeTitle(_ mode: ProxyMode) -> String { mode == .rule ? "Rule" : mode == .global ? "Global Proxy" : "Direct" }

    private var proxyCard: some View {
        ClientHomeCard(colors: DesignSystem.CardTheme.proxies.colors) {
            cardHeader("PROXY", symbol: "paperplane.fill", iconColor: DesignSystem.CardTheme.proxies.tint, summary: "\(model.selectedNodeName) · Nodes: \(model.nodes.count)", expanded: $proxiesExpanded, menu: .proxies)
            if proxiesExpanded {
            if model.nodes.isEmpty {
                VStack(spacing: 8) {
                    Text("No Nodes Yet").designText(.secondary, weight: .medium)
                    Text("Add a node or import a profile containing nodes.").designText(.caption).foregroundStyle(DesignSystem.Colors.secondaryText)
                }.frame(maxWidth: .infinity).padding(20)
            } else {
                ForEach(model.nodes) { node in
                    Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5).padding(.horizontal, DesignSystem.Card.padding)
                    ClientNodeRow(node: node, selected: model.selectedNodeName == node.name, latency: latency.latencyResults[node.id]) {
                        Task { await model.selectNode(node.name) }
                    }.disabled(model.isBusy)
                    .background(model.selectedNodeName == node.name ? Color.primary.opacity(0.045) : .clear)
                    .contextMenu { Button("Edit Node", systemImage: "pencil") { nodeToEdit = node; showNodeEditor = true } }
                }
            }
            }
        }
    }

    private var ruleSetCount: Int { model.parsed.rules.filter { $0.kind == .ruleSet }.count }
    private var localRuleCount: Int { model.parsed.rules.filter { $0.kind != .ruleSet }.count }

    private var rulesCard: some View {
        ClientHomeCard(colors: DesignSystem.CardTheme.rules.colors) {
            cardHeader("Routing Rules", symbol: "line.3.horizontal.decrease.circle", iconColor: DesignSystem.CardTheme.rules.tint, summary: "RuleSet · \(ruleSetCount)   Local · \(localRuleCount)", expanded: $rulesExpanded, menu: .rules)
            if rulesExpanded {
                let rules = model.parsed.rules
                if rules.isEmpty {
                    Text("No Routing Rules").designText(.secondary).foregroundStyle(DesignSystem.Colors.secondaryText).padding(20)
                } else {
                    ForEach(rules.prefix(5)) { rule in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(rule.kind.token).designText(.caption, weight: .semibold).foregroundStyle(DesignSystem.Colors.secondaryText)
                                Spacer()
                                Text(rule.policy.token).designText(.caption, weight: .medium).foregroundStyle(DesignSystem.Colors.accent)
                            }
                            Text(rule.value ?? "Final Match").designText(.secondary).lineLimit(2)
                        }.padding(.horizontal, DesignSystem.Card.padding).padding(.vertical, 12)
                    }
                    if rules.count > 5 {
                        Text("Showing 5 of \(rules.count) rules").designText(.caption).foregroundStyle(DesignSystem.Colors.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, DesignSystem.Card.padding).padding(.bottom, 16)
                    }
                }
            }
        }
    }

    private func toggleDetails(_ expanded: Binding<Bool>) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            expanded.wrappedValue.toggle()
        }
    }

    private enum CardMenu { case connection, profiles, proxies, rules }

    private func cardHeader(_ title: String, symbol: String, iconColor: Color, summary: String,
                            expanded: Binding<Bool>, menu: CardMenu? = nil) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Button { toggleDetails(expanded) } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol).designText(.cardTitle, weight: .semibold).frame(width: 28)
                        .foregroundStyle(iconColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).designText(.cardTitle, weight: .semibold)
                        if !expanded.wrappedValue { Text(summary).designText(.secondary).foregroundStyle(DesignSystem.Colors.secondaryText).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    if title == "Profiles", model.isBusy { ProgressView() }
                }
                .padding(.leading, DesignSystem.Card.padding).padding(.vertical, 20).padding(.trailing, menu == nil ? DesignSystem.Card.padding : 0)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
                .accessibilityHint("Tap to expand or collapse details.")
            if let menu {
                Menu {
                    switch menu {
                    case .connection:
                        ClientTunnelMenuActions()
                    case .profiles:
                        NavigationLink { ClientProfilesView().clientNavigationBar(visible: true) } label: {
                            Label("Manage Profiles", systemImage: "doc.text")
                        }
                    case .proxies:
                        NavigationLink { ClientNodesView().clientNavigationBar(visible: true) } label: {
                            Label("Manage Nodes", systemImage: "network")
                        }
                        Divider()
                        Button("Latency Test", systemImage: "bolt.fill") { latency.testLatencies(for: model.nodes, transport: tunnel) }
                            .disabled(model.nodes.isEmpty)
                        Button(autoChoosing ? "Testing…" : "Test and Auto Select", systemImage: "shuffle") {
                            autoChoosing = true; latency.testLatencies(for: model.nodes, transport: tunnel)
                        }.disabled(model.nodes.isEmpty || autoChoosing)
                    case .rules:
                        NavigationLink { ClientRoutingRulesView(ruleSets: true).clientNavigationBar(visible: true) } label: {
                            Label("Rule Sets", systemImage: "square.stack.3d.up")
                        }
                        NavigationLink { ClientRoutingRulesView(ruleSets: false).clientNavigationBar(visible: true) } label: {
                            Label("Local Rules", systemImage: "doc.text")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").designText(.body, weight: .semibold)
                        .frame(width: DesignSystem.Interaction.minimumHitSize, height: DesignSystem.Interaction.minimumHitSize).contentShape(Rectangle())
                }
                .clientIconMenu()
                .padding(.top, 12).padding(.trailing, 12)
                .accessibilityLabel("\(title) actions")
                .disabled(model.isBusy)
            }
        }
    }

}

private struct ClientHomeCard<Content: View>: View {
    var colors: [Color]
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .foregroundStyle(DesignSystem.Colors.text).tint(DesignSystem.Colors.text)
            .designCard(colors: colors)
    }
}

private struct ClientRoutingRulesView: View {
    @Environment(ClientModel.self) private var model
    let ruleSets: Bool
    @State private var editing = false
    @State private var ruleEditor: ClientRuleSetDraft?
    @State private var pendingDelete: ParsedRule?
    @State private var updating = false
    @State private var updateComplete = false

    private var rules: [ParsedRule] {
        model.parsed.rules.filter { ($0.kind == .ruleSet) == ruleSets }
    }

    var body: some View {
        List {
            Section {
                Button {
                    if ruleSets { ruleEditor = ClientRuleSetDraft() }
                    else { editing = true }
                } label: {
                    Label(ruleSets ? "New RuleSet" : "Add Local Rule", systemImage: "plus.circle")
                }.disabled(model.profile == nil || model.isBusy)
            }
            Section {
                if rules.isEmpty {
                    ContentUnavailableView(ruleSets ? "No Rule Sets" : "No Local Rules", systemImage: ruleSets ? "square.stack.3d.up" : "doc.text", description: Text(ruleSets ? "Add a rule set using the button above and choose its policy." : "Add routing rules to the current profile."))
                } else {
                    ForEach(rules) { rule in
                        Button {
                            if ruleSets { ruleEditor = ClientRuleSetDraft(rule: rule) }
                        } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(rule.kind.token).designText(.caption, weight: .semibold).foregroundStyle(DesignSystem.Colors.secondaryText)
                                Spacer()
                                Text(rule.policy.token).designText(.caption, weight: .medium).foregroundStyle(DesignSystem.Colors.accent)
                            }
                            Text(displayValue(rule)).designText(.secondary).textSelection(.enabled)
                            if !rule.options.isEmpty {
                                Text(rule.options.map(\.token).joined(separator: " · ")).designText(.caption).foregroundStyle(DesignSystem.Colors.secondaryText)
                            }
                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!ruleSets)
                        .clientSwipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if ruleSets {
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = rule }
                                Button("Edit", systemImage: "pencil") { ruleEditor = ClientRuleSetDraft(rule: rule) }.tint(DesignSystem.Colors.accent)
                                Button("Update", systemImage: "arrow.clockwise") { Task { await update(source: rule.value) } }.tint(.orange)
                            }
                        }
                    }
                }
            } header: {
                Text("\(ruleSets ? "Rule sets" : "Local rules"): \(rules.count)")
            } footer: {
                Text(ruleSets ? "Rule set references and their policies. Contents are loaded when the profile is applied." : "Shown in matching order, including the final rule.")
            }
        }
        .navigationTitle(ruleSets ? "RuleSet" : "Local")
        .clientInlineTitle()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if ruleSets {
                HStack {
                    Button { Task { await update() } } label: {
                        Label(updating ? "Updating…" : "Update All", systemImage: "arrow.clockwise")
                    }.buttonStyle(.bordered).labelStyle(.titleAndIcon)
                        .disabled(updating || model.isBusy || rules.isEmpty)
                    if updating { ProgressView() }
                    Spacer()
                }.padding(.horizontal, DesignSystem.Card.padding).padding(.vertical, 10).background(.bar)
            }
        }
        .sheet(isPresented: $editing) { ClientActiveProfileEditor() }
        .confirmationDialog("Delete RuleSet?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let pendingDelete { Task { _ = await model.manageResource(.delete(.ruleSet(pendingDelete))) } }; pendingDelete = nil }
        }
        .alert("Update Complete", isPresented: $updateComplete) { Button("OK", role: .cancel) {} }
        .sheet(item: $ruleEditor) { draft in
            ClientRuleSetEditorView(draft: draft)
                .clientSheetDetents()
                .clientSheetDragIndicator()
        }
        .disabled(updating || model.isBusy)
    }

    @MainActor private func update(source: String? = nil) async {
        guard !updating else { return }
        updating = true; defer { updating = false }
        updateComplete = await model.manageResource(.update(.ruleSets(sources: source.map { Set([$0]) })))
    }

    private func displayValue(_ rule: ParsedRule) -> String {
        let value = rule.value ?? "Final Match"
        if ruleSets, let url = URL(string: value), url.isFileURL { return url.lastPathComponent }
        return value
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
            ClientForm {
                Section("Rule Set URL") {
                    TextField("https://example.com/rules.list", text: $draft.source)
                        .clientKeyboardType(.URL).clientNoAutocapitalization().autocorrectionDisabled()
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
            .clientInlineTitle()
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
        if await model.manageResource(.save(.ruleSet(original: draft.original, source: draft.source,
            policy: draft.policy, noResolve: draft.noResolve))) { dismiss() }
        else {
            error = model.error ?? "Could not save. Try again later."
            model.error = nil
        }
    }
}
