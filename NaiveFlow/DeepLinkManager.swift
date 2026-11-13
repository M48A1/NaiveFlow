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
    func handle(url: URL) {
        switch url.scheme?.lowercased() {
        case "naiveflow":
            handleNaiveFlowScheme(url)
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
        default:
            break
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
