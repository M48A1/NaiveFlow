//
//  ProxyEditorView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/19/26.
//

import UIKit

class TVProxyEditorViewController: UITableViewController {

    // MARK: - Properties

    private let existingConfiguration: ProxyConfiguration?
    private let onSave: (ProxyConfiguration) -> Void

    private var selectedProtocol: OutboundProtocol = .nowhere
    private var name = ""
    private var serverAddress = ""
    private var serverPort = ""

    private var nowhereKey = ""
    private var nowhereNetwork: NowhereNetwork = .tcp
    private var nowhereMorph = true
    private var nowhereMorphPrelude: NowhereMorphPrelude = .fade

    private var vlessUUID = ""
    private var vlessEncryption = "none"
    private var vlessFlow = ""
    private var vlessTransport = "raw"

    private var vlessWebSocketHost = ""
    private var vlessWebSocketPath = "/"

    private var vlessHTTPUpgradeHost = ""
    private var vlessHTTPUpgradePath = "/"

    private var vlessGRPCServiceName = ""
    private var vlessGRPCAuthority = ""
    private var vlessGRPCMode = "gun"
    private var vlessGRPCUserAgent = ""

    private var vlessXHTTPHost = ""
    private var vlessXHTTPPath = "/"
    private var vlessXHTTPMode = "auto"
    private var vlessXHTTPExtra = ""

    private var vlessSecurity = "none"
    private var vlessTLSSNI = ""
    private var vlessTLSALPN = ""
    private var vlessRealitySNI = ""
    private var vlessRealityPublicKey = ""
    private var vlessRealityShortId = ""
    private var vlessTLSECHEnabled = false
    private var vlessTLSECH = ""
    private var vlessFingerprint: TLSFingerprint = .default

    private var vlessXHTTPDownloadEnabled = false
    private var vlessXHTTPDownloadAddress = ""
    private var vlessXHTTPDownloadPort = ""
    private var vlessXHTTPDownloadHost = ""
    private var vlessXHTTPDownloadPath = "/"

    private var vlessXHTTPDownloadSecurity = "none"
    private var vlessXHTTPDownloadTLSSNI = ""
    private var vlessXHTTPDownloadTLSALPN = ""
    private var vlessXHTTPDownloadRealitySNI = ""
    private var vlessXHTTPDownloadRealityPublicKey = ""
    private var vlessXHTTPDownloadRealityShortId = ""
    private var vlessXHTTPDownloadFingerprint: TLSFingerprint = .default

    private var hysteriaPassword = ""
    private var hysteriaCC: HysteriaCongestionControl = .brutal
    private var hysteriaUploadMbpsText = String(HysteriaCongestionControl.uploadMbpsDefault)
    private var hysteriaDownloadMbpsText = String(HysteriaCongestionControl.downloadMbpsDefault)
    private var hysteriaObfuscationType = "none"
    private var hysteriaObfuscationPassword = ""
    private var hysteriaObfuscationMaxText = String(HysteriaObfuscation.geckoMaxPacketSizeDefault)
    private var hysteriaObfuscationMinText = String(HysteriaObfuscation.geckoMinPacketSizeDefault)
    private var hysteriaSNI = ""
    
    private var trojanPassword = ""
    private var trojanSNI = ""
    private var trojanALPN = ""
    private var trojanECHEnabled = false
    private var trojanECH = ""
    private var trojanFingerprint: TLSFingerprint = .default

    private var anytlsPassword = ""
    private var anytlsSNI = ""
    private var anytlsALPN = ""
    private var anytlsECHEnabled = false
    private var anytlsECH = ""
    private var anytlsFingerprint: TLSFingerprint = .default

    private var ssPassword = ""
    private var ssMethod = "2022-blake3-aes-256-gcm"

    private var socks5Username = ""
    private var socks5Password = ""

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

    // MARK: - Form Structure

    private enum RowType {
        case text(label: String, value: String, placeholder: String, key: FieldKey)
        case selection(label: String, value: String, options: [(display: String, value: String)], key: FieldKey, systemImage: String? = nil, isEnabled: Bool = true)
        case toggle(
            label: String,
            isOn: Bool,
            key: FieldKey,
            systemImage: String? = nil,
            isEnabled: Bool = true
        )
    }

