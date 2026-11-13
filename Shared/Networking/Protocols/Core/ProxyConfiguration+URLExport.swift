//
//  ProxyConfiguration+URLExport.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation

extension ProxyConfiguration {
    private var bracketedServerAddress: String {
        serverAddress.contains(":") ? "[\(serverAddress)]" : serverAddress
    }

    private func encodedQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&#=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func encodedCredential(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func toURLString() -> String {
        switch outboundProtocol {
        case .nowhere:
            return toNowhereURLString()
        case .vless:
            return toVLESSURLString()
        case .hysteria:
            return toHysteriaURLString()
        case .trojan:
            return toTrojanURLString()
        case .anytls:
            return toAnyTLSURLString()
        case .shadowsocks:
            return toShadowsocksURLString()
        case .socks5:
            return toSOCKS5URLString()
        case .direct:
            return toDirectURLString()
        }
    }

    private func toNowhereURLString() -> String {
        guard case .nowhere(let configuration) = outbound else {
            return ""
        }
        let usernameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedKey = configuration.key.addingPercentEncoding(withAllowedCharacters: usernameCharacters) ?? ""
        let fragment = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name
        let parameters = configuration.certificatePolicy.queryParameters + ["net=\(configuration.network.rawValue)", "morph=\(configuration.morph ? 1 : 0)"]
        return "nowhere://\(encodedKey)@\(bracketedServerAddress):\(serverPort)?\(parameters.joined(separator: "&"))#\(fragment)"
    }

    private func toVLESSURLString() -> String {
        guard case .vless(let vless) = outbound else { return "" }
        var parameters: [String] = []

        if vless.encryption != "none" {
            parameters.append("encryption=\(encodedQueryValue(vless.encryption))")
        }
        if let flow = vless.flow, !flow.isEmpty {
            parameters.append("flow=\(encodedQueryValue(flow))")
        }
        parameters.append("security=\(vless.security.tag)")
        if vless.transport.tag != "tcp" {
            parameters.append("type=\(vless.transport.tag)")
        }
        
        if case .tls(let tls) = vless.security {
            parameters += tls.certificatePolicy.queryParameters
            if tls.serverName != serverAddress {
                parameters.append("sni=\(encodedQueryValue(tls.serverName))")
            }
            if let alpn = tls.alpn, !alpn.isEmpty {
                parameters.append("alpn=\(encodedQueryValue(alpn.joined(separator: ",")))")
            }
            if tls.fingerprint != .default {
                parameters.append("fp=\(tls.fingerprint.rawValue)")
            }
            if let ech = tls.echQueryValue {
                parameters.append("ech=\(ech)")
            }
        }

        if case .reality(let reality) = vless.security {
            parameters.append("sni=\(encodedQueryValue(reality.serverName))")
            parameters.append("pbk=\(reality.publicKey.base64URLEncodedString())")
            if !reality.shortId.isEmpty {
                parameters.append("sid=\(reality.shortId.hexEncodedString())")
            }
            if reality.fingerprint != .default {
                parameters.append("fp=\(reality.fingerprint.rawValue)")
            }
        }
        
        appendTransportParams(to: &parameters)

        let query = parameters.isEmpty ? "" : "?\(parameters.joined(separator: "&"))"
        let fragment = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name
        return "vless://\(vless.uuid.uuidString.lowercased())@\(bracketedServerAddress):\(serverPort)/\(query)#\(fragment)"
    }
    
    private func appendTransportParams(to params: inout [String]) {
        switch xrayTransportLayer {
        case .ws(let ws):
            if ws.host != serverAddress {
                params.append("host=\(encodedQueryValue(ws.host))")
            }
            if ws.path != "/" {
                params.append("path=\(encodedQueryValue(ws.path))")
            }
            if ws.maxEarlyData > 0 {
                params.append("ed=\(ws.maxEarlyData)")
            }
        case .httpUpgrade(let hu):
            if hu.host != serverAddress {
                params.append("host=\(encodedQueryValue(hu.host))")
            }
            if hu.path != "/" {
                params.append("path=\(encodedQueryValue(hu.path))")
            }
        case .grpc(let grpc):
            if !grpc.serviceName.isEmpty {
                let encoded = encodedQueryValue(grpc.serviceName)
                params.append("serviceName=\(encoded)")
            }
            if !grpc.authority.isEmpty {
                let encoded = encodedQueryValue(grpc.authority)
                params.append("authority=\(encoded)")
            }
            if grpc.multiMode {
                params.append("mode=multi")
            }
        case .xhttp(let xhttp):
            if xhttp.host != serverAddress {
                params.append("host=\(encodedQueryValue(xhttp.host))")
            }
            if xhttp.path != "/" {
                params.append("path=\(encodedQueryValue(xhttp.path))")
            }
            if xhttp.mode != .auto {
                params.append("mode=\(xhttp.mode.rawValue)")
            }
            if let extra = xhttp.urlExtraParam {
                params.append("extra=\(extra)")
            }
        case .raw:
            break
        }
    }
    
    private func toHysteriaURLString() -> String {
        guard case .hysteria(let configuration) = outbound else {
            return ""
        }
        let encodedPassword = encodedCredential(configuration.password)
        let fragment = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name
        var parameters: [String] = []
        if configuration.congestionControl == .brutal {
            parameters.append("upmbps=\(configuration.uploadMbps)")
            parameters.append("downmbps=\(configuration.downloadMbps)")
        }
        if let obfuscation = configuration.obfuscation {
            parameters.append("obfs=\(obfuscation.typeTag)")
            parameters.append("obfs-password=\(encodedQueryValue(obfuscation.password))")
            if case .gecko(_, let minPacketSize, let maxPacketSize) = obfuscation {
                parameters.append("obfs-min-packet-size=\(minPacketSize)")
                parameters.append("obfs-max-packet-size=\(maxPacketSize)")
            }
        }
        parameters += configuration.certificatePolicy.queryParameters
        if configuration.serverName != serverAddress {
            parameters.append("sni=\(encodedQueryValue(configuration.serverName))")
        }
        let query = parameters.isEmpty ? "" : "?\(parameters.joined(separator: "&"))"
        return "hysteria2://\(encodedPassword)@\(bracketedServerAddress):\(serverPort)/\(query)#\(fragment)"
    }
    
    private func toTrojanURLString() -> String {
        guard case .trojan(let configuration) = outbound,
              let tls = configuration.tlsConfiguration else { return "" }
        let encodedPassword = encodedCredential(configuration.password)
        let fragment = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name
        var parameters: [String] = []
        parameters += tls.certificatePolicy.queryParameters
        if tls.serverName != serverAddress {
            parameters.append("sni=\(encodedQueryValue(tls.serverName))")
        }
        if let alpn = tls.alpn, !alpn.isEmpty {
            let joined = alpn.joined(separator: ",")
            parameters.append("alpn=\(encodedQueryValue(joined))")
        }
        if tls.fingerprint != .default {
            parameters.append("fp=\(tls.fingerprint.rawValue)")
        }
        if let ech = tls.echQueryValue {
            parameters.append("ech=\(ech)")
        }
        let query = parameters.isEmpty ? "" : "?\(parameters.joined(separator: "&"))"
        return "trojan://\(encodedPassword)@\(bracketedServerAddress):\(serverPort)\(query)#\(fragment)"
    }

    private func toAnyTLSURLString() -> String {
        guard case .anytls(let configuration) = outbound,
              let tls = configuration.tlsConfiguration else { return "" }
        let encodedPassword = encodedCredential(configuration.password)
        let fragment = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name
        var parameters: [String] = []
        parameters += tls.certificatePolicy.queryParameters
        if tls.serverName != serverAddress {
            parameters.append("sni=\(encodedQueryValue(tls.serverName))")
        }
        if let alpn = tls.alpn, !alpn.isEmpty {
            let joined = alpn.joined(separator: ",")
            parameters.append("alpn=\(encodedQueryValue(joined))")
        }
        if tls.fingerprint != .default {
            parameters.append("fp=\(tls.fingerprint.rawValue)")
        }
        if let ech = tls.echQueryValue {
            parameters.append("ech=\(ech)")
        }
        if configuration.idleCheckInterval != AnyTLSConfiguration.defaultIdleCheckInterval {
            parameters.append("ici=\(configuration.idleCheckInterval)")
        }
        if configuration.idleTimeout != AnyTLSConfiguration.defaultIdleTimeout {
            parameters.append("it=\(configuration.idleTimeout)")
        }
        if configuration.minIdleSession != AnyTLSConfiguration.defaultMinIdleSession {
            parameters.append("mis=\(configuration.minIdleSession)")
        }
        let query = parameters.isEmpty ? "" : "?\(parameters.joined(separator: "&"))"
        return "anytls://\(encodedPassword)@\(bracketedServerAddress):\(serverPort)\(query)#\(fragment)"
    }

    private func toShadowsocksURLString() -> String {
        guard case .shadowsocks(let configuration) = outbound else {
            return "ss://invalid"
        }
        let userInfo = "\(configuration.method):\(configuration.password)"
        let encoded = Data(userInfo.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        
        let fragment = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name
        return "ss://\(encoded)@\(bracketedServerAddress):\(serverPort)/#\(fragment)"
    }

    private func toDirectURLString() -> String {
        let fragment = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name
        return "direct://#\(fragment)"
    }

    private func toSOCKS5URLString() -> String {
        let fragment = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name
        if case .socks5(let configuration) = outbound, let user = configuration.username, !user.isEmpty {
            let encodedUser = encodedCredential(user)
            let encodedPass = encodedCredential(configuration.password ?? "")
            return "socks5://\(encodedUser):\(encodedPass)@\(bracketedServerAddress):\(serverPort)#\(fragment)"
        }
        return "socks5://\(bracketedServerAddress):\(serverPort)#\(fragment)"
    }
    
}
