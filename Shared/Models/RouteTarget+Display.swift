//
//  RouteTarget+Display.swift
//  NaiveFlow
//
//  Created by NodePassProject on 6/7/26.
//

import Foundation

extension RouteTarget {
    @MainActor
    func outboundName(
        defaultRouteTarget: RouteTarget?,
        selection: ProxySelection?
    ) -> String? {
        let target: RouteTarget
        switch self {
        case .default:
            guard let defaultRouteTarget else { return nil }
            target = defaultRouteTarget
        case .defaultProxy:
            target = defaultRouteTarget ?? .defaultProxy
        default:
            target = self
        }

        switch target {
        case .default: return String(localized: "Default")
        case .defaultProxy: return selection?.effectiveConfiguration?.name ?? String(localized: "Proxy")
        case .proxy(let id): return selection?.runtimeOutboundNames[id] ?? String(localized: "Proxy")
        case .direct: return self == .direct ? nil : String(localized: "DIRECT")
        case .reject: return self == .reject ? nil : String(localized: "REJECT")
        }
    }
}
