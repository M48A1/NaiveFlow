//
//  TagBadge.swift
//  NaiveFlow
//
//  Created by NodePassProject on 6/29/26.
//

import SwiftUI

struct TagBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .designText(.micro, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
            .dynamicTypeSize(.medium)
    }
}