    private enum FieldKey {
        case name, address, port
        case outboundProtocol
        case nowhereKey, nowhereNetwork, nowhereMorph, nowhereMorphPrelude
        case vlessUUID, vlessEncryption, vlessTransport, vlessFlow, vlessSecurity
        case vlessWebSocketHost, vlessWebSocketPath
        case vlessHTTPUpgradeHost, vlessHTTPUpgradePath
        case vlessGRPCServiceName, vlessGRPCAuthority, vlessGRPCMode, vlessGRPCUserAgent
        case vlessXHTTPHost, vlessXHTTPPath, vlessXHTTPMode
        case vlessTLSSNI, vlessTLSALPN, vlessTLSECHEnabled, vlessTLSECH, vlessFingerprint
        case vlessRealitySNI, vlessRealityPublicKey, vlessRealityShortId
        case vlessXHTTPDownloadEnabled, vlessXHTTPDownloadAddress, vlessXHTTPDownloadPort
        case vlessXHTTPDownloadHost, vlessXHTTPDownloadPath
        case vlessXHTTPDownloadSecurity, vlessXHTTPDownloadTLSSNI, vlessXHTTPDownloadTLSALPN, vlessXHTTPDownloadFingerprint
        case vlessXHTTPDownloadRealitySNI, vlessXHTTPDownloadRealityPublicKey,
             vlessXHTTPDownloadRealityShortId
        case hysteriaPassword, hysteriaCC, hysteriaUploadMbps, hysteriaDownloadMbps
        case hysteriaObfuscationType, hysteriaObfuscationPassword, hysteriaObfuscationMin, hysteriaObfuscationMax
        case hysteriaSNI
        case trojanPassword, trojanSNI, trojanALPN, trojanECHEnabled, trojanECH, trojanFingerprint
        case anytlsPassword, anytlsSNI, anytlsALPN, anytlsECHEnabled, anytlsECH, anytlsFingerprint
        case ssPassword, ssMethod
        case socks5Username, socks5Password
    }

    private var formSections: [(title: String?, rows: [RowType])] {
        var sections: [(title: String?, rows: [RowType])] = []

        sections.append((nil, [
            .text(label: String(localized: "Name"), value: name, placeholder: "Name", key: .name),
        ]))

        let protocolOptions: [(String, String)] = [
            ("Nowhere", "nowhere"),
            ("VLESS", "vless"),
            ("Hysteria", "hysteria"),
            ("Trojan", "trojan"),
            ("AnyTLS", "anytls"),
            ("Shadowsocks", "shadowsocks"),
            ("SOCKS5", "socks5"),
            ("Direct", "direct"),
        ]
        sections.append((String(localized: "Protocol"), [
            .selection(label: String(localized: "Protocol"), value: selectedProtocol.name, options: protocolOptions, key: .outboundProtocol),
        ]))

        var serverRows: [RowType] = [
            .text(label: String(localized: "Address"), value: serverAddress, placeholder: String(localized: "Address"), key: .address),
        ]
        if isNowhere {
            serverRows.append(.text(label: String(localized: "Port"), value: serverPort, placeholder: "443", key: .port))
            serverRows.append(.text(label: String(localized: "Key"), value: nowhereKey, placeholder: String(localized: "Key"), key: .nowhereKey))
        } else {
            serverRows.append(.text(label: String(localized: "Port"), value: serverPort, placeholder: "443", key: .port))
        }
        if isVLESS {
            serverRows.append(.text(label: String(localized: "UUID", comment: "UUID for VLESS protocol"), value: vlessUUID, placeholder: String(localized: "UUID", comment: "UUID for VLESS protocol"), key: .vlessUUID))
            if #available(tvOS 26.0, *) {
                serverRows.append(.text(label: String(localized: "Encryption", comment: "Encryption for VLESS protocol"), value: vlessEncryption, placeholder: "none", key: .vlessEncryption))
            }
        } else if isHysteria {
            serverRows.append(.text(label: String(localized: "Password"), value: hysteriaPassword, placeholder: String(localized: "Password"), key: .hysteriaPassword))
            serverRows.append(.selection(label: String(localized: "Obfuscation", comment: "Obfuscation for Hysteria protocol"), value: hysteriaObfuscationDisplayValue, options: [
                (String(localized: "None"), "none"),
                ("Salamander", "salamander"),
                ("Gecko", "gecko"),
            ], key: .hysteriaObfuscationType))
            if hysteriaObfuscationType != "none" {
                serverRows.append(.text(label: String(localized: "Password"), value: hysteriaObfuscationPassword, placeholder: String(localized: "Password"), key: .hysteriaObfuscationPassword))
            }
            if hysteriaObfuscationType == "gecko" {
                serverRows.append(.text(label: String(localized: "Maximum Packet Size", comment: "Maximum Packet Size for Hysteria protocol Gecko obfuscation"), value: hysteriaObfuscationMaxText, placeholder: String(HysteriaObfuscation.geckoMaxPacketSizeDefault), key: .hysteriaObfuscationMax))
                serverRows.append(.text(label: String(localized: "Minimum Packet Size", comment: "Minimum Packet Size for Hysteria protocol Gecko obfuscation"), value: hysteriaObfuscationMinText, placeholder: String(HysteriaObfuscation.geckoMinPacketSizeDefault), key: .hysteriaObfuscationMin))
            }
        } else if isTrojan {
            serverRows.append(.text(label: String(localized: "Password"), value: trojanPassword, placeholder: String(localized: "Password"), key: .trojanPassword))
        } else if isAnyTLS {
            serverRows.append(.text(label: String(localized: "Password"), value: anytlsPassword, placeholder: String(localized: "Password"), key: .anytlsPassword))
        } else if isShadowsocks {
            serverRows.append(.text(label: String(localized: "Password"), value: ssPassword, placeholder: String(localized: "Password"), key: .ssPassword))
            let methods: [(String, String)] = [
                ("BLAKE3-AES-128-GCM", "2022-blake3-aes-128-gcm"),
                ("BLAKE3-AES-256-GCM", "2022-blake3-aes-256-gcm"),
                ("BLAKE3-ChaCha20", "2022-blake3-chacha20-poly1305"),
            ]
            serverRows.append(.selection(label: String(localized: "Method", comment: "Method for Shadowsocks protocol"), value: ssMethodDisplayValue, options: methods, key: .ssMethod))
        } else if isSOCKS5 {
            serverRows.append(.text(label: String(localized: "Username"), value: socks5Username, placeholder: String(localized: "Username"), key: .socks5Username))
            serverRows.append(.text(label: String(localized: "Password"), value: socks5Password, placeholder: String(localized: "Password"), key: .socks5Password))
        }
        if !isDirect {
            sections.append((String(localized: "Server"), serverRows))
        }

