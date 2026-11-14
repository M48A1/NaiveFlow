import SwiftUI

struct TVClientHomeView: View {
    @Environment(ClientModel.self) private var model
    let tunnel: TunnelController
    let latency: LatencyCenter

    private var ruleSetCount: Int { model.parsed.rules.filter { $0.kind == .ruleSet }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.television) {
                modeCard
                HStack(alignment: .top, spacing: 28) {
                    profilesCard
                    proxyCard
                    rulesCard
                }
            }
            .clientMainContent(maximumWidth: DesignSystem.Layout.televisionWidth)
        }
        .background(DesignSystem.Colors.background.ignoresSafeArea())
        .alert("VPN Error", isPresented: Binding(
            get: { tunnel.startError != nil },
            set: { if !$0 { tunnel.startError = nil } }
        )) {
            Button("OK") { tunnel.startError = nil }
        } message: { Text(tunnel.startError ?? "") }
    }

    private var modeCard: some View {
        TVHomeCard(color: DesignSystem.CardTheme.outbound.tint, height: 240) {
            HStack {
                heading("Outbound Mode", symbol: "arrow.triangle.branch", color: DesignSystem.CardTheme.outbound.tint)
                Spacer()
                Menu {
                    ClientTunnelMenuActions().environment(tunnel)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .buttonStyle(TVHomeButtonStyle(color: DesignSystem.CardTheme.outbound.tint))
                .frame(width: 64)
                .accessibilityLabel("Connection actions")
            }
            Text(model.mode == .rule ? "Use routing rules to handle requests." : model.mode == .global ? "Route all requests through the proxy." : "Connect all requests directly.")
                .designText(.body).foregroundStyle(DesignSystem.Colors.secondaryText).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                modeButton("Direct", mode: .direct)
                modeButton("Global Proxy", mode: .global)
                modeButton("Rule", mode: .rule)
            }
        }
    }

    private var profilesCard: some View {
        TVHomeCard(color: DesignSystem.CardTheme.profiles.tint, height: 410) {
            heading("Profiles", symbol: "doc.text.fill", color: DesignSystem.CardTheme.profiles.tint)
            Text(model.activeName).designText(.body, weight: .medium).lineLimit(1)
            Text(model.hasSavedDraft ? "Saved changes · Not applied" : model.hasApplied ? "Applied profile" : "Saved · Not applied")
                .designText(.caption).foregroundStyle(DesignSystem.Colors.secondaryText)
            ForEach(model.library.profiles.prefix(2)) { profile in
                Button { Task { await model.activate(profile) } } label: {
                    HStack {
                        Text(profile.displayName).lineLimit(1)
                        Spacer(minLength: 4)
                        if model.library.selectedID == profile.id && model.hasApplied {
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                }
                .buttonStyle(TVHomeButtonStyle(color: DesignSystem.CardTheme.profiles.tint))
                .disabled(model.isBusy)
                .accessibilityHint("Apply this profile")
            }
            Spacer(minLength: 0)
            NavigationLink { TVClientProfilesView() } label: {
                Label("Manage Profiles", systemImage: "doc.on.doc")
            }
            .buttonStyle(TVHomeButtonStyle(color: DesignSystem.CardTheme.profiles.tint))
        }
    }

    private var proxyCard: some View {
        TVHomeCard(color: DesignSystem.CardTheme.proxies.tint, height: 410) {
            heading("PROXY", symbol: "paperplane.fill", color: DesignSystem.CardTheme.proxies.tint)
            Text(model.selectedNodeName).designText(.body, weight: .medium).lineLimit(1)
            Text("Nodes: \(model.nodes.count)").designText(.caption).foregroundStyle(DesignSystem.Colors.secondaryText)
            if model.nodes.isEmpty {
                Text("Add a node or import a profile containing nodes.")
                    .designText(.body).foregroundStyle(DesignSystem.Colors.secondaryText)
            } else {
                ForEach(model.nodes.prefix(2)) { node in
                    Button { Task { await model.selectNode(node.name) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: model.selectedNodeName == node.name ? "checkmark.circle.fill" : "circle")
                            Text(node.name).lineLimit(1)
                            Spacer(minLength: 0)
                            if case .success(let ms) = latency.latencyResults[node.id] {
                                Text("\(ms) ms").designText(.caption).monospacedDigit()
                            }
                        }
                    }
                    .buttonStyle(TVHomeButtonStyle(color: DesignSystem.CardTheme.proxies.tint))
                    .disabled(model.isBusy)
                }
            }
            Spacer(minLength: 0)
            NavigationLink { TVClientNodesView(latency: latency, tunnel: tunnel) } label: {
                Label("Manage Nodes", systemImage: "network")
            }
            .buttonStyle(TVHomeButtonStyle(color: DesignSystem.CardTheme.proxies.tint))
        }
    }

    private var rulesCard: some View {
        TVHomeCard(color: DesignSystem.CardTheme.rules.tint, height: 410) {
            heading("Routing Rules", symbol: "line.3.horizontal.decrease.circle", color: DesignSystem.CardTheme.rules.tint)
            HStack(spacing: 20) {
                ruleCount("Rule Sets", count: ruleSetCount)
                ruleCount("Local Rules", count: model.parsed.rules.count - ruleSetCount)
            }
            .padding(.vertical, 4)
            ForEach(model.parsed.rules.prefix(2)) { rule in
                Text(rule.raw).designText(.code)
                    .foregroundStyle(DesignSystem.Colors.secondaryText).lineLimit(1)
            }
            if model.parsed.rules.isEmpty {
                Text("No routing rules in this profile.").designText(.body).foregroundStyle(DesignSystem.Colors.secondaryText)
            }
            Spacer(minLength: 0)
            NavigationLink { TVClientRulesView() } label: {
                Label("Manage Rules", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(TVHomeButtonStyle(color: DesignSystem.CardTheme.rules.tint))
        }
    }

    private func heading(_ title: String, symbol: String, color: Color) -> some View {
        Label { Text(title).foregroundStyle(DesignSystem.Colors.text) } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .designText(.cardTitle).lineLimit(1)
    }

    private func ruleCount(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(count)).designText(.value).monospacedDigit()
            Text(title).designText(.caption).foregroundStyle(DesignSystem.Colors.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeButton(_ title: LocalizedStringKey, mode: ProxyMode) -> some View {
        Button { Task { await model.setSetting("proxy-mode", value: mode.rawValue) } } label: {
            Label(title, systemImage: model.mode == mode ? "checkmark.circle.fill" : "circle")
                .lineLimit(1)
        }
        .buttonStyle(TVHomeButtonStyle(color: DesignSystem.CardTheme.outbound.tint, selected: model.mode == mode))
        .disabled(model.isBusy)
        .accessibilityAddTraits(model.mode == mode ? [.isSelected] : [])
    }
}

private struct TVHomeCard<Content: View>: View {
    let color: Color
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.regular) { content }
            .padding(DesignSystem.Card.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: height, alignment: .top)
            .designCard(colors: [color])
    }
}

private struct TVHomeButtonStyle: ButtonStyle {
    let color: Color
    var selected = false
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .designText(.button)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(focused ? Color.white : selected ? color : Color.primary)
            .background(focused ? color : color.opacity(selected ? 0.15 : 0.07), in: RoundedRectangle(cornerRadius: DesignSystem.Interaction.buttonRadius))
            .overlay { RoundedRectangle(cornerRadius: DesignSystem.Interaction.buttonRadius).stroke(focused ? color : .clear, lineWidth: DesignSystem.Interaction.focusOutline) }
            .scaleEffect(focused && !reduceMotion ? DesignSystem.Interaction.focusScale : 1)
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : DesignSystem.Interaction.disabledOpacity)
            .animation(reduceMotion ? nil : .easeOut(duration: DesignSystem.Interaction.focusDuration), value: focused)
    }
}

