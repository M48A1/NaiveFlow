import SwiftUI

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
        ClientForm {
            Section("Target") {
                TextField("Domain (optional with IPv4)", text: $host)
                TextField("Resolved IPv4 (optional)", text: $ip)
#if !os(tvOS)
                    .clientKeyboardType(.numbersAndPunctuation)
#endif
                TextField("Destination Port", text: $port)
#if !os(tvOS)
                    .clientKeyboardType(.numberPad)
#endif
                Picker("Protocol", selection: $network) { Text("TCP").tag("TCP"); Text("UDP").tag("UDP") }
                Toggle("Resolve Domain if Needed", isOn: $resolve)
            }
            Section("Source (Optional)") {
                TextField("Source IPv4", text: $sourceIP)
                TextField("Source Port", text: $sourcePort)
#if !os(tvOS)
                    .clientKeyboardType(.numberPad)
#endif
            }
            Section {
                Button("Test Applied Rules") { Task { await test() } }.disabled(testing || (host.isEmpty && ip.isEmpty))
                if testing { ProgressView() }
                if let result {
                    Text(result)
#if !os(tvOS)
                        .textSelection(.enabled)
#endif
                }
            } footer: { Text("Uses the applied version, including its pinned rule sets and Geo data. Does not send target traffic. DNS runs only when enabled and required; missing source metadata may prevent a decision. Automatic groups choose a member at connection time.") }
        }
        .autocorrectionDisabled()
        .navigationTitle("Rule Test")
#if !os(tvOS)
        .clientNoAutocapitalization().clientKeyboardDone()
        .clientInlineTitle()
#endif
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