        if isNowhere {
            var transportRows: [RowType] = [
                .selection(
                    label: String(localized: "Network"),
                    value: nowhereNetwork.rawValue.uppercased(),
                    options: [("TCP", "tcp"), ("UDP", "udp")],
                    key: .nowhereNetwork
                ),
                .toggle(label: String(localized: "Morph"), isOn: nowhereMorph, key: .nowhereMorph),
            ]
            if nowhereMorph {
                transportRows.append(.selection(
                    label: String(localized: "Prelude"),
                    value: nowhereMorphPrelude.displayName,
                    options: NowhereMorphPrelude.allCases.map { ($0.displayName, $0.rawValue) },
                    key: .nowhereMorphPrelude
                ))
            }
            sections.append((nil, transportRows))
        } else if isVLESS {
            var transportRows: [RowType] = [
                .selection(label: String(localized: "Transport", comment: "Transport for VLESS protocol"), value: transportDisplayValue, options: [
                    ("TCP", "raw"), ("WebSocket", "ws"), ("HTTPUpgrade", "httpupgrade"), ("gRPC", "grpc"), ("XHTTP", "xhttp"),
                ], key: .vlessTransport),
            ]
            if vlessTransport == "ws" {
                transportRows.append(.text(label: String(localized: "Host"), value: vlessWebSocketHost, placeholder: String(localized: "Host"), key: .vlessWebSocketHost))
                transportRows.append(.text(label: String(localized: "Path"), value: vlessWebSocketPath, placeholder: String(localized: "Path"), key: .vlessWebSocketPath))
            }
            if vlessTransport == "httpupgrade" {
                transportRows.append(.text(label: String(localized: "Host"), value: vlessHTTPUpgradeHost, placeholder: String(localized: "Host"), key: .vlessHTTPUpgradeHost))
                transportRows.append(.text(label: String(localized: "Path"), value: vlessHTTPUpgradePath, placeholder: String(localized: "Path"), key: .vlessHTTPUpgradePath))
            }
            if vlessTransport == "grpc" {
                transportRows.append(.text(label: String(localized: "Service Name", comment: "Service Name for VLESS protocol gRPC transport"), value: vlessGRPCServiceName, placeholder: String(localized: "Service Name", comment: "Service Name for VLESS protocol gRPC transport"), key: .vlessGRPCServiceName))
                transportRows.append(.text(label: String(localized: "Authority", comment: "Authority for VLESS protocol gRPC transport"), value: vlessGRPCAuthority, placeholder: String(localized: "Authority", comment: "Authority for VLESS protocol gRPC transport"), key: .vlessGRPCAuthority))
                transportRows.append(.selection(label: String(localized: "Mode"), value: grpcModeDisplayValue, options: [
                    ("Gun", "gun"),
                    ("Multi", "multi"),
                ], key: .vlessGRPCMode))
                transportRows.append(.text(label: String(localized: "User Agent"), value: vlessGRPCUserAgent, placeholder: String(localized: "User Agent"), key: .vlessGRPCUserAgent))
            }
            if vlessTransport == "xhttp" {
                transportRows.append(.text(label: String(localized: "Host"), value: vlessXHTTPHost, placeholder: String(localized: "Host"), key: .vlessXHTTPHost))
                transportRows.append(.text(label: String(localized: "Path"), value: vlessXHTTPPath, placeholder: String(localized: "Path"), key: .vlessXHTTPPath))
                transportRows.append(.selection(label: String(localized: "Mode"), value: xhttpModeDisplayValue, options: [
                    (String(localized: "Auto"), "auto"),
                    ("Packet Up", "packet-up"),
                    ("Stream Up", "stream-up"),
                    ("Stream One", "stream-one"),
                ], key: .vlessXHTTPMode))
            }
            sections.append((nil, [
                .selection(label: String(localized: "Flow", comment: "Flow for VLESS protocol TCP transport"), value: flowDisplayValue, options: [
                    (String(localized: "None"), ""),
                    ("Vision", "xtls-rprx-vision"),
                ], key: .vlessFlow),
            ]))
            sections.append((String(localized: "Transport"), transportRows))
        } else if isHysteria {
            var hysteriaNetworkRows: [RowType] = [
                .selection(label: String(localized: "Congestion Control", comment: "Congestion control algorithm for Hysteria protocol"), value: hysteriaCC.displayName, options: HysteriaCongestionControl.allCases.map { ($0.displayName, $0.rawValue) }, key: .hysteriaCC),
            ]
            if hysteriaCC == .brutal {
                hysteriaNetworkRows.append(.text(label: String(localized: "Upload Speed", comment: "Upload Speed for Hysteria protocol"), value: hysteriaUploadMbpsText, placeholder: String(localized: "Mbps"), key: .hysteriaUploadMbps))
                hysteriaNetworkRows.append(.text(label: String(localized: "Download Speed", comment: "Download Speed for Hysteria protocol"), value: hysteriaDownloadMbpsText, placeholder: String(localized: "Mbps"), key: .hysteriaDownloadMbps))
            }
            sections.append((nil, hysteriaNetworkRows))
        } else if isTrojan {
            var trojanRows: [RowType] = [
                .text(label: String(localized: "SNI"), value: trojanSNI, placeholder: String(localized: "SNI"), key: .trojanSNI),
                .text(label: String(localized: "ALPN"), value: trojanALPN, placeholder: String(localized: "h2,http/1.1"), key: .trojanALPN),
                .toggle(label: String(localized: "Enable ECH"), isOn: trojanECHEnabled, key: .trojanECHEnabled),
            ]
            if trojanECHEnabled {
                trojanRows.append(.text(label: String(localized: "ECH Config"), value: trojanECH, placeholder: String(localized: "Base64"), key: .trojanECH))
            }
            trojanRows.append(.selection(label: String(localized: "Fingerprint"), value: trojanFingerprint.displayName, options: TLSFingerprint.allCases.map { ($0.displayName, $0.rawValue) }, key: .trojanFingerprint))
            sections.append((String(localized: "TLS"), trojanRows))
        } else if isAnyTLS {
            var anytlsRows: [RowType] = [
                .text(label: String(localized: "SNI"), value: anytlsSNI, placeholder: String(localized: "SNI"), key: .anytlsSNI),
                .text(label: String(localized: "ALPN"), value: anytlsALPN, placeholder: String(localized: "h2,http/1.1"), key: .anytlsALPN),
                .toggle(label: String(localized: "Enable ECH"), isOn: anytlsECHEnabled, key: .anytlsECHEnabled),
            ]
            if anytlsECHEnabled {
                anytlsRows.append(.text(label: String(localized: "ECH Config"), value: anytlsECH, placeholder: String(localized: "Base64"), key: .anytlsECH))
            }
            anytlsRows.append(.selection(label: String(localized: "Fingerprint"), value: anytlsFingerprint.displayName, options: TLSFingerprint.allCases.map { ($0.displayName, $0.rawValue) }, key: .anytlsFingerprint))
            sections.append((String(localized: "TLS"), anytlsRows))
        }

