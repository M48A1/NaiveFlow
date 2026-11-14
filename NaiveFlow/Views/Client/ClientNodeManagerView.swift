import SwiftUI
import UniformTypeIdentifiers

struct ClientNodeManagerView: View {
    @Environment(ClientModel.self) private var model
    @Environment(LatencyCenter.self) private var latency
    @Environment(TunnelController.self) private var tunnel
    @State private var query = ""
    @State private var protocolName = ""
    @State private var subscriptionID = ""
    @State private var availability = ""
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var editingNode: ProxyConfiguration?
    @State private var editing = false
    @State private var importingFile = false
    @State private var importingLinks = false
    @State private var scanning = false
    @State private var deleting: Set<String> = []
    @State private var confirmDelete = false
    private var filtered: Bool { !query.isEmpty || !protocolName.isEmpty || !subscriptionID.isEmpty || !availability.isEmpty }
    private var visible: [ProxyConfiguration] {
        let names: Set<String>? = subscriptionID.isEmpty ? nil : Set(model.profile?.nodeSubscriptions?.first { $0.id.uuidString == subscriptionID }?.members.map(\.name) ?? [])
        return ClientNodeTools.filtered(model.nodes, query: query, protocolName: protocolName, subscriptionNames: names, availability: availability, results: latency.latencyResults)
    }
    var body: some View {
        List {
            Section {
                NavigationLink("Subscription Groups") { ClientNodeSubscriptionsView() }
                NavigationLink("Connection Diagnostics") { ClientDiagnosticsView() }
            }
            Section("Filters") {
                Picker("Protocol", selection: $protocolName) {
                    Text("All Protocols").tag("")
                    ForEach(OutboundProtocol.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                }
                Picker("Subscription", selection: $subscriptionID) {
                    Text("All Nodes").tag("")
                    ForEach(model.profile?.nodeSubscriptions ?? []) { Text($0.name).tag($0.id.uuidString) }
                }
                Picker("Availability", selection: $availability) {
                    Text("All Results").tag(""); Text("Available").tag("available"); Text("Failed / Certificate Error").tag("failed")
                    Text("Testing").tag("testing"); Text("Not Tested").tag("untested")
                }
                if filtered { Button("Clear Filters") { query = ""; protocolName = ""; subscriptionID = ""; availability = "" } }
            }
            Section {
                if visible.isEmpty { ContentUnavailableView("No Matching Nodes", systemImage: "network", description: Text("Change filters or use + to import nodes.")) }
                ForEach(visible) { node in
                    if selecting {
                        Button {
                            if !selected.insert(node.name).inserted { selected.remove(node.name) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(node.name) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) { Text(node.name).foregroundStyle(.primary); Text(node.outboundProtocol.name).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    } else {
                        ClientNodeRow(node: node, selected: model.selectedNodeName == node.name, latency: latency.latencyResults[node.id]) {
                            Task { await model.selectNode(node.name) }
                        }.listRowInsets(EdgeInsets())
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editingNode = node; editing = true }
                            Button("Test Latency", systemImage: "bolt") { latency.testLatency(for: node, transport: tunnel) }
                            if node.chain?.isEmpty != false {
                                let link = node.toURLString()
                                if !link.isEmpty {
                                    Button("Copy Link", systemImage: "doc.on.doc") { ClientSystem.copy(link) }
                                    ShareLink(item: link, preview: SharePreview(node.name)) {
                                        Label("Share Link", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = [node.name]; confirmDelete = true }
                        }
#if os(iOS)
                        .clientSwipeActions {
                            Button("Delete", role: .destructive) { deleting = [node.name]; confirmDelete = true }
                            Button("Edit") { editingNode = node; editing = true }.tint(.blue)
                        }
#endif
                    }
                }
                .onMove { from, to in
                    guard !filtered, !selecting else { return }
                    var names = model.nodes.map(\.name); names.move(fromOffsets: from, toOffset: to)
                    Task { await model.reorderNodes(names) }
                }
                .moveDisabled(filtered || selecting)
            } header: { Text("Nodes (\(visible.count) / \(model.nodes.count))") } footer: {
                if selecting { Text("Selected: \(selected.count). Filters do not clear your selection.") }
            }
            Section {
                if selecting {
                    Button("Select All Visible") { selected.formUnion(visible.map(\.name)) }
                    Button("Clear Selection") { selected = [] }
                    Button("Test Selected Nodes") { latency.testLatencies(for: model.nodes.filter { selected.contains($0.name) }, transport: tunnel) }.disabled(selected.isEmpty)
                    Menu("Add Selected to Group") {
                        ForEach(model.groups.filter { ConfigurationValidator.builtInPolicyName($0.name) != "PROXY" }, id: \.name) { group in
                            Button(group.name) { Task { if await model.addNodes(selected, to: group.name) { selected = []; selecting = false } } }
                        }
                    }.disabled(selected.isEmpty || model.groups.isEmpty)
                    Button("Delete Selected Nodes", role: .destructive) { deleting = selected; confirmDelete = true }.disabled(selected.isEmpty)
                } else {
                    Button("Test Visible Nodes", systemImage: "bolt.fill") { latency.testLatencies(for: visible, transport: tunnel) }.disabled(visible.isEmpty)
                    Button("Sort All Nodes by Latency", systemImage: "arrow.up.arrow.down") {
                        let names = model.nodes.sorted { milliseconds($0) < milliseconds($1) }.map(\.name)
                        Task { await model.reorderNodes(names) }
                    }.disabled(model.nodes.isEmpty)
                }
            }
        }
        .searchable(text: $query, prompt: "Node name or server address")
        .navigationTitle("Manage Nodes").clientInlineTitle()
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: .clientToolbarTrailing) { if !selecting { EditButton() } }
#endif
            ToolbarItem(placement: .clientToolbarTrailing) {
                Button(selecting ? "Done" : "Select") { selecting.toggle(); if !selecting { selected = [] } }
            }
            ToolbarItem(placement: .clientToolbarTrailing) {
                Menu {
                    Button("Add Node", systemImage: "plus") { editingNode = nil; editing = true }
                    Button("Import Links or Subscription", systemImage: "link") { importingLinks = true }
                    Button("Import from File", systemImage: "doc") { importingFile = true }
                    Button("Scan QR Code", systemImage: "qrcode.viewfinder") { scanning = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $editing) { ProxyEditorView(configuration: editingNode) { node in Task { await model.saveNode(node, replacing: editingNode?.name) } } }
        .sheet(isPresented: $importingLinks) { ClientNodeImportView(source: "").clientEditorWindow() }
        .sheet(isPresented: $scanning) { ClientQRImportView().clientEditorWindow() }
        .confirmationDialog("Delete \(deleting.count) Node(s)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Nodes", role: .destructive) { let names = deleting; Task { if await model.removeNodes(names) { selected.subtract(names) } } }
        } message: { Text("The entire batch is checked first. Rules and proxy-chain references must be removed before deleting their nodes.") }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let file = try result.get()
                let text = try model.operations.configurationDocument.read(contentsOf: file)
                Task { do { _ = try await model.importNodes(text) } catch { model.report(error) } }
            } catch { model.report(error) }
        }
        .onChange(of: model.nodes.map(\.name)) { _, names in selected.formIntersection(names) }
        .disabled(model.isBusy)
    }
    private func milliseconds(_ node: ProxyConfiguration) -> Int {
        if case .success(let value) = latency.latencyResults[node.id] { return value }; return .max
    }
}
