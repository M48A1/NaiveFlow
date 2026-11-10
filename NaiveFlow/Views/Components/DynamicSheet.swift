//
//  DynamicSheet.swift
//  NaiveFlow
//
//  Created by NodePassProject on 2/16/26.
//

import SwiftUI

struct DynamicSheet<Content: View>: View {
    var animation: Animation
    @ViewBuilder var content: Content
    @State private var sheetHeight: CGFloat = 320
    var body: some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { newValue in
                    withAnimation(animation) {
                        sheetHeight = max(1, newValue.height)
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        // The presentation system limits the detent to the current container.
        // Measure the intrinsic content, not the sheet's constrained viewport.
        .modifier(SheetHeightModifier(height: sheetHeight))
    }
}

fileprivate struct SheetHeightModifier: ViewModifier, Animatable {
    var height: CGFloat
    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }
    func body(content: Content) -> some View {
        content
            .presentationDetents(height == .zero ? [.medium] : [.height(height)])
    }
}
