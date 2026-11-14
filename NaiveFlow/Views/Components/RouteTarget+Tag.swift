//
//  RouteTarget+Tag.swift
//  NaiveFlow
//
//  Created by NodePassProject on 9/23/26.
//

import SwiftUI

extension RouteTarget {
    var tagText: String {
        switch self {
        case .default: String(localized: "Default")
        case .direct: String(localized: "Direct")
        case .reject: String(localized: "Reject")
        case .defaultProxy, .proxy: String(localized: "Proxy")
        }
    }

    var tagColor: Color {
        switch self {
        case .default: .blue
        case .direct: .green
        case .reject: .red
        case .defaultProxy, .proxy: .purple
        }
    }
}
