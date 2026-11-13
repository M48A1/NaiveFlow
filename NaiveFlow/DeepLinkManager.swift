//
//  DeepLinkManager.swift
//  NaiveFlow
//
//  Created by NodePassProject on 4/24/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class DeepLinkManager {
    var url: String?
    var ruleSetLink: URL?
    struct ModuleImport: Equatable {
        let link: URL
        let format: ModuleFormat?
    }

    var moduleImport: ModuleImport?

    func handle(url: URL) {
        switch url.scheme?.lowercased() {
        case "naiveflow":
            handleNaiveFlowScheme(url)
        case "surge", "quantumult-x":
            if let request = Self.foreignModuleImport(from: url) {
                moduleImport = request
            }
        case "nowhere", "vless", "hysteria2", "hy2", "trojan", "anytls", "ss":
            self.url = url.absoluteString
        default:
            break
        }
    }

    private func handleNaiveFlowScheme(_ url: URL) {
        guard let link = Self.extractLink(from: url.absoluteString) else { return }
        switch url.host?.lowercased() {
        case "add-proxy":
            self.url = link
        case "add-rule-set":
            ruleSetLink = URL(string: link)
        case "add-module":
            if let url = URL(string: link) { moduleImport = ModuleImport(link: url, format: nil) }
        default:
            break
        }
    }

    private static func foreignModuleImport(from url: URL) -> ModuleImport? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.isEmpty != false else { return nil }
        let parameters = components.queryItems ?? []
        let link: String
        let format: ModuleFormat
        switch (components.scheme?.lowercased(), components.path) {
        case ("surge", "/install-module"):
            guard let value = parameters.first(where: { $0.name == "url" })?.value else { return nil }
            link = value
            format = .surge
        case ("quantumult-x", "/add-resource"):
            guard let value = parameters.first(where: { $0.name == "remote-resource" })?.value,
                  let resources = try? JSONDecoder().decode(QuantumultResources.self, from: Data(value.utf8)),
                  resources.rewriteRemote.count == 1,
                  let rewrite = resources.rewriteRemote.first else { return nil }
            link = rewrite
            format = .quantumultX
        default:
            return nil
        }
        guard let subscription = Module.validSubscriptionURL(from: link) else { return nil }
        return ModuleImport(link: subscription, format: format)
    }

    private struct QuantumultResources: Decodable {
        let rewriteRemote: [String]

        enum CodingKeys: String, CodingKey {
            case rewriteRemote = "rewrite_remote"
        }
    }

    nonisolated static func extractAddProxyLink(from string: String) -> String? {
        guard string.lowercased().hasPrefix("naiveflow://add-proxy") else { return nil }
        return extractLink(from: string)
    }

    /// Every `naiveflow://` deep link carries exactly one link: everything after
    /// `?link=`, taken verbatim, so the inner URL needs no percent-encoding.
    private nonisolated static func extractLink(from string: String) -> String? {
        guard let range = string.range(of: "?link=") else { return nil }
        let rawLink = String(string[range.upperBound...])
        guard !rawLink.isEmpty else { return nil }
        // A raw inner URL owns its own escapes. Decode only when the entire
        // URL was encoded as an outer query value (e.g. https%3A%2F%2F...).
        if URL(string: rawLink)?.scheme != nil { return rawLink }
        guard let decoded = rawLink.removingPercentEncoding,
              URL(string: decoded)?.scheme != nil else { return nil }
        return decoded
    }
}
