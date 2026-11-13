//
//  RoutingRule.swift
//  NaiveFlow
//
//  Created by NodePassProject on 3/1/26.
//

import Foundation

nonisolated enum RoutingRuleType: Int, Codable {
    case ipCIDR = 0
    case domainSuffix = 2
    case domainKeyword = 3
}

extension RoutingRuleType {
    var displayLabel: String {
        switch self {
        case .domainSuffix: return String(localized: "Domain Suffix")
        case .domainKeyword: return String(localized: "Domain Keyword")
        case .ipCIDR: return String(localized: "IPv4 CIDR")
        }
    }
    
    var iconName: String {
        switch self {
        case .domainSuffix: return "globe"
        case .domainKeyword: return "magnifyingglass"
        case .ipCIDR: return "network"
        }
    }
    
    func normalized(_ value: String) -> String {
        switch self {
        case .ipCIDR:
            if !value.contains("/") {
                return value + "/32"
            }
            return value
        case .domainSuffix, .domainKeyword:
            return value
        }
    }
}

nonisolated struct RoutingRule: Codable, Equatable, Identifiable {
    let id = UUID()
    let type: RoutingRuleType
    let value: String

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    static func == (lhs: RoutingRule, rhs: RoutingRule) -> Bool {
        lhs.type == rhs.type && lhs.value == rhs.value
    }
}
