//
//  ProxyEditorView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/1/26.
//

import SwiftUI

struct ProxyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ClientModel.self) private var model
    
    let configuration: ProxyConfiguration?
    let onSave: (ProxyConfiguration) -> Void
    
    @State private var blockQUIC = false
    @State private var selectedProtocol: OutboundProtocol = .anytls
    @State private var chainEnabled = false
    @State private var underlyingProxy = ""
    @State private var verifyServerCertificate = true
    @State private var serverCertificateFingerprint = ""
    @State private var verifyDownloadCertificate = true
    @State private var downloadCertificateFingerprint = ""
    @State private var name = ""
    @State private var serverAddress = ""
    @State private var serverPort = ""
    
    @State private var nowhereKey = ""
    @State private var nowhereNetwork: NowhereNetwork = .tcp
    @State private var nowhereMorph = true
    @State private var nowhereMorphPrelude: NowhereMorphPrelude = .fade

    @State private var vlessUUID = ""
    @State private var vlessEncryption = "none"
    @State private var vlessFlow = ""
    @State private var vlessTransport = "raw"
    
    @State private var vlessWebSocketHost = ""
    @State private var vlessWebSocketPath = "/"
    
    @State private var vlessHTTPUpgradeHost = ""
    @State private var vlessHTTPUpgradePath = "/"
    
    @State private var vlessGRPCServiceName = ""
    @State private var vlessGRPCAuthority = ""
    @State private var vlessGRPCMode = "gun"
    @State private var vlessGRPCUserAgent = ""
    
    @State private var vlessXHTTPHost = ""
    @State private var vlessXHTTPPath = "/"
    @State private var vlessXHTTPMode = "auto"
    @State private var vlessXHTTPExtra = ""
    
    @State private var vlessSecurity = "none"
    @State private var vlessTLSSNI = ""
    @State private var vlessTLSALPN = ""
    @State private var vlessTLSECHEnabled = false
    @State private var vlessTLSECHConfig = ""
    @State private var vlessRealitySNI = ""
    @State private var vlessRealityPublicKey = ""
    @State private var vlessRealityShortId = ""
    @State private var vlessFingerprint: TLSFingerprint = .default
    
    @State private var vlessXHTTPDownloadEnabled = false
    @State private var vlessXHTTPDownloadAddress = ""
    @State private var vlessXHTTPDownloadPort = ""
    @State private var vlessXHTTPDownloadHost = ""
    @State private var vlessXHTTPDownloadPath = "/"
    
    @State private var vlessXHTTPDownloadSecurity = "none"
    @State private var vlessXHTTPDownloadTLSSNI = ""
    @State private var vlessXHTTPDownloadTLSALPN = ""
    @State private var vlessXHTTPDownloadRealitySNI = ""
    @State private var vlessXHTTPDownloadRealityPublicKey = ""
    @State private var vlessXHTTPDownloadRealityShortId = ""
    @State private var vlessXHTTPDownloadFingerprint: TLSFingerprint = .default
    
    @State private var hysteriaPassword = ""
    @State private var hysteriaCC: HysteriaCongestionControl = .brutal
    @State private var hysteriaUploadMbpsText = String(HysteriaCongestionControl.uploadMbpsDefault)
    @State private var hysteriaDownloadMbpsText = String(HysteriaCongestionControl.downloadMbpsDefault)
    @State private var hysteriaObfuscationType = "none"
    @State private var hysteriaObfuscationPassword = ""
    @State private var hysteriaObfuscationMaxText = String(HysteriaObfuscation.geckoMaxPacketSizeDefault)
    @State private var hysteriaObfuscationMinText = String(HysteriaObfuscation.geckoMinPacketSizeDefault)
    @State private var hysteriaSNI = ""
    
    @State private var trojanPassword = ""
    @State private var trojanSNI = ""
    @State private var trojanALPN = ""
    @State private var trojanECHEnabled = false
    @State private var trojanECHConfig = ""
    @State private var trojanFingerprint: TLSFingerprint = .default
    
    @State private var anytlsPassword = ""
    @State private var anytlsSNI = ""
    @State private var anytlsALPN = ""
    @State private var anytlsECHEnabled = false
    @State private var anytlsECHConfig = ""
    @State private var anytlsFingerprint: TLSFingerprint = .default
    
    @State private var ssPassword = ""
    @State private var ssMethod = "2022-blake3-aes-256-gcm"
    
    @State private var socks5Username = ""
    @State private var socks5Password = ""
    
    private var isNowhere: Bool { selectedProtocol == .nowhere }
    private var isVLESS: Bool { selectedProtocol == .vless }
    private var isVLESSReality: Bool { vlessSecurity == "reality" }
    private var isVLESSTLS: Bool { vlessSecurity == "tls" }
    private var isHysteria: Bool { selectedProtocol == .hysteria }
    private var isTrojan: Bool { selectedProtocol == .trojan }
    private var isAnyTLS: Bool { selectedProtocol == .anytls }
    private var isShadowsocks: Bool { selectedProtocol == .shadowsocks }
    private var isSOCKS5: Bool { selectedProtocol == .socks5 }
    private var isDirect: Bool { selectedProtocol == .direct }
    
    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        if !isDirect && chainEnabled && !chainCandidates.contains(where: { $0.name == underlyingProxy }) { return false }
        if usesNodeTLS && !TLSCertificatePolicy.isValidFingerprint(serverCertificateFingerprint) { return false }
        if isVLESS && vlessXHTTPDownloadEnabled && vlessXHTTPDownloadSecurity == "tls"
            && !TLSCertificatePolicy.isValidFingerprint(downloadCertificateFingerprint) { return false }
        if isDirect { return true }
        guard !serverAddress.isEmpty else { return false }
        if isNowhere {
            return !nowhereKey.isEmpty && validNowherePort(serverPort) != nil
        }
        guard UInt16(serverPort) != nil else { return false }
        if isVLESS {
            guard UUID(vlessString: vlessUUID) != nil,
                  !isVLESSReality || (!vlessRealitySNI.isEmpty && !vlessRealityPublicKey.isEmpty) else { return false }
            if vlessTransport == "xhttp", vlessXHTTPDownloadEnabled {
                guard !vlessXHTTPDownloadAddress.isEmpty, UInt16(vlessXHTTPDownloadPort) != nil else { return false }
                if vlessXHTTPDownloadSecurity == "reality", vlessXHTTPDownloadRealityPublicKey.isEmpty { return false }
            }
            return true
        }
        if isHysteria {
            if hysteriaPassword.isEmpty { return false }
            if hysteriaCC == .brutal {
                guard let up = Int(hysteriaUploadMbpsText), HysteriaCongestionControl.uploadMbpsRange.contains(up),
                      let down = Int(hysteriaDownloadMbpsText), HysteriaCongestionControl.downloadMbpsRange.contains(down)
                else { return false }
            }
            return true
        }
        if isTrojan {
            return !trojanPassword.isEmpty
        }
        if isAnyTLS {
            return !anytlsPassword.isEmpty
        }
        if isShadowsocks {
            return !ssPassword.isEmpty
        }
        if isSOCKS5 {
            return true
        }
        return false
    }
    
    init(configuration: ProxyConfiguration? = nil, onSave: @escaping (ProxyConfiguration) -> Void) {
        self.configuration = configuration
        self.onSave = onSave
    }
    
    var body: some View {
        NavigationStack {
            ClientForm {
                Section {
                    LabeledContent {
                        TextField("Name", text: $name)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Name", systemName: "tag.fill", foregroundStyle: .white, backgroundStyle: .gray.gradient)
                    }
                }
                
                Section {
                    Picker(selection: $selectedProtocol) {
                        Text(String("AnyTLS")).tag(OutboundProtocol.anytls)
                        if configuration?.isDirect == true {
                            Text(String("Direct")).tag(OutboundProtocol.direct)
                        }
                        Text(String("Hysteria")).tag(OutboundProtocol.hysteria)
                        Text(String("Nowhere")).tag(OutboundProtocol.nowhere)
                        Text(String("Shadowsocks")).tag(OutboundProtocol.shadowsocks)
                        Text(String("SOCKS5")).tag(OutboundProtocol.socks5)
                        Text(String("Trojan")).tag(OutboundProtocol.trojan)
                        Text(String("VLESS")).tag(OutboundProtocol.vless)
                    } label: {
                        TextWithColorfulIcon(title: "Protocol", systemName: "arrow.down.left.arrow.up.right.circle.fill", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                    }
                }
                
                if !isDirect {
                    serverSettings
                }
                
                if !isDirect {
                    Section {
                        Toggle("Block QUIC", isOn: $blockQUIC)
                    } footer: {
                        Text("Applies to QUIC traffic forwarded through this node, not the node's own QUIC transport.")
                    }
                }
                networkSettings
                
                if isVLESS {
                    xraySecurityLayerSettings
                } else {
                    securityLayerSettings
                }
                
                if usesNodeTLS {
                    certificateSettings(verify: $verifyServerCertificate, fingerprint: $serverCertificateFingerprint, title: "TLS Certificate")
                }
                if isVLESS && vlessTransport == "xhttp" && vlessXHTTPDownloadEnabled && vlessXHTTPDownloadSecurity == "tls" {
                    certificateSettings(verify: $verifyDownloadCertificate, fingerprint: $downloadCertificateFingerprint, title: "TLS Certificate (Download)")
                }
                moreSettings
                if !isDirect { chainSettings }
            }
            .navigationTitle(configuration != nil ? "Edit Node" : "Add Node")
            .clientInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton("Save") { save() }
                        .disabled(!isValid)
                }
            }
        }
        .onAppear { populateFromExisting() }
    }
    
    @ViewBuilder
    private var serverSettings: some View {
        Section("Server") {
            LabeledContent {
                TextField("Address", text: $serverAddress)
                    .clientKeyboardType(.URL)
                    .autocorrectionDisabled()
                    .clientNoAutocapitalization()
                    .multilineTextAlignment(.trailing)
            } label: {
                TextWithColorfulIcon(title: "Address", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
            }
            LabeledContent {
                TextField(String("443"), text: $serverPort)
                    .clientKeyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            } label: {
                TextWithColorfulIcon(title: "Port", systemName: "123.rectangle", foregroundStyle: .white, backgroundStyle: .cyan.gradient)
            }
            if isNowhere {
                LabeledContent {
                    TextField("Key", text: $nowhereKey)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "Key", systemName: "key.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
            } else if isVLESS {
                LabeledContent {
                    TextField(String(localized: "UUID", comment: "UUID for VLESS protocol"), text: $vlessUUID)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "UUID", comment: "UUID for VLESS protocol", systemName: "key.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
                LabeledContent {
                    TextField(String("none"), text: $vlessEncryption)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "Encryption", comment: "Encryption for VLESS protocol", systemName: "lock.fill", foregroundStyle: .white, backgroundStyle: .red.gradient)
                }
            } else if isHysteria {
                LabeledContent {
                    TextField("Password", text: $hysteriaPassword)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "Password", systemName: "key.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
                Picker(selection: $hysteriaObfuscationType) {
                    Text("None").tag("none")
                    Text(String("Salamander")).tag("salamander")
                    Text(String("Gecko")).tag("gecko")
                } label: {
                    TextWithColorfulIcon(title: "Obfuscation", comment: "Obfuscation for Hysteria protocol", systemName: "theatermasks.fill", foregroundStyle: .white, backgroundStyle: .purple.gradient)
                }
                if hysteriaObfuscationType != "none" {
                    LabeledContent {
                        TextField("Password", text: $hysteriaObfuscationPassword)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Password", systemName: "key.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                    }
                }
                if hysteriaObfuscationType == "gecko" {
                    LabeledContent {
                        TextField(String(HysteriaObfuscation.geckoMaxPacketSizeDefault), text: $hysteriaObfuscationMaxText)
                            .clientKeyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Maximum Packet Size", comment: "Maximum Packet Size for Hysteria protocol Gecko obfuscation", systemName: "plus.circle.fill", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                    }
                    LabeledContent {
                        TextField(String(HysteriaObfuscation.geckoMinPacketSizeDefault), text: $hysteriaObfuscationMinText)
                            .clientKeyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Minimum Packet Size", comment: "Minimum Packet Size for Hysteria protocol Gecko obfuscation", systemName: "minus.circle.fill", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                    }
                }
            } else if isTrojan {
                LabeledContent {
                    TextField("Password", text: $trojanPassword)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "Password", systemName: "key.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
            } else if isAnyTLS {
                LabeledContent {
                    TextField("Password", text: $anytlsPassword)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "Password", systemName: "key.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
            } else if isShadowsocks {
                LabeledContent {
                    TextField("Password", text: $ssPassword)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "Password", systemName: "key.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
                Picker(selection: $ssMethod) {
                    Text(String("BLAKE3-AES-128-GCM")).tag("2022-blake3-aes-128-gcm")
                    Text(String("BLAKE3-AES-256-GCM")).tag("2022-blake3-aes-256-gcm")
                    Text(String("BLAKE3-ChaCha20-Poly1305")).tag("2022-blake3-chacha20-poly1305")
                } label: {
                    TextWithColorfulIcon(title: "Method", comment: "Method for Shadowsocks protocol", systemName: "lock.fill", foregroundStyle: .white, backgroundStyle: .red.gradient)
                }
            } else if isSOCKS5 {
                LabeledContent {
                    TextField("Username", text: $socks5Username)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "Username", systemName: "person.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
                LabeledContent {
                    TextField("Password", text: $socks5Password)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "Password", systemName: "key.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
            }
        }
    }
    
    @ViewBuilder
    private var networkSettings: some View {
        if isNowhere {
            Section {
                Picker(selection: $nowhereNetwork) {
                    Text(verbatim: "TCP").tag(NowhereNetwork.tcp)
                    Text(verbatim: "UDP").tag(NowhereNetwork.udp)
                } label: {
                    TextWithColorfulIcon(title: "Network", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
                Toggle(isOn: $nowhereMorph) {
                    TextWithColorfulIcon(title: "Morph", systemName: "waveform", foregroundStyle: .white, backgroundStyle: .indigo.gradient)
                }
                if nowhereMorph {
                    Picker(selection: $nowhereMorphPrelude) {
                        ForEach(NowhereMorphPrelude.allCases, id: \.self) { prelude in
                            Text(prelude.displayName).tag(prelude)
                        }
                    } label: {
                        TextWithColorfulIcon(title: "Prelude", systemName: "text.line.first.and.arrowtriangle.forward", foregroundStyle: .white, backgroundStyle: .indigo.gradient)
                    }
                }
            }
        } else if isVLESS {
            Section {
                Picker(selection: $vlessFlow) {
                    Text("None").tag("")
                    Text("Vision").tag("xtls-rprx-vision")
                } label: {
                    TextWithColorfulIcon(title: "Flow", comment: "Flow for VLESS protocol TCP transport", systemName: "arrow.left.arrow.right", foregroundStyle: .white, backgroundStyle: .indigo.gradient)
                }
            }
            
            Section("Transport") {
                Picker(selection: $vlessTransport) {
                    Text("TCP").tag("raw")
                    Text("WebSocket").tag("ws")
                    Text("HTTPUpgrade").tag("httpupgrade")
                    Text("gRPC").tag("grpc")
                    Text("XHTTP").tag("xhttp")
                } label: {
                    TextWithColorfulIcon(title: "Transport", comment: "Transport for VLESS protocol", systemName: "arrow.triangle.swap", foregroundStyle: .white, backgroundStyle: .purple.gradient)
                }
                if vlessTransport == "ws" {
                    LabeledContent {
                        TextField("Host", text: $vlessWebSocketHost)
                            .clientKeyboardType(.URL)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Host", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    LabeledContent {
                        TextField("/", text: $vlessWebSocketPath)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Path", systemName: "point.topleft.down.to.point.bottomright.curvepath", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                }
                if vlessTransport == "httpupgrade" {
                    LabeledContent {
                        TextField("Host", text: $vlessHTTPUpgradeHost)
                            .clientKeyboardType(.URL)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Host", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    LabeledContent {
                        TextField("/", text: $vlessHTTPUpgradePath)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Path", systemName: "point.topleft.down.to.point.bottomright.curvepath", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                }
                if vlessTransport == "grpc" {
                    LabeledContent {
                        TextField("Service Name", text: $vlessGRPCServiceName)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Service Name", comment: "Service Name for VLESS protocol gRPC transport", systemName: "realtimetext", foregroundStyle: .white, backgroundStyle: .mint.gradient)
                    }
                    LabeledContent {
                        TextField("Authority", text: $vlessGRPCAuthority)
                            .clientKeyboardType(.URL)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Authority", comment: "Authority for VLESS protocol gRPC transport", systemName: "person.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                    }
                    Picker(selection: $vlessGRPCMode) {
                        Text("Gun").tag("gun")
                        Text("Multi").tag("multi")
                    } label: {
                        TextWithColorfulIcon(title: "Mode", systemName: "gearshape.fill", foregroundStyle: .white, backgroundStyle: .gray.gradient)
                    }
                    LabeledContent {
                        TextField("User Agent", text: $vlessGRPCUserAgent)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "User Agent", systemName: "laptopcomputer", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                    }
                }
                if vlessTransport == "xhttp" {
                    LabeledContent {
                        TextField("Host", text: $vlessXHTTPHost)
                            .clientKeyboardType(.URL)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Host", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    LabeledContent {
                        TextField("/", text: $vlessXHTTPPath)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Path", systemName: "point.topleft.down.to.point.bottomright.curvepath", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    Picker(selection: $vlessXHTTPMode) {
                        Text("Auto").tag("auto")
                        Text(String("Packet Up")).tag("packet-up")
                        Text(String("Stream Up")).tag("stream-up")
                        Text(String("Stream One")).tag("stream-one")
                    } label: {
                        TextWithColorfulIcon(title: "Mode", systemName: "gearshape.fill", foregroundStyle: .white, backgroundStyle: .gray.gradient)
                    }
                }
            }
        } else if isHysteria {
            Section {
                Picker(selection: $hysteriaCC) {
                    ForEach(HysteriaCongestionControl.allCases, id: \.self) { cc in
                        Text(cc.displayName).tag(cc)
                    }
                } label: {
                    TextWithColorfulIcon(title: "Congestion Control", comment: "Congestion control algorithm for Hysteria protocol", systemName: "speedometer", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
                if hysteriaCC == .brutal {
                    LabeledContent {
                        TextField("Mbps", text: $hysteriaUploadMbpsText)
                            .clientKeyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Upload Speed", comment: "Upload Speed for Hysteria protocol", systemName: "arrow.up.circle.fill", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    LabeledContent {
                        TextField("Mbps", text: $hysteriaDownloadMbpsText)
                            .clientKeyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Download Speed", comment: "Download Speed for Hysteria protocol", systemName: "arrow.down.circle.fill", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var xraySecurityLayerSettings: some View {
        Section((vlessTransport == "xhttp" && vlessXHTTPDownloadEnabled) ? String(localized: "TLS (Upload)") : String(localized: "TLS")) {
            Picker(selection: $vlessSecurity) {
                Text("None").tag("none")
                Text("TLS").tag("tls")
                Text("Reality").tag("reality")
            } label: {
                TextWithColorfulIcon(title: "Security", comment: "Security for VLESS protocol", systemName: "shield.lefthalf.filled", foregroundStyle: .white, backgroundStyle: .blue.gradient)
            }
            if isVLESSTLS {
                LabeledContent {
                    TextField("SNI", text: $vlessTLSSNI)
                        .clientKeyboardType(.URL)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "SNI", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
                LabeledContent {
                    TextField("h2,http/1.1", text: $vlessTLSALPN)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "ALPN", systemName: "list.bullet", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
                Toggle(isOn: $vlessTLSECHEnabled) {
                    TextWithColorfulIcon(title: "Enable ECH", systemName: "lock.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
                if vlessTLSECHEnabled {
                    LabeledContent {
                        TextField("Base64", text: $vlessTLSECHConfig)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "ECH Config", systemName: "doc.text.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                    }
                }
                Picker(selection: $vlessFingerprint) {
                    ForEach(TLSFingerprint.allCases, id: \.self) { fp in
                        Text(fp.displayName).tag(fp)
                    }
                } label: {
                    TextWithColorfulIcon(title: "Fingerprint", systemName: "hand.raised.fingers.spread.fill", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                }
            }
            if isVLESSReality {
                LabeledContent {
                    TextField("SNI", text: $vlessRealitySNI)
                        .clientKeyboardType(.URL)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "SNI", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
                LabeledContent {
                    TextField("Public Key", text: $vlessRealityPublicKey)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "Public Key", comment: "Public Key for Reality security layer", systemName: "key.horizontal.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
                LabeledContent {
                    TextField("Short ID", text: $vlessRealityShortId)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "Short ID", comment: "Short ID for Reality security layer", systemName: "person.crop.square.filled.and.at.rectangle.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
                Picker(selection: $vlessFingerprint) {
                    ForEach(TLSFingerprint.allCases, id: \.self) { fp in
                        Text(fp.displayName).tag(fp)
                    }
                } label: {
                    TextWithColorfulIcon(title: "Fingerprint", systemName: "hand.raised.fingers.spread.fill", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                }
            }
        }
    }
    
    @ViewBuilder
    private var securityLayerSettings: some View {
        if isHysteria {
            Section("TLS") {
                LabeledContent {
                    TextField("SNI", text: $hysteriaSNI)
                        .clientKeyboardType(.URL)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "SNI", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
            }
        } else if isTrojan {
            Section("TLS") {
                LabeledContent {
                    TextField("SNI", text: $trojanSNI)
                        .clientKeyboardType(.URL)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "SNI", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
                LabeledContent {
                    TextField("h2,http/1.1", text: $trojanALPN)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "ALPN", systemName: "list.bullet", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
                Toggle(isOn: $trojanECHEnabled) {
                    TextWithColorfulIcon(title: "Enable ECH", systemName: "lock.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
                if trojanECHEnabled {
                    LabeledContent {
                        TextField("Base64", text: $trojanECHConfig)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "ECH Config", systemName: "doc.text.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                    }
                }
                Picker(selection: $trojanFingerprint) {
                    ForEach(TLSFingerprint.allCases, id: \.self) { fp in
                        Text(fp.displayName).tag(fp)
                    }
                } label: {
                    TextWithColorfulIcon(title: "Fingerprint", systemName: "hand.raised.fingers.spread.fill", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                }
            }
        } else if isAnyTLS {
            Section("TLS") {
                LabeledContent {
                    TextField("SNI", text: $anytlsSNI)
                        .clientKeyboardType(.URL)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "SNI", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
                LabeledContent {
                    TextField("h2,http/1.1", text: $anytlsALPN)
                        .autocorrectionDisabled()
                        .clientNoAutocapitalization()
                        .multilineTextAlignment(.trailing)
                } label: {
                    TextWithColorfulIcon(title: "ALPN", systemName: "list.bullet", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
                Toggle(isOn: $anytlsECHEnabled) {
                    TextWithColorfulIcon(title: "Enable ECH", systemName: "lock.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                }
                if anytlsECHEnabled {
                    LabeledContent {
                        TextField("Base64", text: $anytlsECHConfig)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "ECH Config", systemName: "doc.text.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                    }
                }
                Picker(selection: $anytlsFingerprint) {
                    ForEach(TLSFingerprint.allCases, id: \.self) { fp in
                        Text(fp.displayName).tag(fp)
                    }
                } label: {
                    TextWithColorfulIcon(title: "Fingerprint", systemName: "hand.raised.fingers.spread.fill", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                }
            }
        }
    }

    private var chainCandidates: [ProxyConfiguration] {
        model.nodes.filter { node in
            !node.isDirect && node.name != configuration?.name && node.name != name &&
            !(node.chain ?? []).contains { $0.name == configuration?.name || $0.name == name }
        }
    }

    private var chainSettings: some View {
        Section {
            Toggle("Use a Proxy Chain", isOn: $chainEnabled)
            if chainEnabled {
                Picker("Upstream Node", selection: $underlyingProxy) {
                    Text("Select an Existing Node").tag("")
                    ForEach(chainCandidates) { node in Text(node.name).tag(node.name) }
                }
                if chainCandidates.isEmpty { Text("Add another proxy node first.").designText(.caption).foregroundStyle(DesignSystem.Colors.secondaryText) }
            }
        } footer: {
            if chainEnabled, let upstream = chainCandidates.first(where: { $0.name == underlyingProxy }) {
                let hops = (upstream.chain ?? []).map(\.name) + [upstream.name, name.isEmpty ? "Current Node" : name]
                Text((["This Device"] + hops + ["Destination"]).joined(separator: " → "))
            } else {
                Text("Use an existing node as the upstream proxy, then connect through the current node to the destination.")
            }
        }
    }

    @ViewBuilder
    private var moreSettings: some View {
        if isVLESS && vlessTransport == "xhttp" {
            Section {
                Toggle(isOn: $vlessXHTTPDownloadEnabled) {
                    TextWithColorfulIcon(title: "Detached Download", systemName: "arrow.down.circle.fill", foregroundStyle: .white, backgroundStyle: .indigo.gradient)
                }
                if vlessXHTTPDownloadEnabled {
                    LabeledContent {
                        TextField("Address", text: $vlessXHTTPDownloadAddress)
                            .clientKeyboardType(.URL)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Address", systemName: "server.rack", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    LabeledContent {
                        TextField("Port", text: $vlessXHTTPDownloadPort)
                            .clientKeyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Port", systemName: "123.rectangle", foregroundStyle: .white, backgroundStyle: .cyan.gradient)
                    }
                    LabeledContent {
                        TextField("Host", text: $vlessXHTTPDownloadHost)
                            .clientKeyboardType(.URL)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Host", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    LabeledContent {
                        TextField("/", text: $vlessXHTTPDownloadPath)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Path", systemName: "point.topleft.down.to.point.bottomright.curvepath", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                }
            }
        }
        
        if isVLESS && vlessTransport == "xhttp" && vlessXHTTPDownloadEnabled {
            Section("TLS (Download)") {
                Picker(selection: $vlessXHTTPDownloadSecurity) {
                    Text("None").tag("none")
                    Text("TLS").tag("tls")
                    Text("Reality").tag("reality")
                } label: {
                    TextWithColorfulIcon(title: "Security", systemName: "shield.lefthalf.filled", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                }
                if vlessXHTTPDownloadSecurity == "tls" {
                    LabeledContent {
                        TextField("SNI", text: $vlessXHTTPDownloadTLSSNI)
                            .clientKeyboardType(.URL)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "SNI", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    LabeledContent {
                        TextField("h2,http/1.1", text: $vlessXHTTPDownloadTLSALPN)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "ALPN", systemName: "list.bullet", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    Picker(selection: $vlessXHTTPDownloadFingerprint) {
                        ForEach(TLSFingerprint.allCases, id: \.self) { fp in
                            Text(fp.displayName).tag(fp)
                        }
                    } label: {
                        TextWithColorfulIcon(title: "Fingerprint", systemName: "hand.raised.fingers.spread.fill", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                    }
                }
                if vlessXHTTPDownloadSecurity == "reality" {
                    LabeledContent {
                        TextField("SNI", text: $vlessXHTTPDownloadRealitySNI)
                            .clientKeyboardType(.URL)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "SNI", systemName: "network", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    LabeledContent {
                        TextField("Public Key", text: $vlessXHTTPDownloadRealityPublicKey)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Public Key", systemName: "key.horizontal.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                    }
                    LabeledContent {
                        TextField("Short ID", text: $vlessXHTTPDownloadRealityShortId)
                            .autocorrectionDisabled()
                            .clientNoAutocapitalization()
                            .multilineTextAlignment(.trailing)
                    } label: {
                        TextWithColorfulIcon(title: "Short ID", systemName: "person.crop.square.filled.and.at.rectangle.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                    }
                    Picker(selection: $vlessXHTTPDownloadFingerprint) {
                        ForEach(TLSFingerprint.allCases, id: \.self) { fp in
                            Text(fp.displayName).tag(fp)
                        }
                    } label: {
                        TextWithColorfulIcon(title: "Fingerprint", systemName: "hand.raised.fingers.spread.fill", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                    }
                }
            }
        }
        
    }
    
    private var usesNodeTLS: Bool { isNowhere || isHysteria || isTrojan || isAnyTLS || (isVLESS && isVLESSTLS) }
    private var nodeCertificatePolicy: TLSCertificatePolicy {
        TLSCertificatePolicy(insecureSkipVerify: !verifyServerCertificate, certificateSHA256: serverCertificateFingerprint)
    }

    private func certificateSettings(verify: Binding<Bool>, fingerprint: Binding<String>, title: String) -> some View {
        Section {
            Toggle("Verify Server Certificate", isOn: verify)
            TextField("Certificate SHA-256 Fingerprint (Optional)", text: fingerprint)
                .designText(.caption, design: .monospaced)
                .clientNoAutocapitalization()
                .autocorrectionDisabled()
            if !TLSCertificatePolicy.isValidFingerprint(fingerprint.wrappedValue) {
                Text("Enter a SHA-256 fingerprint containing 64 hexadecimal characters.")
                    .designText(.caption).foregroundStyle(DesignSystem.Colors.error)
            }
        } header: {
            Text(title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("A certificate fingerprint applies only to this node and must match when set. Leave it empty to use system trust.")
                if !verify.wrappedValue {
                    Text("With verification disabled and no fingerprint, the server's identity is not checked.")
                }

            }
        }
    }

    private func populateFromExisting() {
        guard let configuration else { return }
        underlyingProxy = configuration.underlyingProxy ?? ""
        chainEnabled = configuration.underlyingProxy != nil
        blockQUIC = configuration.blockQUIC ?? AWCore.getQUICPolicy().blocksQUIC(isProxied: !configuration.isDirect)
        let policy = configuration.nodeCertificatePolicy
        verifyServerCertificate = !policy.insecureSkipVerify
        serverCertificateFingerprint = policy.certificateSHA256 ?? ""
        selectedProtocol = configuration.outboundProtocol
        name = configuration.name
        serverAddress = configuration.serverAddress
        serverPort = String(configuration.serverPort)
        if case .nowhere(let nowhere) = configuration.outbound {
            nowhereKey = nowhere.key
            nowhereNetwork = nowhere.network
            nowhereMorph = nowhere.morph
            nowhereMorphPrelude = nowhere.morphPrelude
        }
        if let vless = configuration.vless {
            vlessUUID = vless.uuid.uuidString
            vlessEncryption = vless.encryption
            vlessFlow = vless.flow ?? ""
        } else {
            vlessUUID = configuration.id.uuidString
            vlessEncryption = "none"
            vlessFlow = ""
        }
        if isVLESS {
            vlessTransport = configuration.xrayTransportLayer.tag
            vlessSecurity = configuration.xraySecurityLayer.tag
            
            if case .ws(let ws) = configuration.xrayTransportLayer {
                vlessWebSocketHost = ws.host
                vlessWebSocketPath = ws.path
            }
            
            if case .httpUpgrade(let httpUpgrade) = configuration.xrayTransportLayer {
                vlessHTTPUpgradeHost = httpUpgrade.host
                vlessHTTPUpgradePath = httpUpgrade.path
            }
            
            if case .grpc(let grpc) = configuration.xrayTransportLayer {
                vlessGRPCServiceName = grpc.serviceName
                vlessGRPCAuthority = grpc.authority
                vlessGRPCMode = grpc.multiMode ? "multi" : "gun"
                vlessGRPCUserAgent = grpc.userAgent
            }
            
            if case .xhttp(let xhttp) = configuration.xrayTransportLayer {
                vlessXHTTPHost = xhttp.host
                vlessXHTTPPath = xhttp.path
                vlessXHTTPMode = xhttp.mode.rawValue
                vlessXHTTPExtra = xhttp.encodedExtra
                if let download = xhttp.downloadSettings {
                    vlessXHTTPDownloadEnabled = true
                    vlessXHTTPDownloadAddress = download.serverAddress
                    vlessXHTTPDownloadPort = String(download.serverPort)
                    vlessXHTTPDownloadSecurity = download.security
                    if let tls = download.tls {
                        verifyDownloadCertificate = !tls.insecureSkipVerify
                        downloadCertificateFingerprint = tls.serverCertificateFingerprint ?? ""
                        vlessXHTTPDownloadTLSSNI = tls.serverName
                        vlessXHTTPDownloadTLSALPN = tls.alpn?.joined(separator: ",") ?? ""
                        vlessXHTTPDownloadFingerprint = tls.fingerprint
                    }
                    if let reality = download.reality {
                        vlessXHTTPDownloadRealitySNI = reality.serverName
                        vlessXHTTPDownloadRealityPublicKey = reality.publicKey.base64URLEncodedString()
                        vlessXHTTPDownloadRealityShortId = reality.shortId.hexEncodedString()
                        vlessXHTTPDownloadFingerprint = reality.fingerprint
                    }
                    vlessXHTTPDownloadHost = download.xhttp.host
                    vlessXHTTPDownloadPath = download.xhttp.path
                }
            }
            
            if case .tls(let tls) = configuration.xraySecurityLayer {
                vlessTLSSNI = tls.serverName
                vlessTLSALPN = tls.alpn?.joined(separator: ",") ?? ""
                vlessTLSECHEnabled = tls.echEnabled
                vlessTLSECHConfig = tls.echConfig ?? ""
                vlessFingerprint = tls.fingerprint
            }
            
            if case .reality(let reality) = configuration.xraySecurityLayer {
                vlessRealitySNI = reality.serverName
                vlessRealityPublicKey = reality.publicKey.base64URLEncodedString()
                vlessRealityShortId = reality.shortId.hexEncodedString()
                vlessFingerprint = reality.fingerprint
            }
        }
        
        switch configuration.outbound {
        case .nowhere:
            break
        case .vless:
            break
        case .hysteria(let configuration):
            hysteriaPassword = configuration.password
            hysteriaCC = configuration.congestionControl
            hysteriaUploadMbpsText = String(configuration.uploadMbps)
            hysteriaDownloadMbpsText = String(configuration.downloadMbps)
            if let obfuscation = configuration.obfuscation {
                hysteriaObfuscationType = obfuscation.typeTag
                hysteriaObfuscationPassword = obfuscation.password
                if case .gecko(_, let minPacketSize, let maxPacketSize) = obfuscation {
                    hysteriaObfuscationMaxText = String(maxPacketSize)
                    hysteriaObfuscationMinText = String(minPacketSize)
                }
            }
            hysteriaSNI = configuration.serverName
        case .trojan(let configuration):
            let tls = configuration.tlsConfiguration ?? TLSConfiguration(serverName: "")
            trojanPassword = configuration.password
            trojanSNI = tls.serverName
            trojanALPN = tls.alpn?.joined(separator: ",") ?? ""
            trojanECHEnabled = tls.echEnabled
            trojanECHConfig = tls.echConfig ?? ""
            trojanFingerprint = tls.fingerprint
        case .anytls(let configuration):
            let tls = configuration.tlsConfiguration ?? TLSConfiguration(serverName: "")
            anytlsPassword = configuration.password
            anytlsSNI = tls.serverName
            anytlsALPN = tls.alpn?.joined(separator: ",") ?? ""
            anytlsECHEnabled = tls.echEnabled
            anytlsECHConfig = tls.echConfig ?? ""
            anytlsFingerprint = tls.fingerprint
        case .shadowsocks(let configuration):
            ssPassword = configuration.password
            ssMethod = configuration.method
        case .socks5(let configuration):
            socks5Username = configuration.username ?? ""
            socks5Password = configuration.password ?? ""
        case .direct:
            break
        }
    }
    
    private func xhttpDownloadSettingsDict() -> [String: Any]? {
        guard vlessXHTTPDownloadEnabled,
              !vlessXHTTPDownloadAddress.isEmpty,
              let port = UInt16(vlessXHTTPDownloadPort) else { return nil }
        var download: [String: Any] = [
            "address": vlessXHTTPDownloadAddress,
            "port": Int(port),
            "security": vlessXHTTPDownloadSecurity
        ]
        switch vlessXHTTPDownloadSecurity {
        case "tls":
            var tls: [String: Any] = ["fingerprint": vlessXHTTPDownloadFingerprint.rawValue]
            if !vlessXHTTPDownloadTLSSNI.isEmpty { tls["serverName"] = vlessXHTTPDownloadTLSSNI }
            let alpn = vlessXHTTPDownloadTLSALPN
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !alpn.isEmpty { tls["alpn"] = alpn }
            tls["allowInsecure"] = !verifyDownloadCertificate
            if let pin = TLSCertificatePolicy.normalize(downloadCertificateFingerprint) { tls["server-cert-fingerprint-sha256"] = pin }
            download["tlsSettings"] = tls
        case "reality":
            download["realitySettings"] = [
                "serverName": vlessXHTTPDownloadRealitySNI,
                "publicKey": vlessXHTTPDownloadRealityPublicKey,
                "shortId": vlessXHTTPDownloadRealityShortId,
                "fingerprint": vlessXHTTPDownloadFingerprint.rawValue
            ]
        default:
            break
        }
        var xhttpSettings: [String: Any] = [:]
        if !vlessXHTTPDownloadHost.isEmpty { xhttpSettings["host"] = vlessXHTTPDownloadHost }
        if !vlessXHTTPDownloadPath.isEmpty, vlessXHTTPDownloadPath != "/" { xhttpSettings["path"] = vlessXHTTPDownloadPath }
        if !xhttpSettings.isEmpty { download["xhttpSettings"] = xhttpSettings }
        return download
    }
    
    private var hysteriaObfuscationValue: HysteriaObfuscation? {
        HysteriaObfuscation.make(
            type: hysteriaObfuscationType == "none" ? nil : hysteriaObfuscationType,
            password: hysteriaObfuscationPassword,
            geckoMinPacketSize: Int(hysteriaObfuscationMinText),
            geckoMaxPacketSize: Int(hysteriaObfuscationMaxText)
        )
    }
    
    private func save() {
        let port: UInt16
        if isDirect {
            port = 0
        } else {
            guard let parsedPort = UInt16(serverPort), !isNowhere || parsedPort != 0 else { return }
            port = parsedPort
        }
        let parsedUUID: UUID
        if isNowhere || isHysteria || isTrojan || isAnyTLS || isShadowsocks || isSOCKS5 || isDirect {
            parsedUUID = self.configuration?.id ?? UUID()
        } else {
            guard let uuid = UUID(vlessString: vlessUUID) else { return }
            parsedUUID = uuid
        }
        
        let bareAddress = serverAddress.hasPrefix("[") && serverAddress.hasSuffix("]")
        ? String(serverAddress.dropFirst().dropLast())
        : serverAddress
        
        let outbound: Outbound
        switch selectedProtocol {
        case .nowhere:
            outbound = .nowhere(NowhereConfiguration(
                key: nowhereKey,
                network: nowhereNetwork,
                morph: nowhereMorph,
                morphPrelude: nowhereMorphPrelude,
                certificatePolicy: nodeCertificatePolicy
            ))
        case .vless:
            var vlessTLSConfiguration: TLSConfiguration?
            if isVLESSTLS {
                let sni = vlessTLSSNI.isEmpty ? serverAddress : vlessTLSSNI
                let alpn: [String]? = vlessTLSALPN.isEmpty ? nil : vlessTLSALPN.split(separator: ",").map { String($0) }
                let ech = vlessTLSECHConfig.trimmingCharacters(in: .whitespacesAndNewlines)
                vlessTLSConfiguration = TLSConfiguration(
                    serverName: sni,
                    alpn: alpn,
                    echEnabled: vlessTLSECHEnabled,
                    echConfig: vlessTLSECHEnabled && !ech.isEmpty ? ech : nil,
                    fingerprint: vlessFingerprint,
                    insecureSkipVerify: nodeCertificatePolicy.insecureSkipVerify,
                    serverCertificateFingerprint: nodeCertificatePolicy.certificateSHA256
                )
            }
            
            var vlessRealityConfiguration: RealityConfiguration?
            if isVLESSReality {
                guard let publicKey = Data(base64URLEncoded: vlessRealityPublicKey) else { return }
                let shortId = Data(hexString: vlessRealityShortId) ?? Data()
                vlessRealityConfiguration = RealityConfiguration(
                    serverName: vlessRealitySNI,
                    publicKey: publicKey,
                    shortId: shortId,
                    fingerprint: vlessFingerprint
                )
            }
            
            var vlessWebSocketConfiguration: WebSocketConfiguration?
            if vlessTransport == "ws" {
                let host = vlessWebSocketHost.isEmpty ? serverAddress : vlessWebSocketHost
                let path = vlessWebSocketPath.isEmpty ? "/" : vlessWebSocketPath
                vlessWebSocketConfiguration = WebSocketConfiguration(host: host, path: path)
            }
            
            var vlessHTTPUpgradeConfiguration: HTTPUpgradeConfiguration?
            if vlessTransport == "httpupgrade" {
                vlessHTTPUpgradeConfiguration = HTTPUpgradeConfiguration(host: vlessHTTPUpgradeHost.isEmpty ? serverAddress : vlessHTTPUpgradeHost, path: vlessHTTPUpgradePath.isEmpty ? "/" : vlessHTTPUpgradePath)
            }
            
            var vlessXHTTPConfiguration: XHTTPConfiguration?
            if vlessTransport == "xhttp" {
                let host = vlessXHTTPHost.isEmpty ? serverAddress : vlessXHTTPHost
                let mode = XHTTPMode(rawValue: vlessXHTTPMode) ?? .auto
                var parameters: [String: String] = [
                    "host": host,
                    "path": vlessXHTTPPath,
                    "mode": mode.rawValue
                ]
                var extra: [String: Any] = [:]
                if !vlessXHTTPExtra.isEmpty, let data = vlessXHTTPExtra.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    extra = parsed
                }
                if let download = xhttpDownloadSettingsDict() {
                    extra["downloadSettings"] = download
                }
                if !extra.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    parameters["extra"] = json
                }
                vlessXHTTPConfiguration = XHTTPConfiguration.parse(from: parameters, serverAddress: serverAddress)
            }
            
            var vlessGRPCConfiguration: GRPCConfiguration?
            if vlessTransport == "grpc" {
                vlessGRPCConfiguration = GRPCConfiguration(
                    serviceName: vlessGRPCServiceName,
                    authority: vlessGRPCAuthority,
                    multiMode: vlessGRPCMode == "multi",
                    userAgent: vlessGRPCUserAgent
                )
            }
            
            let vlessXrayTransportLayer: XrayTransportLayer
            if let vlessWebSocketConfiguration { vlessXrayTransportLayer = .ws(vlessWebSocketConfiguration) }
            else if let vlessHTTPUpgradeConfiguration { vlessXrayTransportLayer = .httpUpgrade(vlessHTTPUpgradeConfiguration) }
            else if let vlessXHTTPConfiguration { vlessXrayTransportLayer = .xhttp(vlessXHTTPConfiguration) }
            else if let vlessGRPCConfiguration { vlessXrayTransportLayer = .grpc(vlessGRPCConfiguration) }
            else { vlessXrayTransportLayer = .raw }
            
            let vlessXraySecurityLayer: XraySecurityLayer
            if let vlessRealityConfiguration { vlessXraySecurityLayer = .reality(vlessRealityConfiguration) }
            else if let vlessTLSConfiguration { vlessXraySecurityLayer = .tls(vlessTLSConfiguration) }
            else { vlessXraySecurityLayer = .none }
            
            outbound = .vless(
                VLESSConfiguration(
                    uuid: parsedUUID,
                    encryption: vlessEncryption,
                    flow: vlessFlow.isEmpty ? nil : vlessFlow,
                    transport: vlessXrayTransportLayer,
                    security: vlessXraySecurityLayer
                )
            )
        case .hysteria:
            outbound = .hysteria(
                HysteriaConfiguration(
                    password: hysteriaPassword,
                    congestionControl: hysteriaCC,
                    uploadMbps: Int(hysteriaUploadMbpsText) ?? HysteriaCongestionControl.uploadMbpsDefault,
                    downloadMbps: Int(hysteriaDownloadMbpsText) ?? HysteriaCongestionControl.downloadMbpsDefault,
                    obfuscation: hysteriaObfuscationValue,
                    serverName: hysteriaSNI.isEmpty ? bareAddress : hysteriaSNI,
                    certificatePolicy: nodeCertificatePolicy
                )
            )
        case .trojan:
            let sni = trojanSNI.isEmpty ? bareAddress : trojanSNI
            let alpn: [String]? = trojanALPN.isEmpty ? nil : trojanALPN.split(separator: ",").map { String($0) }
            let ech = trojanECHConfig.trimmingCharacters(in: .whitespacesAndNewlines)
            outbound = .trojan(
                TrojanConfiguration(
                    password: trojanPassword,
                    tls: TLSConfiguration(serverName: sni, alpn: alpn, echEnabled: trojanECHEnabled, echConfig: trojanECHEnabled && !ech.isEmpty ? ech : nil, fingerprint: trojanFingerprint, insecureSkipVerify: nodeCertificatePolicy.insecureSkipVerify, serverCertificateFingerprint: nodeCertificatePolicy.certificateSHA256)
                )
            )
        case .anytls:
            let sni = anytlsSNI.isEmpty ? bareAddress : anytlsSNI
            let alpn: [String]? = anytlsALPN.isEmpty ? nil : anytlsALPN.split(separator: ",").map { String($0) }
            let ech = anytlsECHConfig.trimmingCharacters(in: .whitespacesAndNewlines)
            outbound = .anytls(
                AnyTLSConfiguration(
                    password: anytlsPassword,
                    securityLayer: .tls(TLSConfiguration(serverName: sni, alpn: alpn, echEnabled: anytlsECHEnabled, echConfig: anytlsECHEnabled && !ech.isEmpty ? ech : nil, fingerprint: anytlsFingerprint, insecureSkipVerify: nodeCertificatePolicy.insecureSkipVerify, serverCertificateFingerprint: nodeCertificatePolicy.certificateSHA256)),
                    inheritingTuningFrom: self.configuration?.anytls
                )
            )
        case .shadowsocks:
            outbound = .shadowsocks(ShadowsocksConfiguration(password: ssPassword, method: ssMethod))
        case .socks5:
            outbound = .socks5(
                SOCKS5Configuration(
                    username: socks5Username.isEmpty ? nil : socks5Username,
                    password: socks5Password.isEmpty ? nil : socks5Password
                )
            )
        case .direct:
            outbound = .direct(DirectConfiguration())
        }
        
        let configuration = ProxyConfiguration(
            id: self.configuration?.id ?? UUID(),
            name: name,
            serverAddress: isDirect ? "" : bareAddress,
            serverPort: port,
            subscriptionId: self.configuration?.subscriptionId,
            outbound: outbound,
            blockQUIC: blockQUIC,
            underlyingProxy: !isDirect && chainEnabled ? underlyingProxy : nil
        )
        
        onSave(configuration)
        dismiss()
    }

    private func validNowherePort(_ value: String) -> UInt16? {
        guard let port = UInt16(value), port != 0 else { return nil }
        return port
    }

}
