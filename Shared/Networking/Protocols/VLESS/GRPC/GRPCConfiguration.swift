//
//  GRPCConfiguration.swift
//  NaiveFlow
//
//  Created by NodePassProject on 4/23/26.
//

import Foundation

nonisolated struct GRPCConfiguration: Codable, Equatable, Hashable {
    static let defaultServiceName = "xray.transport.internet.grpc.encoding.GRPCService"

    /// gRPC service name. A plain name maps to `/<name>/Tun` (or `/TunMulti`); a leading
    /// `/` marks a full custom path whose final segment is the stream name.
    let serviceName: String

    /// HTTP/2 `:authority` value; when empty, derived from SNI / server address at dial time.
    let authority: String

    /// When `true`, uses the `TunMulti` stream. A single-element `MultiHunk` is
    /// wire-compatible with `Hunk`, so encoding is identical in both modes.
    let multiMode: Bool

    /// Custom `User-Agent` header. When empty, falls back to the default Chrome UA.
    let userAgent: String

    /// HTTP/2 initial window size (bytes). `0` means use gRPC's default (65535).
    let initialWindowsSize: Int

    /// Keepalive ping interval in seconds. `0` disables keepalive pings.
    let idleTimeout: Int

    /// Keepalive ping timeout in seconds. `0` uses the gRPC default (20 seconds).
    let healthCheckTimeout: Int

    /// When `true`, send keepalive pings even when no streams are active.
    let permitWithoutStream: Bool

    init(
        serviceName: String = "",
        authority: String = "",
        multiMode: Bool = false,
        userAgent: String = "",
        initialWindowsSize: Int = 0,
        idleTimeout: Int = 0,
        healthCheckTimeout: Int = 0,
        permitWithoutStream: Bool = false
    ) {
        self.serviceName = serviceName
        self.authority = authority
        self.multiMode = multiMode
        self.userAgent = userAgent
        self.initialWindowsSize = initialWindowsSize
        self.idleTimeout = idleTimeout
        self.healthCheckTimeout = healthCheckTimeout
        self.permitWithoutStream = permitWithoutStream
    }

    static func parse(from params: [String: String]) -> GRPCConfiguration? {
        let serviceName = params["serviceName"] ?? ""
        let authority = params["authority"] ?? ""
        let mode = (params["mode"] ?? "gun").lowercased()
        let multiMode = (mode == "multi")
        let userAgent = params["userAgent"] ?? ""

        let initialWindowsSize = params["initial_windows_size"].flatMap { Int($0) } ?? 0
        let idleTimeout = params["idle_timeout"].flatMap { Int($0) } ?? 0
        let healthCheckTimeout = params["health_check_timeout"].flatMap { Int($0) } ?? 0
        let permitWithoutStream = params["permit_without_stream"].map { $0 != "false" && $0 != "0" } ?? false

        return GRPCConfiguration(
            serviceName: serviceName,
            authority: authority,
            multiMode: multiMode,
            userAgent: userAgent,
            initialWindowsSize: initialWindowsSize,
            idleTimeout: idleTimeout,
            healthCheckTimeout: healthCheckTimeout,
            permitWithoutStream: permitWithoutStream
        )
    }

    // MARK: - Path resolution

    /// Returns the `:authority` to advertise: explicit config → TLS SNI → Reality SNI → server address.
    func resolvedAuthority(tlsServerName: String?, realityServerName: String?, serverAddress: String) -> String {
        if !authority.isEmpty { return authority }
        if let tlsServerName, !tlsServerName.isEmpty { return tlsServerName }
        if let realityServerName, !realityServerName.isEmpty { return realityServerName }
        return serverAddress
    }

    /// Returns the HTTP/2 `:path`: `/<escaped serviceName>/Tun[Multi]`, or the custom
    /// path when `serviceName` starts with `/`. Components are URL-path-escaped.
    ///
    /// Throws a configuration error when a custom path cannot name a stream (for
    /// example `/` or a trailing slash), rather than trapping on a reversed string
    /// range. The editor/parser accept these strings, so the failure must surface as
    /// an ``NaiveFlowError/Proxy/invalidConfiguration(detail:)`` at dial time.
    func resolvedPath() throws -> String {
        let name = serviceName.isEmpty ? Self.defaultServiceName : serviceName
        if !name.hasPrefix("/") {
            let stream = multiMode ? "TunMulti" : "Tun"
            return "/\(urlPathEscape(name))/\(stream)"
        }

        // Custom full path: drop the leading slash and split off the final segment,
        // which names the stream. `lastIndex(of:)` (rather than a backwards
        // `range(of:)`) keeps the bounds valid for both `/` and `/name`, where the
        // single slash leaves no service component.
        let trimmed = name.dropFirst()
        let lastSlash = trimmed.lastIndex(of: "/")
        let serviceRaw = lastSlash.map { String(trimmed[trimmed.startIndex..<$0]) } ?? ""
        let endingSegment = lastSlash.map { String(trimmed[trimmed.index(after: $0)...]) } ?? String(trimmed)

        let servicePart = serviceRaw
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { urlPathEscape(String($0)) }
            .joined(separator: "/")

        let parts = endingSegment.split(separator: "|", omittingEmptySubsequences: false).map { String($0) }
        let streamName: String
        if multiMode {
            // `|` splits the Tun name (before) from the TunMulti name (after); without it one name serves both.
            streamName = parts.count >= 2 ? parts[1] : (parts.first ?? "")
        } else {
            streamName = parts.first ?? ""
        }

        guard !streamName.isEmpty else {
            throw NaiveFlowError.proxy(.grpc, .invalidConfiguration(
                detail: "gRPC serviceName '\(name)' does not resolve to a stream name"
            ))
        }

        let prefix = servicePart.isEmpty ? "" : "/\(servicePart)"
        return "\(prefix)/\(urlPathEscape(streamName))"
    }

    private func urlPathEscape(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