        if isVLESS && vlessTransport == "xhttp" {
            var detachRows: [RowType] = [
                .toggle(label: String(localized: "Detached Download"), isOn: vlessXHTTPDownloadEnabled, key: .vlessXHTTPDownloadEnabled),
            ]
            if vlessXHTTPDownloadEnabled {
                detachRows.append(.text(label: String(localized: "Address"), value: vlessXHTTPDownloadAddress, placeholder: String(localized: "Address"), key: .vlessXHTTPDownloadAddress))
                detachRows.append(.text(label: String(localized: "Port"), value: vlessXHTTPDownloadPort, placeholder: "443", key: .vlessXHTTPDownloadPort))
            }
            sections.append((nil, detachRows))

            if vlessXHTTPDownloadEnabled {
                var downloadRows: [RowType] = [
                    .selection(label: String(localized: "Security", comment: "Security for VLESS protocol"), value: downloadSecurityDisplayValue, options: [
                        (String(localized: "None"), "none"),
                        ("TLS", "tls"),
                        ("Reality", "reality"),
                    ], key: .vlessXHTTPDownloadSecurity),
                ]
                if vlessXHTTPDownloadSecurity == "tls" {
                    downloadRows.append(.text(label: String(localized: "SNI"), value: vlessXHTTPDownloadTLSSNI, placeholder: String(localized: "SNI"), key: .vlessXHTTPDownloadTLSSNI))
                    downloadRows.append(.text(label: String(localized: "ALPN"), value: vlessXHTTPDownloadTLSALPN, placeholder: String(localized: "h2,http/1.1"), key: .vlessXHTTPDownloadTLSALPN))
                    downloadRows.append(.selection(label: String(localized: "Fingerprint"), value: vlessXHTTPDownloadFingerprint.displayName, options: TLSFingerprint.allCases.map { ($0.displayName, $0.rawValue) }, key: .vlessXHTTPDownloadFingerprint))
                }
                if vlessXHTTPDownloadSecurity == "reality" {
                    downloadRows.append(.text(label: String(localized: "SNI"), value: vlessXHTTPDownloadRealitySNI, placeholder: String(localized: "SNI"), key: .vlessXHTTPDownloadRealitySNI))
                    downloadRows.append(.text(label: String(localized: "Public Key", comment: "Public Key for Reality security layer"), value: vlessXHTTPDownloadRealityPublicKey, placeholder: String(localized: "Public Key", comment: "Public Key for Reality security layer"), key: .vlessXHTTPDownloadRealityPublicKey))
                    downloadRows.append(.text(label: String(localized: "Short ID", comment: "Short ID for Reality security layer"), value: vlessXHTTPDownloadRealityShortId, placeholder: String(localized: "Short ID", comment: "Short ID for Reality security layer"), key: .vlessXHTTPDownloadRealityShortId))
                    downloadRows.append(.selection(label: String(localized: "Fingerprint"), value: vlessXHTTPDownloadFingerprint.displayName, options: TLSFingerprint.allCases.map { ($0.displayName, $0.rawValue) }, key: .vlessXHTTPDownloadFingerprint))
                }
                downloadRows.append(.text(label: String(localized: "Host"), value: vlessXHTTPDownloadHost, placeholder: String(localized: "Host"), key: .vlessXHTTPDownloadHost))
                downloadRows.append(.text(label: String(localized: "Path"), value: vlessXHTTPDownloadPath, placeholder: String(localized: "Path"), key: .vlessXHTTPDownloadPath))
                sections.append((String(localized: "TLS (Download)"), downloadRows))
            }
        }

