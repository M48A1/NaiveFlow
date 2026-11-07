//
//  UpgradeHandshakeResponse.swift
//  NaiveFlow
//

import Foundation

/// Parsed HTTP response head from a protocol upgrade handshake (`WebSocket`,
/// `HTTPUpgrade`). Field names are lowercased and repeated fields are joined with
/// `", "` so token lookups see every value the server sent.
nonisolated struct UpgradeHandshakeResponse: Sendable {
    /// Raw status line, e.g. `HTTP/1.1 101 Switching Protocols`.
    let statusLine: String

    /// Numeric status code parsed from `statusLine`.
    let statusCode: Int

    /// Lowercased field names mapped to comma-joined values.
    let fields: [String: String]

    /// Parses an HTTP response head. Returns `nil` when the block is empty or its
    /// status line is not `HTTP/<version> <code> ...`.
    init?(headerString: String) {
        let lines = headerString
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
        guard let statusLine = lines.first else { return nil }

        // Parse the code as an integer: a reason phrase such as "401 error101"
        // must not satisfy a `contains("101")` style check.
        let parts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let statusCode = Int(parts[1]) else {
            return nil
        }

        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name] = fields[name].map { "\($0), \(value)" } ?? value
        }

        self.statusLine = statusLine
        self.statusCode = statusCode
        self.fields = fields
    }

    /// Value of `field` (case-insensitive), or `nil` when absent.
    func value(_ field: String) -> String? {
        fields[field.lowercased()]
    }

    /// Whether the comma-separated `field` contains `token` (case-insensitive).
    /// `Connection: keep-alive, Upgrade` therefore matches `upgrade`.
    func containsToken(_ token: String, in field: String) -> Bool {
        guard let value = value(field) else { return false }
        let wanted = token.lowercased()
        return value
            .split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
    }
}
