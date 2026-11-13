//
//  Page.swift
//  NaiveFlow
//
//  Created by NodePassProject on 9/23/26.
//

import Foundation

enum Page: Equatable, Hashable, Identifiable, CaseIterable {
    case launchpad
    case dashboard
    case proxies
    case toolbox
    case data
    case configuration
    case diagnosis
    case about
    
    var id: Int {
        switch self {
        case .proxies: 15
        case .launchpad: 0
        case .dashboard: 1
        case .toolbox: 2
        case .data: 3
        case .configuration: 14
        case .diagnosis: 12
        case .about: 13
        }
    }
    
    var name: String {
        switch self {
        case .proxies: String(localized: "Policy")
        case .launchpad: String(localized: "Overview")
        case .dashboard: String(localized: "Dashboard")
        case .toolbox: String(localized: "Toolbox")
        case .data: String(localized: "Data")
        case .configuration: String(localized: "Configuration")
        case .diagnosis: String(localized: "Diagnosis")
        case .about: String(localized: "About")
        }
    }
    
    var symbol: String {
        switch self {
        case .proxies: "arrow.triangle.branch"
        case .launchpad: "switch.2"
        case .dashboard: "rectangle.3.group"
        case .toolbox: "latch.2.case"
        case .data: "cylinder.split.1x2"
        case .configuration: "doc.text"
        case .diagnosis: "stethoscope"
        case .about: "info.circle"
        }
    }
}
