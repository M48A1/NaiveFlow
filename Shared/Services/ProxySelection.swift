//
//  ProxySelection.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/3/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class ProxySelection {
    private(set) var runtimeOutboundNames: [UUID: String] = [:]
    private(set) var runtimeGroups: [RuntimeGroupDisplay] = []
    private(set) var runtimeConfiguration: ProxyConfiguration?
    var usesRuntimeVersion: Bool { runtimeConfiguration != nil }
    var effectiveConfiguration: ProxyConfiguration? { runtimeConfiguration }

    func showRuntimeVersion(_ bundle: RuntimeConfigurationBundle) {
        guard let node = bundle.selectedNode else {
            clearRuntimeVersion()
            return
        }
        runtimeConfiguration = node
        runtimeOutboundNames = Dictionary(bundle.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        runtimeGroups = bundle.displayGroups.isEmpty ? bundle.policyGroups.map {
            RuntimeGroupDisplay(id: $0.id, name: $0.name, memberCount: $0.memberIDs.count, iconURL: $0.iconURL)
        } : bundle.displayGroups
    }

    func clearRuntimeVersion() {
        runtimeConfiguration = nil
        runtimeOutboundNames = [:]
        runtimeGroups = []
    }
}