        return sections
    }

    private var ssMethodDisplayValue: String {
        switch ssMethod {
        case "none": String(localized: "None")
        case "aes-128-gcm": "AES-128-GCM"
        case "aes-256-gcm": "AES-256-GCM"
        case "chacha20-ietf-poly1305": "ChaCha20-Poly1305"
        case "2022-blake3-aes-128-gcm": "BLAKE3-AES-128-GCM"
        case "2022-blake3-aes-256-gcm": "BLAKE3-AES-256-GCM"
        case "2022-blake3-chacha20-poly1305": "BLAKE3-ChaCha20"
        default: ssMethod
        }
    }

    private var transportDisplayValue: String {
        switch vlessTransport {
        case "raw": "TCP"
        case "ws": "WebSocket"
        case "httpupgrade": "HTTPUpgrade"
        case "grpc": "gRPC"
        case "xhttp": "XHTTP"
        default: vlessTransport
        }
    }

    private var grpcModeDisplayValue: String {
        switch vlessGRPCMode {
        case "gun": "Gun"
        case "multi": "Multi"
        default: vlessGRPCMode
        }
    }

    private var flowDisplayValue: String {
        switch vlessFlow {
        case "xtls-rprx-vision": "Vision"
        default: String(localized: "None")
        }
    }

    private var xhttpModeDisplayValue: String {
        switch vlessXHTTPMode {
        case "auto": String(localized: "Auto")
        case "packet-up": "Packet Up"
        case "stream-up": "Stream Up"
        case "stream-one": "Stream One"
        default: vlessXHTTPMode
        }
    }

    private var securityDisplayValue: String {
        switch vlessSecurity {
        case "none": String(localized: "None")
        case "tls": "TLS"
        case "reality": "Reality"
        default: vlessSecurity
        }
    }

    private var downloadSecurityDisplayValue: String {
        switch vlessXHTTPDownloadSecurity {
        case "none": String(localized: "None")
        case "tls": "TLS"
        case "reality": "Reality"
        default: vlessXHTTPDownloadSecurity
        }
    }

    private var hysteriaObfuscationDisplayValue: String {
        switch hysteriaObfuscationType {
        case "salamander": "Salamander"
        case "gecko": "Gecko"
        default: String(localized: "None")
        }
    }
    
    private var hysteriaObfuscationValue: HysteriaObfuscation? {
        HysteriaObfuscation.make(
            type: hysteriaObfuscationType == "none" ? nil : hysteriaObfuscationType,
            password: hysteriaObfuscationPassword,
            geckoMinPacketSize: Int(hysteriaObfuscationMinText),
            geckoMaxPacketSize: Int(hysteriaObfuscationMaxText)
        )
    }

    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        if isDirect { return true }
        guard !serverAddress.isEmpty else { return false }
        if isNowhere {
            return !nowhereKey.isEmpty && validNowherePort(serverPort) != nil
        }
        guard UInt16(serverPort) != nil else { return false }
        if isVLESS {
            guard UUID(uuidString: vlessUUID) != nil,
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
        if isTrojan { return !trojanPassword.isEmpty }
        if isAnyTLS { return !anytlsPassword.isEmpty }
        if isShadowsocks { return !ssPassword.isEmpty }
        if isSOCKS5 { return true }
        return false
    }

    // MARK: - Init

    init(configuration: ProxyConfiguration? = nil, onSave: @escaping (ProxyConfiguration) -> Void) {
        self.existingConfiguration = configuration
        self.onSave = onSave
        super.init(style: .grouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = existingConfiguration != nil ? String(localized: "Edit Configuration") : String(localized: "Add Configuration")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.remembersLastFocusedIndexPath = true

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))

        if let configuration = existingConfiguration {
            populateFromExisting(configuration)
        }
        updateSaveButton()
    }

    // MARK: - Table View

    override func numberOfSections(in tableView: UITableView) -> Int {
        formSections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        formSections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        formSections[section].title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = formSections[indexPath.section].rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.isUserInteractionEnabled = true
        cell.contentView.alpha = 1

        switch row {
        case .text(let label, let value, let placeholder, _):
            var content = cell.defaultContentConfiguration()
            content.text = label
            if value.isEmpty {
                content.secondaryText = placeholder
                content.secondaryTextProperties.color = .tertiaryLabel
            } else {
                content.secondaryText = value
                content.secondaryTextProperties.color = .label
            }
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator

        case .selection(let label, let value, _, _, let systemImage, let isEnabled):
            var content = cell.defaultContentConfiguration()
            content.text = label
            content.image = systemImage.flatMap(UIImage.init(systemName:))
            content.secondaryText = value
            content.secondaryTextProperties.color = .systemBlue
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.isUserInteractionEnabled = isEnabled
            cell.contentView.alpha = isEnabled ? 1 : 0.5

        case .toggle(let label, let isOn, _, let systemImage, let isEnabled):
            var content = cell.defaultContentConfiguration()
            content.text = label
            content.image = systemImage.flatMap(UIImage.init(systemName:))
            content.secondaryText = isOn ? String(localized: "On") : String(localized: "Off")
            content.secondaryTextProperties.color = isOn ? .systemGreen : .secondaryLabel
            cell.contentConfiguration = content
            cell.isUserInteractionEnabled = isEnabled
            cell.contentView.alpha = isEnabled ? 1 : 0.5

        }

        return cell
    }

    // MARK: - Focus

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations {
            if let cell = context.nextFocusedView as? UITableViewCell {
                cell.overrideUserInterfaceStyle = .light
            }
            if let cell = context.previouslyFocusedView as? UITableViewCell {
                cell.overrideUserInterfaceStyle = .unspecified
            }
        }
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = formSections[indexPath.section].rows[indexPath.row]

        switch row {
        case .text(let label, let value, let placeholder, let key):
            let inputVC = TVTextInputViewController(
                title: label,
                currentValue: value,
                placeholder: placeholder
            ) { [weak self] newValue in
                self?.updateField(key, value: newValue)
                self?.tableView.reloadData()
                self?.updateSaveButton()
            }
            let nav = UINavigationController(rootViewController: inputVC)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)

        case .selection(_, _, let options, let key, _, let isEnabled):
            guard isEnabled else { return }
            let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            for (display, value) in options {
                alert.addAction(UIAlertAction(title: display, style: .default) { [weak self] _ in
                    self?.updateField(key, value: value)
                    self?.tableView.reloadData()
                    self?.updateSaveButton()
                })
            }
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            present(alert, animated: true)

        case .toggle(_, let isOn, let key, _, let isEnabled):
            guard isEnabled else { return }
            updateField(key, value: isOn ? "false" : "true")
            tableView.reloadData()
            updateSaveButton()

        }
    }

    // MARK: - Field Updates

    private func updateField(_ key: FieldKey, value: String) {
        switch key {
        case .name: name = value
        case .address: serverAddress = value
        case .port: serverPort = value
        case .outboundProtocol:
            if let proto = OutboundProtocol(rawValue: value) {
                selectedProtocol = proto
            }
        case .nowhereKey: nowhereKey = value
        case .nowhereNetwork:
            if let network = NowhereNetwork(rawValue: value) { nowhereNetwork = network }
        case .nowhereMorph: nowhereMorph = value == "true"
        case .nowhereMorphPrelude:
            if let prelude = NowhereMorphPrelude(rawValue: value) {
                nowhereMorphPrelude = prelude
            }
        case .vlessUUID: vlessUUID = value
        case .vlessEncryption: vlessEncryption = value
        case .vlessTransport: vlessTransport = value
        case .vlessFlow: vlessFlow = value
        case .vlessSecurity: vlessSecurity = value
        case .vlessWebSocketHost: vlessWebSocketHost = value
        case .vlessWebSocketPath: vlessWebSocketPath = value
        case .vlessHTTPUpgradeHost: vlessHTTPUpgradeHost = value
        case .vlessHTTPUpgradePath: vlessHTTPUpgradePath = value
        case .vlessGRPCServiceName: vlessGRPCServiceName = value
        case .vlessGRPCAuthority: vlessGRPCAuthority = value
        case .vlessGRPCMode: vlessGRPCMode = value
        case .vlessGRPCUserAgent: vlessGRPCUserAgent = value
        case .vlessXHTTPHost: vlessXHTTPHost = value
        case .vlessXHTTPPath: vlessXHTTPPath = value
        case .vlessXHTTPMode: vlessXHTTPMode = value
        case .vlessTLSSNI: vlessTLSSNI = value
        case .vlessTLSALPN: vlessTLSALPN = value
        case .vlessTLSECHEnabled: vlessTLSECHEnabled = value == "true"
        case .vlessTLSECH: vlessTLSECH = value
        case .vlessRealitySNI: vlessRealitySNI = value
        case .vlessRealityPublicKey: vlessRealityPublicKey = value
        case .vlessRealityShortId: vlessRealityShortId = value
        case .vlessFingerprint:
            if let fingerprint = TLSFingerprint(rawValue: value) { vlessFingerprint = fingerprint }
        case .vlessXHTTPDownloadEnabled: vlessXHTTPDownloadEnabled = value == "true"
        case .vlessXHTTPDownloadAddress: vlessXHTTPDownloadAddress = value
        case .vlessXHTTPDownloadPort: vlessXHTTPDownloadPort = value
        case .vlessXHTTPDownloadSecurity: vlessXHTTPDownloadSecurity = value
        case .vlessXHTTPDownloadTLSSNI: vlessXHTTPDownloadTLSSNI = value
        case .vlessXHTTPDownloadTLSALPN: vlessXHTTPDownloadTLSALPN = value
        case .vlessXHTTPDownloadFingerprint:
            if let fingerprint = TLSFingerprint(rawValue: value) { vlessXHTTPDownloadFingerprint = fingerprint }
        case .vlessXHTTPDownloadRealitySNI: vlessXHTTPDownloadRealitySNI = value
        case .vlessXHTTPDownloadRealityPublicKey: vlessXHTTPDownloadRealityPublicKey = value
        case .vlessXHTTPDownloadRealityShortId: vlessXHTTPDownloadRealityShortId = value
        case .vlessXHTTPDownloadHost: vlessXHTTPDownloadHost = value
        case .vlessXHTTPDownloadPath: vlessXHTTPDownloadPath = value
        case .hysteriaPassword: hysteriaPassword = value
        case .hysteriaCC:
            if let congestionControl = HysteriaCongestionControl(rawValue: value) { hysteriaCC = congestionControl }
        case .hysteriaUploadMbps: hysteriaUploadMbpsText = value
        case .hysteriaDownloadMbps: hysteriaDownloadMbpsText = value
        case .hysteriaSNI: hysteriaSNI = value
        case .hysteriaObfuscationType: hysteriaObfuscationType = value
        case .hysteriaObfuscationPassword: hysteriaObfuscationPassword = value
        case .hysteriaObfuscationMin: hysteriaObfuscationMinText = value
        case .hysteriaObfuscationMax: hysteriaObfuscationMaxText = value
        case .trojanPassword: trojanPassword = value
        case .trojanSNI: trojanSNI = value
        case .trojanALPN: trojanALPN = value
        case .trojanECHEnabled: trojanECHEnabled = value == "true"
        case .trojanECH: trojanECH = value
        case .trojanFingerprint:
            if let fingerprint = TLSFingerprint(rawValue: value) { trojanFingerprint = fingerprint }
        case .anytlsPassword: anytlsPassword = value
        case .anytlsSNI: anytlsSNI = value
        case .anytlsALPN: anytlsALPN = value
        case .anytlsECHEnabled: anytlsECHEnabled = value == "true"
        case .anytlsECH: anytlsECH = value
        case .anytlsFingerprint:
            if let fingerprint = TLSFingerprint(rawValue: value) { anytlsFingerprint = fingerprint }
        case .ssPassword: ssPassword = value
        case .ssMethod: ssMethod = value
        case .socks5Username: socks5Username = value
        case .socks5Password: socks5Password = value
        }
    }

    // MARK: - Populate

    private func populateFromExisting(_ configuration: ProxyConfiguration) {
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
                vlessFingerprint = tls.fingerprint
                vlessTLSECHEnabled = tls.echEnabled
                vlessTLSECH = tls.echConfig ?? ""
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
        case .hysteria(let hysteria):
            hysteriaPassword = hysteria.password
            hysteriaCC = hysteria.congestionControl
            hysteriaUploadMbpsText = String(hysteria.uploadMbps)
            hysteriaDownloadMbpsText = String(hysteria.downloadMbps)
            if let obfuscation = hysteria.obfuscation {
                hysteriaObfuscationType = obfuscation.typeTag
                hysteriaObfuscationPassword = obfuscation.password
                if case .gecko(_, let minPacketSize, let maxPacketSize) = obfuscation {
                    hysteriaObfuscationMaxText = String(maxPacketSize)
                    hysteriaObfuscationMinText = String(minPacketSize)
                }
            }
            hysteriaSNI = hysteria.serverName
        case .trojan(let trojan):
            let tls = trojan.tlsConfiguration ?? TLSConfiguration(serverName: "")
            trojanPassword = trojan.password
            trojanSNI = tls.serverName
            trojanALPN = tls.alpn?.joined(separator: ",") ?? ""
            trojanECHEnabled = tls.echEnabled
            trojanECH = tls.echConfig ?? ""
            trojanFingerprint = tls.fingerprint
        case .anytls(let anytls):
            let tls = anytls.tlsConfiguration ?? TLSConfiguration(serverName: "")
            anytlsPassword = anytls.password
            anytlsSNI = tls.serverName
            anytlsALPN = tls.alpn?.joined(separator: ",") ?? ""
            anytlsECHEnabled = tls.echEnabled
            anytlsECH = tls.echConfig ?? ""
            anytlsFingerprint = tls.fingerprint
        case .shadowsocks(let shadowsocks):
            ssPassword = shadowsocks.password
            ssMethod = shadowsocks.method
        case .socks5(let socks5):
            socks5Username = socks5.username ?? ""
            socks5Password = socks5.password ?? ""
        case .direct:
            break
        }
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        save()
    }

    private func updateSaveButton() {
        navigationItem.rightBarButtonItem?.isEnabled = isValid
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
            parsedUUID = existingConfiguration?.id ?? UUID()
        } else {
            guard let parsed = UUID(uuidString: vlessUUID) else { return }
            parsedUUID = parsed
        }

        var vlessTLSConfiguration: TLSConfiguration?
        if isVLESSTLS {
            let sni = vlessTLSSNI.isEmpty ? serverAddress : vlessTLSSNI
            let alpn: [String]? = vlessTLSALPN.isEmpty ? nil : vlessTLSALPN.split(separator: ",").map { String($0) }
            let ech = vlessTLSECH.trimmingCharacters(in: .whitespacesAndNewlines)
            vlessTLSConfiguration = TLSConfiguration(serverName: sni, alpn: alpn, echEnabled: vlessTLSECHEnabled, echConfig: vlessTLSECHEnabled && !ech.isEmpty ? ech : nil, fingerprint: vlessFingerprint)
        }

        var vlessRealityConfiguration: RealityConfiguration?
        if isVLESSReality {
            guard let publicKey = Data(base64URLEncoded: vlessRealityPublicKey) else { return }
            let shortId = Data(hexString: vlessRealityShortId) ?? Data()
            vlessRealityConfiguration = RealityConfiguration(serverName: vlessRealitySNI, publicKey: publicKey, shortId: shortId, fingerprint: vlessFingerprint)
        }

        var vlessWebSocketConfiguration: WebSocketConfiguration?
        if vlessTransport == "ws" {
            vlessWebSocketConfiguration = WebSocketConfiguration(host: vlessWebSocketHost.isEmpty ? serverAddress : vlessWebSocketHost, path: vlessWebSocketPath.isEmpty ? "/" : vlessWebSocketPath)
        }

        var vlessHTTPUpgradeConfiguration: HTTPUpgradeConfiguration?
        if vlessTransport == "httpupgrade" {
            vlessHTTPUpgradeConfiguration = HTTPUpgradeConfiguration(host: vlessHTTPUpgradeHost.isEmpty ? serverAddress : vlessHTTPUpgradeHost, path: vlessHTTPUpgradePath.isEmpty ? "/" : vlessHTTPUpgradePath)
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

        var vlessXHTTPConfiguration: XHTTPConfiguration?
        if vlessTransport == "xhttp" {
            let host = vlessXHTTPHost.isEmpty ? serverAddress : vlessXHTTPHost
            let mode = XHTTPMode(rawValue: vlessXHTTPMode) ?? .auto
            var parameters: [String: String] = ["host": host, "path": vlessXHTTPPath, "mode": mode.rawValue]
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

        let bareAddress = serverAddress.hasPrefix("[") && serverAddress.hasSuffix("]")
            ? String(serverAddress.dropFirst().dropLast()) : serverAddress

        let outbound: Outbound
        switch selectedProtocol {
        case .nowhere:
            outbound = .nowhere(NowhereConfiguration(
                key: nowhereKey,
                network: nowhereNetwork,
                morph: nowhereMorph,
                morphPrelude: nowhereMorphPrelude
            ))
        case .vless:
            let vlessXrayTransportLayer: XrayTransportLayer
            if let vlessWebSocketConfiguration { vlessXrayTransportLayer = .ws(vlessWebSocketConfiguration) }
            else if let vlessHTTPUpgradeConfiguration { vlessXrayTransportLayer = .httpUpgrade(vlessHTTPUpgradeConfiguration) }
            else if let vlessGRPCConfiguration { vlessXrayTransportLayer = .grpc(vlessGRPCConfiguration) }
            else if let vlessXHTTPConfiguration { vlessXrayTransportLayer = .xhttp(vlessXHTTPConfiguration) }
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
                    serverName: hysteriaSNI.isEmpty ? bareAddress : hysteriaSNI
                )
            )
        case .trojan:
            let sni = trojanSNI.isEmpty ? bareAddress : trojanSNI
            let alpn: [String]? = trojanALPN.isEmpty ? nil : trojanALPN.split(separator: ",").map { String($0) }
            let ech = trojanECH.trimmingCharacters(in: .whitespacesAndNewlines)
            outbound = .trojan(
                TrojanConfiguration(
                    password: trojanPassword,
                    tls: TLSConfiguration(
                        serverName: sni,
                        alpn: alpn,
                        echEnabled: trojanECHEnabled,
                        echConfig: trojanECHEnabled && !ech.isEmpty ? ech : nil,
                        fingerprint: trojanFingerprint
                    )
                )
            )
        case .anytls:
            let sni = anytlsSNI.isEmpty ? bareAddress : anytlsSNI
            let alpn: [String]? = anytlsALPN.isEmpty ? nil : anytlsALPN.split(separator: ",").map { String($0) }
            let ech = anytlsECH.trimmingCharacters(in: .whitespacesAndNewlines)
            outbound = .anytls(
                AnyTLSConfiguration(
                    password: anytlsPassword,
                    securityLayer: .tls(
                        TLSConfiguration(
                            serverName: sni,
                            alpn: alpn,
                            echEnabled: anytlsECHEnabled,
                            echConfig: anytlsECHEnabled && !ech.isEmpty ? ech : nil,
                            fingerprint: anytlsFingerprint
                        )
                    ),
                    inheritingTuningFrom: existingConfiguration?.anytls
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
            id: existingConfiguration?.id ?? UUID(),
            name: name,
            serverAddress: isDirect ? "" : bareAddress,
            serverPort: port,
            subscriptionId: existingConfiguration?.subscriptionId,
            outbound: outbound
        )

        onSave(configuration)
        dismiss(animated: true)
    }

    private func validNowherePort(_ value: String) -> UInt16? {
        guard let port = UInt16(value), port != 0 else { return nil }
        return port
    }

}
