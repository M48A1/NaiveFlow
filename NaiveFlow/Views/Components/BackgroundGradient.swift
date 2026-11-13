//
//  BackgroundGradient.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/21/26.
//

import SwiftUI

struct BackgroundGradient: View {
    var body: some View {
        LinearGradient(colors: [.homeBackgroundStart, .homeBackgroundEnd], startPoint: .top, endPoint: .bottom)
    }
}