struct TVClientGroupsView: View {
    let latency: LatencyCenter
    let tunnel: TunnelController
    @Environment(ClientModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingDelete: ParsedProxyGroup?

    private var columnCount: Int { min(3, model.groups.count + 2) }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.television) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0, maximum: 520), spacing: 28), count: columnCount), spacing: 28) {
                    NavigationLink {
                        TVClientNodesView(latency: latency, tunnel: tunnel)
                    } label: {
                        ClientPolicyCard(name: "PROXY", selected: model.selectedNodeName,
                            style: ClientGroupStyle(symbol: "shippingbox", palette: 0))
                    }
                    .buttonStyle(.card)

                    ForEach(model.groups) { group in
                        NavigationLink {
                            TVClientGroupDetailView(name: group.name)
                        } label: {
                            ClientPolicyCard(name: group.name, selected: model.selectedMember(in: group),
                                style: model.profile?.groupStyles[group.name] ?? ClientGroupStyle(palette: ClientPalette.index(for: group.name)),
                                iconURL: group.parameters["icon-url"])
                        }
                        .buttonStyle(.card)
                        .contextMenu {
                            Button("Delete Group", role: .destructive) { pendingDelete = group }
                        }
                    }
                    NavigationLink { TVClientGroupEditor(group: nil) } label: {
                        ClientNewGroupCard()
                    }
                    .buttonStyle(.card)
                    .disabled(model.isBusy)
                }
                .frame(maxWidth: CGFloat(columnCount) * 520 + CGFloat(columnCount - 1) * 28)

                if model.groups.isEmpty {
                    Text("Group your nodes to choose an outbound for different traffic.")
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                }
            }
            .clientMainContent(maximumWidth: DesignSystem.Layout.televisionWidth)
        }
        .confirmationDialog("Delete Group?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { group in
            Button("Delete", role: .destructive) { Task { await model.deleteGroup(group.name) } }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.pollPolicyStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct TVClientGroupDetailView: View {
    @Environment(ClientModel.self) private var model
    let name: String

    var body: some View {
        List {
            if let original = model.groups.first(where: { $0.name == name }) {
                let group = model.resolvedGroup(original)
                NavigationLink("Edit Group") { TVClientGroupEditor(group: original) }
                    .disabled(model.isBusy)
                Section {
                    ForEach(group.members, id: \.self) { member in
                        if group.kind == .select {
                            Button {
                                Task { await model.selectMember(member, in: original) }
                            } label: {
                                Label(member, systemImage: model.selectedMember(in: original) == member ? "checkmark.circle.fill" : "circle")
                            }
                            .disabled(model.isBusy)
                        } else {
                            Text(member)
                        }
                    }
                } header: {
                    TVClientGroupLabel(name: model.selectedMember(in: original), iconURL: original.parameters["icon-url"])
                }
            }
        }
        .navigationTitle(name)
    }
}

private struct TVClientGroupEditor: View {
    @Environment(ClientModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: ParsedProxyGroup?
    @State private var name: String
    @State private var kind: String
    @State private var members: [String]
    @State private var iconURL: String

    init(group: ParsedProxyGroup?) {
        self.group = group
        _name = State(initialValue: group?.name ?? "")
        _kind = State(initialValue: group?.kindToken ?? "select")
        _members = State(initialValue: group?.members ?? [])
        _iconURL = State(initialValue: group?.parameters["icon-url"] ?? "")
    }

    var body: some View {
        List {
            Section("Group") {
                TextField("Group Name", text: $name)
                Picker("Type", selection: $kind) {
                    ForEach(kinds, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Group Icon") {
                TVClientGroupLabel(name: "Icon Preview", iconURL: normalizedIconURL)
                TextField("HTTPS Icon URL", text: $iconURL).autocorrectionDisabled()
                NavigationLink("Choose from Icon Pack") { TVClientGroupIconPacksView(iconURL: $iconURL) }
                if !normalizedIconURL.isEmpty {
                    Button("Use Default Icon") { iconURL = "" }
                }
                if !validIconURL {
                    Text("Enter a valid HTTPS icon URL.").foregroundStyle(DesignSystem.Colors.error)
                }
            }
            Section("Member Order") {
                ForEach(Array(members.enumerated()), id: \.offset) { index, member in
                    Menu(member) {
                        Button("Move Up") { members.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("Move Down") { members.swapAt(index, index + 1) }.disabled(index + 1 == members.count)
                        Button("Remove", role: .destructive) { members.remove(at: index) }
                    }
                }
            }
            Section("Add Members") {
                ForEach(candidates, id: \.self) { member in
                    Button(member) { members.append(member) }
                }
            }
            Button("Save and Apply") { Task { await save() } }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || members.isEmpty || !validIconURL)
        }
        .navigationTitle(group == nil ? "New Group" : "Edit Group")
        .disabled(model.isBusy)
    }

    private var normalizedIconURL: String {
        iconURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validIconURL: Bool {
        normalizedIconURL.isEmpty || ProxyGroupIconURL.parse(normalizedIconURL) != nil
    }

    private var kinds: [String] {
        let defaults = ["select", "url-test", "fallback", "load-balance"]
        guard let original = group?.kindToken, !defaults.contains(original) else { return defaults }
        return defaults + [original]
    }

    private var candidates: [String] {
        let available = model.nodes.map(\.name) + model.groups.map(\.name).filter { $0 != group?.name && $0 != name }
            + ["DIRECT", "REJECT", "PROXY"]
        var seen = Set(members)
        return available.filter { seen.insert($0).inserted }
    }

    private func save() async {
        let style = group.flatMap { model.profile?.groupStyles[$0.name] } ?? ClientGroupStyle()
        var parameters = (group?.parameters.pairs ?? []).filter { key, value in
            key.caseInsensitiveCompare("icon-url") != .orderedSame &&
                (key != "selected" || (kind == "select" && members.contains(value)))
        }
        if !normalizedIconURL.isEmpty { parameters.append(("icon-url", normalizedIconURL)) }
        if await model.saveGroup(original: group?.name, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 kind: kind, members: members, parameters: parameters, style: style) {
            dismiss()
        }
    }
}
