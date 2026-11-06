//
//  SelectionOperations.swift
//  RuleProxy
//
//  Created by NodePassProject on 8/20/26.
//

import Foundation

@MainActor
struct SelectionOperations {
    let proxySelection: ProxySelection

    func select(_ configuration: ProxyConfiguration) {
        guard !proxySelection.usesRuntimeVersion else { return }
        proxySelection.select(configuration)
    }

    func selectChain(_ chain: ProxyChain, configurations: [ProxyConfiguration]) {
        guard !proxySelection.usesRuntimeVersion else { return }
        proxySelection.selectChain(chain, configurations: configurations)
    }

    func selectIfNone(_ configuration: ProxyConfiguration) {
        proxySelection.selectIfNone(configuration)
    }
}
