//
//  ProxyConfiguration+URLParsing.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation

nonisolated extension ProxyConfiguration {
    static let parsableURLPrefixes = ["nowhere://", "vless://", "hysteria2://", "hy2://", "trojan://", "anytls://", "ss://", "socks5://", "socks://", "direct://"]
    static let subscriptionOnlyURLPrefixes = ["https://", "http://"]
    static let subscriptionEntryPrefixes = parsableURLPrefixes + subscriptionOnlyURLPrefixes

    static func canParseURL(_ string: String) -> Bool {
        parsableURLPrefixes.contains { string.hasPrefix($0) }
    }

    static func canParseSubscriptionEntry(_ string: String) -> Bool {
        subscriptionEntryPrefixes.contains { string.hasPrefix($0) }
    }
    
    static func parseSubscriptionEntry(url: String) throws -> ProxyConfiguration {
        guard subscriptionOnlyURLPrefixes.contains(where: { url.hasPrefix($0) }) else {
            return try parse(url: url)
        }
        throw NaiveFlowError.parse(.invalidURL("HTTP proxy URL import is not supported."))
    }
    
    static func parse(url: String) throws -> ProxyConfiguration {
        var transportURL = url
        var blockQUIC: Bool?
        var underlyingProxy: String?
        let fragments = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let beforeFragment = fragments[0]
        if let query = beforeFragment.firstIndex(of: "?") {
            let fields = beforeFragment[beforeFragment.index(after: query)...].split(separator: "&", omittingEmptySubsequences: false)
            let parsedFields = fields.map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false) }
            let preferences = parsedFields.filter { $0.first == "block-quic" }
            if !preferences.isEmpty {
                guard preferences.count == 1, preferences[0].count == 2,
                      ["true", "false", "1", "0"].contains(String(preferences[0][1]).lowercased()) else {
                    throw NaiveFlowError.parse(.invalidURL("Invalid block-quic parameter"))
                }
                blockQUIC = ["true", "1"].contains(String(preferences[0][1]).lowercased())
            }
            let parents = parsedFields.filter { $0.first == "underlying-proxy" }
            if !parents.isEmpty {
                guard parents.count == 1, parents[0].count == 2,
                      let value = String(parents[0][1]).removingPercentEncoding,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !value.contains(where: { $0.isNewline }) else {
                    throw NaiveFlowError.parse(.invalidURL("Invalid underlying-proxy parameter"))
                }
                underlyingProxy = value
            }
            if !preferences.isEmpty || !parents.isEmpty {
                let remaining = fields.filter {
                    let key = $0.split(separator: "=", maxSplits: 1).first
                    return key != "block-quic" && key != "underlying-proxy"
                }
                transportURL = String(beforeFragment[..<query])
                    + (remaining.isEmpty ? "" : "?" + remaining.joined(separator: "&"))
                    + (fragments.count > 1 ? "#" + fragments[1] : "")
            }
        }
        var node = try parseSupportedURL(url: transportURL)
        node.blockQUIC = blockQUIC
        node.underlyingProxy = underlyingProxy
        if !node.isDirect { try IPv4Only.requireHost(node.serverAddress) }
        return node
    }

    private static func parseSupportedURL(url: String) throws -> ProxyConfiguration {
        if url.hasPrefix("nowhere://") {
            return try parseNowhere(url: url)
        }
        if url.hasPrefix("vless://") {
            return try parseVLESS(url: url)
        }
        if url.hasPrefix("hysteria2://") || url.hasPrefix("hy2://") {
            return try parseHysteria(url: url)
        }
        if url.hasPrefix("trojan://") {
            return try parseTrojan(url: url)
        }
        if url.hasPrefix("anytls://") {
            return try parseAnyTLS(url: url)
        }
        if url.hasPrefix("ss://") {
            return try parseShadowsocks(url: url)
        }
        if url.hasPrefix("socks5://") || url.hasPrefix("socks://") {
            return try parseSOCKS5(url: url)
        }
        if url.hasPrefix("direct://") {
            return try parseDirect(url: url)
        }
        throw NaiveFlowError.parse(.invalidURL("Unsupported proxy URL scheme. Supported schemes are nowhere://, vless://, hysteria2://, trojan://, anytls://, ss://, socks5://, and direct://."))
    }

    // MARK: - Per-Scheme Parsers
    
    private static func parseNowhere(url: String) throws -> ProxyConfiguration {
        var remaining = String(url.dropFirst("nowhere://".count))
        var fragment = extractFragment(&remaining)
        DeviceCensorship.deCensor(&fragment)
        var queryString: String?
        if let questionIndex = remaining.firstIndex(of: "?") {
            queryString = String(remaining[remaining.index(after: questionIndex)...])
            remaining = String(remaining[..<questionIndex])
        }
        if let queryString {
            let validatedKeys: Set<String> = ["net", "morph"]
            var seenKeys = Set<String>()
            for parameter in queryString.split(separator: "&", omittingEmptySubsequences: false) {
                let keyValue = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(keyValue[0])
                guard validatedKeys.contains(key), seenKeys.insert(key).inserted else { continue }
                guard keyValue.count == 2 else {
                    throw NaiveFlowError.parse(.invalidURL("Invalid Nowhere \(key) parameter"))
                }
            }
        }
        let parameters = parseQueryParams(queryString, keepFirst: true)
        guard let atIndex = remaining.lastIndex(of: "@") else {
            throw NaiveFlowError.parse(.invalidURL("Missing @ separator in Nowhere URL"))
        }
        let userInfo = String(remaining[..<atIndex])
        let endpoint = String(remaining[remaining.index(after: atIndex)...])
        guard !userInfo.contains(":"), let key = userInfo.removingPercentEncoding else {
            throw NaiveFlowError.parse(.invalidURL("Invalid Nowhere key encoding"))
        }
        guard !key.isEmpty else {
            throw NaiveFlowError.parse(.invalidURL("Missing Nowhere key"))
        }

        guard !endpoint.contains("/") else {
            throw NaiveFlowError.parse(.invalidURL("Invalid Nowhere endpoint"))
        }
        let (host, port) = try parseHostPort(endpoint)
        guard !host.isEmpty, port != 0 else {
            throw NaiveFlowError.parse(.invalidURL("Invalid Nowhere endpoint"))
        }
        let network: NowhereNetwork
        if let rawNetwork = parameters["net"] {
            guard let parsed = NowhereNetwork(rawValue: rawNetwork) else {
                throw NaiveFlowError.parse(.invalidURL("Invalid Nowhere net value"))
            }
            network = parsed
        } else {
            network = .tcp
        }
        let morph: Bool
        switch parameters["morph"] {
        case nil, "1": morph = true
        case "0": morph = false
        default: throw NaiveFlowError.parse(.invalidURL("Invalid Nowhere morph value"))
        }

        return ProxyConfiguration(
            name: fragment ?? "Nowhere",
            serverAddress: host,
            serverPort: port,
            outbound: .nowhere(
                NowhereConfiguration(
                    key: key,
                    network: network,
                    morph: morph,
                    certificatePolicy: TLSCertificatePolicy(insecureSkipVerify: TLSCertificatePolicy.skipVerification(in: parameters), certificateSHA256: try TLSCertificatePolicy.fingerprint(in: parameters))
                )
            )
        )
    }
    
    private static func parseVLESS(url: String) throws -> ProxyConfiguration {
        let body = try splitLinkBody(url, scheme: "vless://", label: "vless", allowBase64Body: true)

        guard let uuid = UUID(uuidString: body.userInfo) else {
            throw NaiveFlowError.parse(.invalidURL("Invalid UUID: \(body.userInfo)"))
        }

        let parameters = body.parameters
        let encryption = parameters["encryption"] ?? "none"
        let flow = parameters["flow"]
        let security = parameters["security"] ?? "none"
        let transportStr = parameters["type"] ?? "tcp"

        let xraySecurityLayer: XraySecurityLayer
        if security == "reality" {
            do {
                if let realityConfig = try RealityConfiguration.parse(from: parameters) {
                    xraySecurityLayer = .reality(realityConfig)
                } else {
                    xraySecurityLayer = .none
                }
            } catch {
                throw NaiveFlowError.parse(.invalidURL("Reality configuration error: \(error.localizedDescription)"))
            }
        } else if security == "tls" {
            do {
                if let tlsConfig = try TLSConfiguration.parse(from: parameters, serverAddress: body.host) {
                    xraySecurityLayer = .tls(tlsConfig)
                } else {
                    xraySecurityLayer = .none
                }
            } catch {
                throw NaiveFlowError.parse(.invalidURL("TLS configuration error: \(error.localizedDescription)"))
            }
        } else {
            xraySecurityLayer = .none
        }

        let xrayTransportLayer = parseXrayTransportLayer(from: parameters, transport: transportStr, serverAddress: body.host, xraySecurityLayer: xraySecurityLayer)

        return ProxyConfiguration(
            name: body.fragment ?? "Untitled",
            serverAddress: body.host,
            serverPort: body.port,
            outbound: .vless(
                VLESSConfiguration(
                    uuid: uuid,
                    encryption: encryption,
                    flow: flow,
                    transport: xrayTransportLayer,
                    security: xraySecurityLayer
                )
            )
        )
    }
    
    private static func parseHysteria(url: String) throws -> ProxyConfiguration {
        let scheme = url.hasPrefix("hysteria2://") ? "hysteria2://" : "hy2://"
        let body = try splitLinkBody(url, scheme: scheme, label: "hysteria")
        let parameters = body.parameters

        let password = body.userInfo.removingPercentEncoding ?? body.userInfo
        let sni = (parameters["sni"]?.isEmpty == false) ? parameters["sni"]! : body.host
        
        let rawUp = parameters["upmbps"].flatMap { Int($0) }
        let rawDown = parameters["downmbps"].flatMap { Int($0) }
        let congestionControl: HysteriaCongestionControl = (rawUp != nil || rawDown != nil) ? .brutal : .bbr

        let obfuscation: HysteriaObfuscation?
        if let obfsType = parameters["obfs"], !obfsType.isEmpty {
            let obfsMin = parameters["obfs-min-packet-size"].flatMap { Int($0) }
            let obfsMax = parameters["obfs-max-packet-size"].flatMap { Int($0) }
            guard let parsed = HysteriaObfuscation.make(type: obfsType, password: parameters["obfs-password"],
                                                        geckoMinPacketSize: obfsMin, geckoMaxPacketSize: obfsMax) else {
                throw NaiveFlowError.parse(.invalidURL("Unsupported Hysteria obfs type: \(obfsType)"))
            }
            obfuscation = parsed
        } else {
            obfuscation = nil
        }

        return ProxyConfiguration(
            name: body.fragment ?? "Untitled",
            serverAddress: body.host,
            serverPort: body.port,
            outbound: .hysteria(
                HysteriaConfiguration(
                    password: password,
                    congestionControl: congestionControl,
                    uploadMbps: rawUp ?? HysteriaCongestionControl.uploadMbpsDefault,
                    downloadMbps: rawDown ?? HysteriaCongestionControl.downloadMbpsDefault,
                    obfuscation: obfuscation,
                    serverName: sni,
                    certificatePolicy: TLSCertificatePolicy(insecureSkipVerify: TLSCertificatePolicy.skipVerification(in: parameters), certificateSHA256: try TLSCertificatePolicy.fingerprint(in: parameters))
                )
            )
        )
    }
    
    private static func parseTrojan(url: String) throws -> ProxyConfiguration {
        let body = try splitLinkBody(url, scheme: "trojan://", label: "trojan")
        
        let password = body.userInfo.removingPercentEncoding ?? body.userInfo
        let tlsConfiguration = try standardTLSConfiguration(from: body.parameters, host: body.host)

        return ProxyConfiguration(
            name: body.fragment ?? "Untitled",
            serverAddress: body.host,
            serverPort: body.port,
            outbound: .trojan(TrojanConfiguration(password: password, tls: tlsConfiguration))
        )
    }
    
    private static func parseAnyTLS(url: String) throws -> ProxyConfiguration {
        let body = try splitLinkBody(url, scheme: "anytls://", label: "anytls")
        let parameters = body.parameters

        let password = body.userInfo.removingPercentEncoding ?? body.userInfo
        let tlsConfiguration = try standardTLSConfiguration(from: parameters, host: body.host)

        return ProxyConfiguration(
            name: body.fragment ?? "Untitled",
            serverAddress: body.host,
            serverPort: body.port,
            outbound: .anytls(
                AnyTLSConfiguration(
                    password: password,
                    idleCheckInterval: parameters["ici"].flatMap { Int($0) } ?? AnyTLSConfiguration.defaultIdleCheckInterval,
                    idleTimeout: parameters["it"].flatMap { Int($0) } ?? AnyTLSConfiguration.defaultIdleTimeout,
                    minIdleSession: parameters["mis"].flatMap { Int($0) } ?? AnyTLSConfiguration.defaultMinIdleSession,
                    securityLayer: .tls(tlsConfiguration)
                )
            )
        )
    }

    private static func parseShadowsocks(url: String) throws -> ProxyConfiguration {
        var urlWithoutScheme = String(url.dropFirst("ss://".count))
        let fragmentName = extractFragment(&urlWithoutScheme)

        let method: String
        let password: String
        let host: String
        let port: UInt16

        if let atIndex = urlWithoutScheme.lastIndex(of: "@") {
            let userInfo = String(urlWithoutScheme[..<atIndex])
            var serverPart = String(urlWithoutScheme[urlWithoutScheme.index(after: atIndex)...])
            
            if let questionIndex = serverPart.firstIndex(of: "?") {
                serverPart = String(serverPart[..<questionIndex])
            }
            if let slashIndex = serverPart.firstIndex(of: "/") {
                serverPart = String(serverPart[..<slashIndex])
            }

            (method, password) = try decodeShadowsocksUserInfo(userInfo)
            (host, port) = try parseHostPort(serverPart)
        } else {
            guard let decoded = Data(base64URLEncoded: urlWithoutScheme),
                  let decodedString = String(data: decoded, encoding: .utf8) else {
                throw NaiveFlowError.parse(.invalidURL("Invalid SS URL encoding"))
            }
            guard let colonIndex = decodedString.firstIndex(of: ":") else {
                throw NaiveFlowError.parse(.invalidURL("Missing method:password separator"))
            }
            method = String(decodedString[..<colonIndex])
            let rest = String(decodedString[decodedString.index(after: colonIndex)...])
            guard let atIndex = rest.lastIndex(of: "@") else {
                throw NaiveFlowError.parse(.invalidURL("Missing @ separator in decoded SS URL"))
            }
            password = String(rest[..<atIndex])
            let serverPart = String(rest[rest.index(after: atIndex)...])
            (host, port) = try parseHostPort(serverPart)
        }

        guard ShadowsocksCipher(method: method) != nil else {
            throw NaiveFlowError.parse(.invalidURL("Unsupported SS method: \(method)"))
        }

        return ProxyConfiguration(
            name: fragmentName ?? "Untitled",
            serverAddress: host,
            serverPort: port,
            outbound: .shadowsocks(ShadowsocksConfiguration(password: password, method: method))
        )
    }
    
    private static func decodeShadowsocksUserInfo(_ userInfo: String) throws -> (method: String, password: String) {
        if let colonIndex = userInfo.firstIndex(of: ":") {
            let method = String(userInfo[..<colonIndex])
            let rawPassword = String(userInfo[userInfo.index(after: colonIndex)...])
            return (method, rawPassword.removingPercentEncoding ?? rawPassword)
        }
        guard let decoded = Data(base64URLEncoded: userInfo),
              let decodedString = String(data: decoded, encoding: .utf8),
              let colonIndex = decodedString.firstIndex(of: ":") else {
            throw NaiveFlowError.parse(.invalidURL("Invalid SS user info encoding"))
        }
        let method = String(decodedString[..<colonIndex])
        let password = String(decodedString[decodedString.index(after: colonIndex)...])
        return (method, password)
    }

    private static func parseDirect(url: String) throws -> ProxyConfiguration {
        var remaining = String(url.dropFirst("direct://".count))
        let fragmentName = extractFragment(&remaining)
        return ProxyConfiguration(
            name: fragmentName ?? "Direct",
            serverAddress: "",
            serverPort: 0,
            outbound: .direct(DirectConfiguration())
        )
    }

    private static func parseSOCKS5(url: String) throws -> ProxyConfiguration {
        let urlWithoutScheme: String
        if url.hasPrefix("socks5://") {
            urlWithoutScheme = String(url.dropFirst("socks5://".count))
        } else if url.hasPrefix("socks://") {
            urlWithoutScheme = String(url.dropFirst("socks://".count))
        } else {
            throw NaiveFlowError.parse(.invalidURL("SOCKS5 URL must start with socks5:// or socks://"))
        }

        var remaining = urlWithoutScheme
        let fragmentName = extractFragment(&remaining)

        let username: String?
        let password: String?
        let serverPart: String

        if let atIndex = remaining.lastIndex(of: "@") {
            let userInfo = String(remaining[..<atIndex])
            serverPart = String(remaining[remaining.index(after: atIndex)...])

            if let colonIndex = userInfo.firstIndex(of: ":") {
                username = String(userInfo[..<colonIndex]).removingPercentEncoding ?? String(userInfo[..<colonIndex])
                password = String(userInfo[userInfo.index(after: colonIndex)...]).removingPercentEncoding ?? String(userInfo[userInfo.index(after: colonIndex)...])
            } else {
                username = userInfo.removingPercentEncoding ?? userInfo
                password = nil
            }
        } else {
            username = nil
            password = nil
            if let slashIndex = remaining.firstIndex(of: "/") {
                serverPart = String(remaining[..<slashIndex])
            } else {
                serverPart = remaining
            }
        }

        let (host, port) = try parseHostPort(serverPart)

        return ProxyConfiguration(
            name: fragmentName ?? "Untitled",
            serverAddress: host,
            serverPort: port,
            outbound: .socks5(SOCKS5Configuration(username: username, password: password))
        )
    }

    // MARK: - Shared Link Decomposition
    
    private struct LinkBody {
        let userInfo: String
        let host: String
        let port: UInt16
        let parameters: [String: String]
        let firstParameters: [String: String]
        let fragment: String?
    }
    
    private static func splitLinkBody(
        _ url: String,
        scheme: String,
        label: String,
        allowBase64Body: Bool = false
    ) throws -> LinkBody {
        var remaining = String(url.dropFirst(scheme.count))

        var fragment = extractFragment(&remaining)
        
        if allowBase64Body, !remaining.contains("@"),
           let decoded = base64DecodedBody(remaining), decoded.contains("@") {
            remaining = decoded
            if fragment == nil { fragment = extractFragment(&remaining) }
        }
        DeviceCensorship.deCensor(&fragment)

        var queryString: String?
        if let questionIndex = remaining.firstIndex(of: "?") {
            queryString = String(remaining[remaining.index(after: questionIndex)...])
            remaining = String(remaining[..<questionIndex])
        }

        guard let atIndex = remaining.lastIndex(of: "@") else {
            throw NaiveFlowError.parse(.invalidURL("Missing @ separator in \(label) URL"))
        }
        let userInfo = String(remaining[..<atIndex])
        var serverPart = String(remaining[remaining.index(after: atIndex)...])
        if serverPart.hasSuffix("/") { serverPart.removeLast() }
        if let slashIndex = serverPart.firstIndex(of: "/") {
            serverPart = String(serverPart[..<slashIndex])
        }

        let (host, port) = try parseHostPort(serverPart)
        return LinkBody(
            userInfo: userInfo,
            host: host,
            port: port,
            parameters: parseQueryParams(queryString),
            firstParameters: parseQueryParams(queryString, keepFirst: true),
            fragment: fragment
        )
    }
    
    private static func extractFragment(_ remaining: inout String) -> String? {
        guard let hashIndex = remaining.lastIndex(of: "#") else { return nil }
        let fragment = String(remaining[remaining.index(after: hashIndex)...]).removingPercentEncoding
        remaining = String(remaining[..<hashIndex])
        return fragment
    }
    
    private static func base64DecodedBody(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = Data(base64URLEncoded: trimmed),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    // MARK: - Parsing Helpers
    
    private static func resolvedServerName(from parameters: [String: String], host: String) -> String {
        if let sni = parameters["sni"], !sni.isEmpty { return sni }
        if let peer = parameters["peer"], !peer.isEmpty { return peer }
        return host
    }
    
    private static func standardTLSConfiguration(from parameters: [String: String], host: String) throws -> TLSConfiguration {
        let serverName = resolvedServerName(from: parameters, host: host)
        var alpn: [String]? = nil
        if let alpnString = parameters["alpn"], !alpnString.isEmpty {
            alpn = alpnString.split(separator: ",").map { String($0) }
        }
        let fingerprint = parameters["fp"].flatMap { TLSFingerprint(importValue: $0) } ?? .default
        let ech = TLSConfiguration.echSettings(fromQueryValue: parameters["ech"])
        return TLSConfiguration(serverName: serverName, alpn: alpn, echEnabled: ech.enabled, echConfig: ech.config, fingerprint: fingerprint, insecureSkipVerify: TLSCertificatePolicy.skipVerification(in: parameters), serverCertificateFingerprint: try TLSCertificatePolicy.fingerprint(in: parameters))
    }

    static func parseQueryParams(_ queryString: String?, keepFirst: Bool = false) -> [String: String] {
        guard let queryString else { return [:] }
        var parameters: [String: String] = [:]
        for parameter in queryString.split(separator: "&") {
            let keyValue = parameter.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            if keyValue.count == 2 {
                let key = String(keyValue[0])
                let value = String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1])
                if !keepFirst || parameters[key] == nil { parameters[key] = value }
            }
        }
        return parameters
    }

    private static func parseXrayTransportLayer(
        from params: [String: String],
        transport: String,
        serverAddress: String,
        xraySecurityLayer: XraySecurityLayer
    ) -> XrayTransportLayer {
        switch transport {
        case "ws":
            if let configuration = WebSocketConfiguration.parse(from: params, serverAddress: serverAddress) {
                return .ws(configuration)
            }
            return .raw
        case "httpupgrade":
            if let configuration = HTTPUpgradeConfiguration.parse(from: params, serverAddress: serverAddress) {
                return .httpUpgrade(configuration)
            }
            return .raw
        case "grpc":
            if let configuration = GRPCConfiguration.parse(from: params) {
                return .grpc(configuration)
            }
            return .raw
        case "xhttp":
            let tlsServerName: String?
            if case .tls(let tls) = xraySecurityLayer { tlsServerName = tls.serverName }
            else { tlsServerName = nil }
            let realityServerName: String?
            if case .reality(let reality) = xraySecurityLayer { realityServerName = reality.serverName }
            else { realityServerName = nil }
            if let configuration = XHTTPConfiguration.parse(from: params, serverAddress: serverAddress, tlsServerName: tlsServerName, realityServerName: realityServerName) {
                return .xhttp(configuration)
            }
            return .raw
        default:
            return .raw
        }
    }

    static func padBase64(_ string: String) -> String {
        let remainder = string.count % 4
        if remainder == 0 { return string }
        return string + String(repeating: "=", count: 4 - remainder)
    }
    
    static func parseHostPort(_ string: String, defaultPort: UInt16? = nil) throws -> (String, UInt16) {
        let host: String
        let portString: String?
        if string.hasPrefix("[") {
            guard let closeBracket = string.firstIndex(of: "]") else {
                throw NaiveFlowError.parse(.invalidURL("Unsupported bracketed address"))
            }
            host = String(string[string.index(after: string.startIndex)..<closeBracket])
            let afterBracket = string[string.index(after: closeBracket)...]
            if afterBracket.hasPrefix(":") {
                portString = String(afterBracket.dropFirst())
            } else {
                guard afterBracket.isEmpty, defaultPort != nil else {
                    throw NaiveFlowError.parse(.invalidURL("Unsupported bracketed address"))
                }
                portString = nil
            }
        } else if let colonIndex = string.lastIndex(of: ":") {
            host = String(string[..<colonIndex])
            portString = String(string[string.index(after: colonIndex)...])
        } else {
            host = string
            portString = nil
        }
        guard !host.isEmpty else {
            throw NaiveFlowError.parse(.invalidURL("Missing host"))
        }
        guard let portString else {
            guard let defaultPort else {
                throw NaiveFlowError.parse(.invalidURL("Missing port"))
            }
            return (host, defaultPort)
        }
        guard let port = UInt16(portString) else {
            throw NaiveFlowError.parse(.invalidURL("Invalid port: \(portString)"))
        }
        return (host, port)
    }
}
