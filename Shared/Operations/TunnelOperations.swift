//
//  TunnelOperations.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/20/26.
//

import Foundation

@MainActor
struct TunnelOperations {
    let tunnel: TunnelController
    let selection: ProxySelection

    func connect() {
        guard let configuration = selection.effectiveConfiguration else { return }
        tunnel.connect(using: configuration)
    }

    func disconnect() {
        tunnel.disconnect()
    }

    func reconnect() {
        tunnel.reconnect()
    }
}
