//
//  BoundedHTTPFetcher.swift
//  NaiveFlow
//
//  Created by NodePassProject on 11/7/26.
//

import Foundation

/// Streams a text/JSON resource while enforcing a hard byte ceiling.
///
/// `URLSession.shared.data(from:)` materialises the entire response body before
/// any caller-side size check runs, so an oversized or hostile subscription can
/// exhaust memory before a rule-count guard is ever reached. This helper streams
/// the body, rejects a declared over-limit `Content-Length` up front, and cancels
/// the transfer the moment the accumulated bytes exceed `maxBytes` — matching the
/// streaming protection already used for proxy subscriptions.
nonisolated enum BoundedHTTPFetcher {
    /// Ceiling for rule-set / module subscription bodies.
    static let defaultMaxBytes = 8 * 1024 * 1024

    enum Failure: LocalizedError {
        case nonHTTP
        case responseTooLarge(limit: Int)

        var errorDescription: String? {
            switch self {
            case .nonHTTP:
                return String(localized: "The server returned a non-HTTP response.")
            case .responseTooLarge(let limit):
                return String(localized: "The response exceeds the \(limit)-byte limit.")
            }
        }
    }

    /// Fetches `url`, returning the bounded body and the HTTP response. Status
    /// validation is left to each caller so it can keep its own error type; only
    /// the byte ceiling is enforced here.
    ///
    /// - Parameter session: injectable so tests can drive a stubbed protocol.
    static func fetch(
        _ url: URL,
        maxBytes: Int = defaultMaxBytes,
        session: URLSession = .shared
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("NaiveFlow", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.nonHTTP }

        // Reject immediately when the server declares an over-limit length.
        if http.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            throw Failure.responseTooLarge(limit: maxBytes)
        }

        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(http.expectedContentLength), maxBytes))
        }
        for try await byte in bytes {
            guard data.count < maxBytes else {
                bytes.task.cancel()
                throw Failure.responseTooLarge(limit: maxBytes)
            }
            data.append(byte)
        }
        return (data, http)
    }
}
