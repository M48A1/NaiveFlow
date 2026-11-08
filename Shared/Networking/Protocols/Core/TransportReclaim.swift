//
//  TransportReclaim.swift
//  NaiveFlow
//
//  Created by NodePassProject on 6/9/26.
//

import Foundation

nonisolated enum TransportReclaim {
    static func reclaimAll() {
        for proto in OutboundProtocol.allCases {
            switch proto {
            case .nowhere:  NowhereClient.pool.reclaim()
            case .vless:
                VLESSEncryption0RTTCache.shared.clear()
                XHTTPXMUXMultiplexerRegistry.shared.reclaim()
            case .hysteria: HysteriaClient.pool.reclaim()
            case .anytls:   AnyTLSMultiplexerRegistry.shared.reclaim()
            case .trojan, .shadowsocks, .socks5, .direct:
                break
            }
        }
    }
    
    static func sealAll() {
        NowhereClient.seal()
        AnyTLSMultiplexerRegistry.shared.seal()
    }

    static func unsealAll() {
        NowhereClient.unseal()
        AnyTLSMultiplexerRegistry.shared.unseal()
    }
}
