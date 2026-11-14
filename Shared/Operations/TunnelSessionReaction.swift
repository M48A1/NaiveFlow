//
//  TunnelSessionReaction.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/20/26.
//

import Foundation
import NetworkExtension

@MainActor
struct TunnelSessionReaction {
    let tunnel: TunnelController
    let selection: ProxySelection

    func run() {
        let status = tunnel.rawStatus
        if status == .disconnected || status == .invalid,
           tunnel.consumePendingReconnect(),
           let configuration = selection.effectiveConfiguration {
            tunnel.connect(using: configuration)
        }
    }
}
