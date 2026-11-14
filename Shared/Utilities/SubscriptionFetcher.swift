//
//  SubscriptionFetcher.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation

nonisolated struct SubscriptionFetcher {
    struct Result {
        let configurations: [ProxyConfiguration]
        let stableKeys: [UUID: String]
        let name: String?
        let upload: Int64?
        let download: Int64?
        let total: Int64?
        let expire: Date?
        let iconLight: Data?
        let iconDark: Data?
    }

    static let maxResponseBytes = 8 * 1024 * 1024

    typealias SystemFetch = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    typealias ResolvedFetch = @Sendable (URLRequest, DNSUpstream) async throws -> (Data, HTTPURLResponse)

    /// Shared transport for both client interfaces. An explicit DNS upstream
    /// must succeed; failure never retries using the system resolver.
    static func fetchResponse(
        _ request: URLRequest,
        maxBytes: Int = maxResponseBytes,
        upstream: DNSUpstream? = nil,
        systemFetch: SystemFetch = { request, limit in
            let result = try await BoundedHTTPFetcher.fetch(request, maxBytes: limit)
            return (result.data, result.response)
        },
        resolvedFetch: ResolvedFetch = { request, upstream in
            let result = try await ResolvedHostFetcher.fetch(request) { host in
                try await DNSUpstreamClient.resolve(host, via: upstream).first
            }
            return (result.data, result.response)
        }
    ) async throws -> (Data, HTTPURLResponse) {
        let upstream = upstream ?? AWCore.getSubscriptionDNSUpstream()
        let result: (Data, HTTPURLResponse)
        if upstream.isSystem { result = try await systemFetch(request, maxBytes) }
        else { result = try await resolvedFetch(request, upstream) }
        guard result.0.count <= maxBytes else { throw NaiveFlowError.subscription(.responseTooLarge(limit: maxBytes)) }
        return result
    }

    static func request(url: URL, remnawaveHWIDEnabled: Bool = false, hwid: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("NaiveFlow", forHTTPHeaderField: "User-Agent")
        request.setValue(AJSONParser.formatHeaderValue, forHTTPHeaderField: "X-NaiveFlow-Format")
        if remnawaveHWIDEnabled {
            request.setValue(hwid ?? AWCore.getRemnawaveHWID(), forHTTPHeaderField: "x-hwid")
        }
        return request
    }

    static func fetch(url urlString: String, remnawaveHWIDEnabled: Bool = false) async throws -> Result {
        guard let url = URL(string: urlString) else {
            throw NaiveFlowError.subscription(.invalidURL)
        }

        let request = Self.request(url: url, remnawaveHWIDEnabled: remnawaveHWIDEnabled)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await fetchResponse(request)
        } catch let error as NaiveFlowError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw NaiveFlowError.subscription(.fetchFailed(underlying: error))
        }

        return try parse(data: data, response: response)
    }

    /// Both network paths must pass HTTP validation before interpreting any
    /// bytes as nodes or subscription metadata.
    static func parse(data: Data, response: URLResponse) throws -> Result {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NaiveFlowError.subscription(.fetchFailed(underlying: URLError(.badServerResponse)))
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NaiveFlowError.subscription(.invalidStatusCode(httpResponse.statusCode))
        }

        return try parsePayload(data: data, response: httpResponse)
    }

    /// Local files and pasted node lists have no HTTP transport to validate.
    static func parseLocal(data: Data) throws -> Result {
        try parsePayload(data: data, response: nil)
    }

    private static func parsePayload(data: Data, response httpResponse: HTTPURLResponse?) throws -> Result {
        let profileTitle = parseProfileTitle(from: httpResponse)
        let userInfo = parseSubscriptionUserInfo(from: httpResponse)
        let iconLight = parseIcon(from: httpResponse, field: "aw-icon-light")
        let iconDark = parseIcon(from: httpResponse, field: "aw-icon-dark")

        if let rawString = String(data: data, encoding: .utf8), AJSONParser.looksLikeDocument(rawString) {
            let document = try AJSONParser.parse(rawString)
            guard !document.configurations.isEmpty else {
                throw NaiveFlowError.subscription(.noConfigurations)
            }
            return Result(
                configurations: document.configurations,
                stableKeys: document.stableKeys,
                name: document.name ?? profileTitle,
                upload: document.upload ?? userInfo.upload,
                download: document.download ?? userInfo.download,
                total: document.total ?? userInfo.total,
                expire: document.expire ?? userInfo.expire,
                iconLight: document.iconLight ?? iconLight,
                iconDark: document.iconDark ?? iconDark
            )
        }

        let bodyString: String
        if let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters),
           let decodedString = String(data: decoded, encoding: .utf8),
           ProxyConfiguration.subscriptionEntryPrefixes.contains(where: { decodedString.contains($0) }) {
            bodyString = decodedString
        } else if let rawString = String(data: data, encoding: .utf8) {
            bodyString = rawString
        } else {
            throw NaiveFlowError.subscription(.noConfigurations)
        }

        if bodyString.contains("proxies:") {
            let result = try ClashProxyParser.parse(yaml: bodyString)
            guard !result.configurations.isEmpty else {
                throw NaiveFlowError.subscription(.noConfigurations)
            }
            return Result(
                configurations: result.configurations,
                stableKeys: [:],
                name: profileTitle,
                upload: userInfo.upload,
                download: userInfo.download,
                total: userInfo.total,
                expire: userInfo.expire,
                iconLight: iconLight,
                iconDark: iconDark
            )
        }

        let configurations = bodyString
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ProxyConfiguration.canParseSubscriptionEntry($0) }
            .compactMap { try? ProxyConfiguration.parseSubscriptionEntry(url: $0) }

        guard !configurations.isEmpty else {
            throw NaiveFlowError.subscription(.noConfigurations)
        }

        return Result(
            configurations: configurations,
            stableKeys: [:],
            name: profileTitle,
            upload: userInfo.upload,
            download: userInfo.download,
            total: userInfo.total,
            expire: userInfo.expire,
            iconLight: iconLight,
            iconDark: iconDark
        )
    }

    // MARK: - Header Parsing

    private static func parseProfileTitle(from response: HTTPURLResponse?) -> String? {
        guard let value = response?.value(forHTTPHeaderField: "profile-title") else { return nil }
        let decoded: String
        if value.hasPrefix("base64:") {
            let encoded = String(value.dropFirst("base64:".count))
            if let data = Data(base64Encoded: encoded),
               let utf8 = String(data: data, encoding: .utf8) {
                decoded = utf8
            } else {
                decoded = value
            }
        } else {
            decoded = value
        }
        let trimmed = decoded.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : decoded
    }

    private static func parseIcon(from response: HTTPURLResponse?, field: String) -> Data? {
        guard let value = response?.value(forHTTPHeaderField: field) else { return nil }
        return Data(iconBase64: value)
    }

    private static func parseSubscriptionUserInfo(from response: HTTPURLResponse?) -> (upload: Int64?, download: Int64?, total: Int64?, expire: Date?) {
        guard let value = response?.value(forHTTPHeaderField: "subscription-userinfo") else {
            return (nil, nil, nil, nil)
        }

        var upload: Int64?
        var download: Int64?
        var total: Int64?
        var expire: Date?

        // Format: upload=X; download=Y; total=Z; expire=T
        for part in value.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let keyValue = trimmed.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2 else { continue }
            let key = keyValue[0].trimmingCharacters(in: .whitespaces)
            let valueString = keyValue[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "upload":
                upload = Int64(valueString)
            case "download":
                download = Int64(valueString)
            case "total":
                total = Int64(valueString)
            case "expire":
                if let timestamp = TimeInterval(valueString) {
                    expire = Date(timeIntervalSince1970: timestamp)
                }
            default:
                break
            }
        }

        return (upload, download, total, expire)
    }
}
