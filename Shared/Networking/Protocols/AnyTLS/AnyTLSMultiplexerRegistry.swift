//
//  AnyTLSMultiplexerRegistry.swift
//  NaiveFlow
//
//  Created by NodePassProject on 5/16/26.
//

import Foundation
import Synchronization

nonisolated final class AnyTLSMultiplexerRegistry: Sendable {
    nonisolated static let shared = AnyTLSMultiplexerRegistry()

    private struct Key: Hashable {
        let host: String
        let port: UInt16
        let password: String
        let chain: [ProxyConfiguration]

        /// The TLS handshake settings (SNI, certificate verification, ALPN,
        /// fingerprint, ECH, version range). Two nodes that share address/port/
        /// password but differ here must not share a pool — the pool pins the
        /// first node's dial closure, so a strict-verify node would otherwise
        /// keep using a skip-verify connection.
        let tls: TLSConfiguration

        /// The actual address dialed (resolved IP when address resolution is
        /// used, otherwise the server address), plus the resolution flag.
        let directDialHost: String
        let useResolvedAddressForDirectDial: Bool
    }

    private struct State {
        var pools: [Key: AnyTLSMultiplexerPool] = [:]
        var sealed = false
    }
    private let state = Mutex(State())

    private init() {}

    func seal() { state.withLock { $0.sealed = true } }

    func unseal() { state.withLock { $0.sealed = false } }

    func pool(
        for configuration: ProxyConfiguration,
        tls: TLSConfiguration,
        directDialHost: String,
        useResolvedAddressForDirectDial: Bool,
        dialOut: @escaping AnyTLSMultiplexerPool.DialOut
    ) -> AnyTLSMultiplexerPool? {
        guard let anytls = configuration.anytls else { return nil }
        let key = Key(
            host: configuration.serverAddress,
            port: configuration.serverPort,
            password: anytls.password,
            chain: configuration.chain ?? [],
            tls: tls,
            directDialHost: directDialHost,
            useResolvedAddressForDirectDial: useResolvedAddressForDirectDial
        )
        let pool = state.withLock { state -> AnyTLSMultiplexerPool? in
            if let existing = state.pools[key] {
                return existing
            }
            guard !state.sealed else { return nil }
            let created = AnyTLSMultiplexerPool(
                password: anytls.password,
                idleSessionCheckInterval: TimeInterval(anytls.idleCheckInterval),
                idleSessionTimeout:       TimeInterval(anytls.idleTimeout),
                minIdleSession:           anytls.minIdleSession,
                dialOut: dialOut
            )
            state.pools[key] = created
            return created
        }
        guard let pool else { return nil }
        return pool
    }

    func closeAll() {
        let snapshot = state.withLock { state -> [AnyTLSMultiplexerPool] in
            let values = Array(state.pools.values)
            state.pools.removeAll(keepingCapacity: false)
            return values
        }
        for pool in snapshot {
            pool.closeAll()
        }
    }
}

nonisolated extension AnyTLSMultiplexerRegistry: TransportPool {
    func reclaim() { closeAll() }
}
