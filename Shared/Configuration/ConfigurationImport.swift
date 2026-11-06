//
//  ConfigurationImport.swift
//  RuleProxy
//
//  Created by NodePassProject on 11/4/26.
//

import Foundation

/// Reads a text profile from disk for the editor.
///
/// Import is deliberately strict about encoding and size: a partially decoded or
/// truncated profile would create diagnostics that point at the wrong line, so an
/// unreadable file is rejected instead of being best-effort decoded.
nonisolated enum ConfigurationImport {

    enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case unsupportedEncoding
        case empty
        case tooLarge(bytes: Int)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                return "The configuration file could not be read: \(detail)"
            case .unsupportedEncoding:
                return "The configuration file is not valid UTF-8. Re-save it as UTF-8 and import again."
            case .empty:
                return "The configuration file is empty."
            case .tooLarge(let bytes):
                return "The configuration file is \(bytes) bytes, larger than the \(ConfigurationImport.maximumBytes) byte limit."
            }
        }
    }

    /// Larger profiles are almost always generated files or a wrong pick; the
    /// editor would stall long before the engine had an opinion.
    static let maximumBytes = 16 * 1024 * 1024

    static func read(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var bounded = Data()
            while bounded.count <= maximumBytes {
                let count = min(65_536, maximumBytes + 1 - bounded.count)
                guard let chunk = try file.read(upToCount: count), !chunk.isEmpty else { break }
                bounded.append(chunk)
            }
            data = bounded
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= maximumBytes else { throw Failure.tooLarge(bytes: data.count) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure.unsupportedEncoding
        }
        return normalize(text)
    }

    /// Removes a byte-order mark, CRLF line endings and trailing NUL padding, all
    /// of which would otherwise show up as a diagnostic on line 1.
    static func normalize(_ text: String) -> String {
        var normalized = text
        if normalized.hasPrefix("\u{FEFF}") {
            normalized.removeFirst()
        }
        normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        return normalized
    }
}
