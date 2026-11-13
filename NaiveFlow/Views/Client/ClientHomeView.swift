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
    @State private var proxiesExpanded = true
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
    private var animation: Animation? { reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                configurationCard
                runningCard
                modeCard
                proxyCard
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("NaiveFlow")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新建配置", systemImage: "doc.badge.plus") { editor = model.createProfile() }
                    Button("从 URL 导入配置", systemImage: "link") { showURL = true }
                    Button("从本地文件导入配置", systemImage: "square.and.arrow.down") { importingFile = true }
                    Divider()
                    Button("新增节点", systemImage: "plus.circle") { nodeToEdit = nil; showNodeEditor = true }
                } label: { Image(systemName: "plus").font(.system(size: 21, weight: .medium)) }
                .accessibilityLabel("添加配置或节点")
            }
        }
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
        .alert("从 URL 导入配置", isPresented: $showURL) {
            TextField("https://example.com/config.conf", text: $remoteURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("导入") { Task {
                do {
                    let text = try await model.fetchText(remoteURL)
                    editor = model.createProfile(name: URL(string: remoteURL)?.deletingPathExtension().lastPathComponent ?? "远程配置", text: text, sourceURL: remoteURL)
                } catch { model.report(error) }
            } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除配置？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let pendingDelete { model.deleteProfile(pendingDelete.id) }; pendingDelete = nil }
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
            else { model.error = "没有可用的延迟结果，请检查网络后重试。" }
        }
        .alert("VPN 错误", isPresented: Binding(get: { tunnel.startError != nil }, set: { if !$0 { tunnel.startError = nil } })) {
            Button("好") { tunnel.startError = nil }
        } message: { Text(tunnel.startError ?? "") }
    }

    private var configurationCard: some View {
        ClientCard {
            Button {
                withAnimation(animation) { configurationsExpanded.toggle() }
            } label: {
                HStack(spacing: 16) {
                    ClientSectionIcon(symbol: "doc.text.fill")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("我的配置").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                        HStack(spacing: 5) {
                            Text(model.activeName).lineLimit(1)
                            if model.hasApplied { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let date = model.profile?.updatedAt {
                            Text("上次更新：\(date.formatted(.dateTime.month().day().hour().minute()))")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Image(systemName: configurationsExpanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(20).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if configurationsExpanded {
                Divider().padding(.leading, 20)
                VStack(spacing: 0) {
                    ForEach(model.library.profiles) { profile in
                        HStack {
                            Button { Task { await model.activate(profile) } } label: {
                                HStack {
                                    Image(systemName: "doc.text").foregroundStyle(.blue)
                                    Text(profile.name).foregroundStyle(.primary).lineLimit(1)
                                    Spacer()
                                    if model.library.selectedID == profile.id { Image(systemName: "checkmark").foregroundStyle(.blue) }
                                }.frame(minHeight: 46).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.isBusy)
                            Menu {
                                Button("编辑 / 重命名", systemImage: "pencil") { editor = profile }
                                if profile.sourceURL != nil { Button("更新远程配置", systemImage: "arrow.clockwise") { Task { await model.updateProfile(profile) } } }
                                Button("复制配置", systemImage: "doc.on.doc") { editor = model.createProfile(name: profile.name + " 副本", text: profile.text) }
                                Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = profile }
                                    .disabled(profile.id == model.library.selectedID)
                            } label: { Image(systemName: "ellipsis").frame(width: 32, height: 40) }
                        }.font(.subheadline).padding(.horizontal, 20)
                    }
                    Divider().padding(.horizontal, 20)
                    HStack(spacing: 0) {
                        Button("新建", systemImage: "plus") { editor = model.createProfile() }.frame(maxWidth: .infinity)
                        Button("URL", systemImage: "link") { showURL = true }.frame(maxWidth: .infinity)
                        Button("文件", systemImage: "folder") { importingFile = true }.frame(maxWidth: .infinity)
                    }.font(.system(size: 13, weight: .medium)).padding(.vertical, 17)
                    NavigationLink { ClientProfilesView() } label: {
                        HStack { Text("配置管理"); Spacer(); Image(systemName: "chevron.right") }
                            .font(.subheadline).padding(.horizontal, 20).padding(.vertical, 14)
                    }
                }.transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var runningCard: some View {
        ClientCard {
            VStack(spacing: 17) {
                HStack(spacing: 12) {
                    if tunnel.rawStatus.isTransitioning { ProgressView().controlSize(.small) }
                    else { Circle().fill(connected ? Color.green : Color.gray.opacity(0.55)).frame(width: 10, height: 10) }
                    Text(connected ? "运行中" : tunnel.rawStatus.isTransitioning ? "连接中" : "已停止").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Toggle("代理运行", isOn: Binding(get: { connected }, set: { _ in model.operations.tunnel.toggle() }))
                        .labelsHidden().tint(.blue).disabled(!canToggle || model.isBusy)
                }
                HStack(spacing: 30) {
                    traffic(symbol: "arrow.up", total: stats.bytesOut, rate: stats.uploadBytesPerSecond)
                    traffic(symbol: "arrow.down", total: stats.bytesIn, rate: stats.downloadBytesPerSecond)
                    Spacer(minLength: 0)
                }
                if !model.hasApplied { Text("选择并应用配置后即可启动").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }.padding(20)
        }
    }

    private func traffic(symbol: String, total: Int64, rate: Int64?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                if connected, let rate { Text(ByteCountFormatter.string(fromByteCount: rate, countStyle: .binary) + "/s").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }.monospacedDigit()
        }
    }

    private var modeCard: some View {
        ClientCard {
            Menu {
                ForEach([ProxyMode.rule, .global, .direct], id: \.rawValue) { mode in
                    Button { Task { await model.setSetting("proxy-mode", value: mode.rawValue) } } label: {
                        if model.mode == mode { Label(modeTitle(mode), systemImage: "checkmark") }
                        else { Text(modeTitle(mode)) }
                    }
                }
            } label: {
                HStack(spacing: 16) {
                    ClientSectionIcon(symbol: "paperplane.fill")
                    Text("出站模式").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    Spacer()
                    Text(modeTitle(model.mode)).font(.system(size: 14)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 20).padding(.vertical, 17)
            }.tint(.primary).disabled(model.isBusy)
        }
    }
    private func modeTitle(_ mode: ProxyMode) -> String { mode == .rule ? "规则模式" : mode == .global ? "全局代理" : "直连模式" }

    private var proxyCard: some View {
        ClientCard {
            Button { withAnimation(animation) { proxiesExpanded.toggle() } } label: {
                HStack(spacing: 16) {
                    ClientSectionIcon(symbol: "paperplane.fill")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PROXY").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                        if !proxiesExpanded { Text(model.selectedNodeName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Text("\(model.nodes.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    Image(systemName: proxiesExpanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 20).padding(.vertical, 17).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if proxiesExpanded {
                if model.nodes.isEmpty {
                    VStack(spacing: 8) {
                        Text("还没有节点").font(.subheadline.weight(.medium))
                        Text("添加节点，或导入包含节点的配置").font(.caption).foregroundStyle(.secondary)
                        Button("添加节点", systemImage: "plus.circle") { nodeToEdit = nil; showNodeEditor = true }.padding(.top, 8)
                    }.padding(24)
                } else {
                    ForEach(model.nodes) { node in
                        Divider().padding(.leading, 56)
                        ClientNodeRow(node: node, selected: model.selectedNodeName == node.name, latency: latency.latencyResults[node.id]) {
                            Task { await model.selectNode(node.name) }
                        }.disabled(model.isBusy)
                        .contextMenu { Button("编辑节点", systemImage: "pencil") { nodeToEdit = node; showNodeEditor = true } }
                    }
                }
                Divider().padding(.horizontal, 20)
                HStack(spacing: 0) {
                    Button("延迟测试", systemImage: "bolt.fill") { latency.testLatencies(for: model.nodes, transport: tunnel) }
                        .frame(maxWidth: .infinity).disabled(model.nodes.isEmpty)
                    Divider().frame(height: 17)
                    Button("自动选择", systemImage: "shuffle") { autoChoosing = true; latency.testLatencies(for: model.nodes, transport: tunnel) }
                        .frame(maxWidth: .infinity).disabled(model.nodes.isEmpty || autoChoosing)
                }.font(.system(size: 13, weight: .medium)).padding(.vertical, 17)
                NavigationLink { ClientNodesView() } label: {
                    HStack { Text("节点管理"); Spacer(); Image(systemName: "chevron.right") }
                        .font(.system(size: 13)).padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
        }
    }
}
