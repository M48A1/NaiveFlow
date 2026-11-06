//
//  WidgetBundle.swift
//  RuleProxy
//
//  Created by NodePassProject on 4/6/26.
//

import WidgetKit
import SwiftUI

@main
struct RuleProxyWidgetBundle: WidgetBundle {
    var body: some Widget {
        VPNToggleControl()
        ModeToggleControl()
    }
}
