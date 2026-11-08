import SwiftUI

struct RequestsView: View {
    @Environment(TunnelController.self) private var tunnel
    @State private var model = RequestsModel()
    @Environment(ConfigurationStore.self) private var configStore
    @Environment(ChainStore.self) private var chainStore
    @Environment(ProxySelection.self) private var proxySelection: ProxySelection?
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var paused = false
    @State private var followLatest = true
    @State private var query = ""
    @State private var filter: RequestsModel.Filter = .all
    @State private var selectedProtocol: RequestsModel.Entry.Transport?
    @State private var selectedRequest: RequestsModel.Entry?

    private var visible: [RequestsModel.Entry] {
        model.visibleRequests(query: query, filter: filter, protocol: selectedProtocol)
    }
    private var pollingEnabled: Bool { !paused && editMode == .inactive }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                Color.clear.frame(height: 1).listRowInsets(EdgeInsets()).id("latest")
                    .accessibilityHidden(true)
                ForEach(visible) { entry in
                    Group {
                        if editMode == .active {
                            row(entry)
                        } else {
                            Button { selectedRequest = entry } label: { row(entry) }
                                .buttonStyle(.plain)
                        }
                    }
                    .tag(entry.id)
                    .contextMenu {
                        Button("Copy Host", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = entry.host
                        }
                        Button("Copy Record", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = model.export([entry])
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followLatest = false }
            }
            .onChange(of: visible.first?.id) { _, _ in
                if followLatest && pollingEnabled { proxy.scrollTo("latest", anchor: .top) }
            }
            .onChange(of: followLatest) { _, following in
                if following { proxy.scrollTo("latest", anchor: .top) }
            }
            .overlay { emptyState }
        }
        .searchable(text: $query, prompt: "Search host, rule or outbound")
        .safeAreaInset(edge: .top, spacing: 0) { controls }
        .navigationTitle("Requests")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editMode == .active {
                    Button(selection.isEmpty ? "Cancel" : "Copy (\(selection.count))") {
                        if !selection.isEmpty {
                            UIPasteboard.general.string = visible.filter { selection.contains($0.id) }
                                .map(\.host).joined(separator: "\n")
                        }
                        selection.removeAll()
                        editMode = .inactive
                    }
                } else {
                    Button(paused ? "Resume Updates" : "Pause Updates",
                           systemImage: paused ? "play.fill" : "pause.fill") { paused.toggle() }
                    Menu {
                        Button("Select", systemImage: "checkmark.circle") { editMode = .active }
                        Toggle("Follow Latest", isOn: $followLatest)
                        ShareLink(item: model.export(visible)) {
                            Label("Export Visible Records", systemImage: "square.and.arrow.up")
                        }
                        .disabled(visible.isEmpty)
                        Button("Clear Records", systemImage: "trash", role: .destructive) {
                            model.clear()
                            selection.removeAll()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Request Actions")
                }
            }
        }
        .sheet(item: $selectedRequest) { selected in
            NavigationStack {
                RequestDetailView(entry: model.requests.first { $0.id == selected.id } ?? selected,
                                  outboundName: outboundName(selected),
                                  live: pollingEnabled && model.refreshState == .current &&
                                      model.requests.contains { $0.id == selected.id })
            }
        }
        .onChange(of: visible.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .task {
            while !Task.isCancelled {
                model.pruneExpired()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: pollingEnabled) {
            guard pollingEnabled else { return }
            while !Task.isCancelled {
                await model.poll(using: tunnel)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var monitoringStatus: String {
        guard pollingEnabled else { return String(localized: "Updates Paused") }
        switch model.refreshState {
        case .loading: return String(localized: "Connecting")
        case .current: return String(localized: "Live")
        case .unavailable: return String(localized: "Refresh Unavailable")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(monitoringStatus,
                      systemImage: pollingEnabled ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .foregroundStyle(pollingEnabled && model.refreshState == .current ? Color.green : Color.secondary)
                Spacer()
                Text("\(visible.count) / \(model.requests.count)")
                    .monospacedDigit().foregroundStyle(.secondary)
                if !followLatest {
                    Button("Latest", systemImage: "arrow.up.to.line") { followLatest = true }
                }
            }
            HStack {
                Menu {
                    ForEach(RequestsModel.Filter.allCases, id: \.self) { option in
                        Button { filter = option } label: {
                            Label(filterName(option), systemImage: filter == option ? "checkmark" : "line.3.horizontal.decrease")
                        }
                    }
                } label: { Label(filterName(filter), systemImage: "line.3.horizontal.decrease") }
                Spacer()
                Menu {
                    Button("All Protocols") { selectedProtocol = nil }
                    ForEach([RequestsModel.Entry.Transport.tcp, .udp, .quic, .unknown], id: \.self) { option in
                        Button(protocolName(option)) { selectedProtocol = option }
                    }
                } label: {
                    Text(selectedProtocol.map(protocolName) ?? String(localized: "All Protocols"))
                }
            }
            if model.refreshState == .unavailable {
                Label("Unable to refresh. Showing recent cached records.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            Text("Recent 5 minutes · Up to \(RequestLog.maxEntries) records")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder private var emptyState: some View {
        if visible.isEmpty {
            if !model.requests.isEmpty || !query.isEmpty || filter != .all || selectedProtocol != nil {
                ContentUnavailableView("No Matching Requests", systemImage: "line.3.horizontal.decrease")
            } else {
                switch model.refreshState {
                case .loading where pollingEnabled: ProgressView()
                case .unavailable:
                    ContentUnavailableView("Unable to Refresh Requests", systemImage: "wifi.exclamationmark",
                                           description: Text("Check the VPN connection and try again."))
                default: ContentUnavailableView("No Recent Requests", systemImage: "network")
                }
            }
        }
    }

    private func row(_ entry: RequestsModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(entry.host):\(String(entry.port))")
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                TagBadge(text: protocolName(entry.protocol), color: .blue)
                TagBadge(text: entry.displayRouteTarget.tagText, color: entry.displayRouteTarget.tagColor)
                TagBadge(text: requestStateName(entry.state), color: stateColor(entry.state))
            }
            let detail = [outboundName(entry), entry.ruleSetName, entry.blockReason.map(blockReasonName)]
                .compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let activity = entry.activity {
                Text("↑ \(formatBytes(activity.bytesOut))  ↓ \(formatBytes(activity.bytesIn))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func outboundName(_ entry: RequestsModel.Entry) -> String? {
        entry.outbound?.name ?? entry.routeTarget.outboundName(defaultRouteTarget: entry.defaultRouteTarget,
            configStore: configStore, chainStore: chainStore, selection: proxySelection)
    }
}

private struct RequestDetailView: View {
    let entry: RequestsModel.Entry
    let outboundName: String?
    let live: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Form {
                if !live {
                    Label("Updates paused or unavailable. Showing the last observed state.", systemImage: "pause.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Request") {
                    LabeledContent("Host", value: entry.host)
                    LabeledContent("Port", value: String(entry.port))
                    LabeledContent("Protocol", value: protocolName(entry.protocol))
                    LabeledContent("Time") { Text(entry.timestamp, format: .dateTime) }
                    LabeledContent("Status", value: requestStateName(entry.state))
                    if let address = entry.resolvedAddress {
                        LabeledContent("Resolved IPv4", value: address)
                    }
                    if let purpose = entry.resolutionPurpose {
                        LabeledContent("Resolution", value: purpose)
                    }
                }
                Section("Routing") {
                    LabeledContent("Route", value: entry.displayRouteTarget.tagText)
                    if let outboundName { LabeledContent("Outbound", value: outboundName) }
                    if let rule = entry.ruleSetName { LabeledContent("Matched Rule", value: rule) }
                    if let reason = entry.blockReason { LabeledContent("Reason", value: blockReasonName(reason)) }
                }
                if let activity = entry.activity {
                    Section {
                        LabeledContent("Upload", value: formatBytes(activity.bytesOut))
                        LabeledContent("Download", value: formatBytes(activity.bytesIn))
                        if let duration = entry.duration(at: live ? context.date : entry.observedAt) {
                            LabeledContent("Connection Duration", value: formatDuration(duration))
                        }
                        if let duration = entry.connectDuration {
                            LabeledContent("Connection Setup", value: formatDuration(duration))
                        }
                        if let failure = activity.failure { LabeledContent("Failure", value: failure) }
                    } header: {
                        Text("Connection")
                    } footer: {
                        Text("Traffic and timing describe the underlying connection. Multiple requests may share it.")
                    }
                }
                Section {
                    ShareLink(item: exportText) { Label("Export Record", systemImage: "square.and.arrow.up") }
                    Button("Copy Host", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.host }
                }
            }
            .textSelection(.enabled)
        }
        .navigationTitle("Request Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var exportText: String { RequestsModel().export([entry]) }
}

private func filterName(_ filter: RequestsModel.Filter) -> String {
    switch filter {
    case .all: String(localized: "All Requests")
    case .active: String(localized: "Active")
    case .failed: String(localized: "Failed")
    case .rejected: String(localized: "Rejected")
    }
}

private func protocolName(_ value: RequestsModel.Entry.Transport) -> String {
    value == .unknown ? String(localized: "Unknown") : value.rawValue.uppercased()
}

private func requestStateName(_ state: RequestsModel.Entry.State) -> String {
    switch state {
    case .connecting: String(localized: "Connecting")
    case .established: String(localized: "Connected")
    case .closed: String(localized: "Closed")
    case .failed: String(localized: "Failed")
    case .rejected: String(localized: "Rejected")
    case .unknown: String(localized: "Status Unavailable")
    }
}

private func stateColor(_ state: RequestsModel.Entry.State) -> Color {
    switch state {
    case .failed, .rejected: .red
    case .established: .green
    case .connecting: .orange
    default: .secondary
    }
}

private func blockReasonName(_ reason: TunnelRequestBlockReason) -> String {
    switch reason {
    case .rule: String(localized: "Rejected by rule")
    case .udpDisabled: String(localized: "UDP disabled")
    case .quicPolicy: String(localized: "QUIC blocked by policy")
    case .quicMITM: String(localized: "QUIC blocked for MITM")
    case .quicProxyPolicy: String(localized: "Proxied QUIC blocked")
    case .webRTC: String(localized: "WebRTC blocked")
    case .resourceLimit: String(localized: "Connection limit reached")
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .binary)
}

private func formatDuration(_ duration: TimeInterval) -> String {
    duration < 1 ? String(format: "%.0f ms", duration * 1000) : String(format: "%.1f s", duration)
}
