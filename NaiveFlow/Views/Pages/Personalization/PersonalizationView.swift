//
//  PersonalizationView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 6/20/26.
//

import SwiftUI

struct PersonalizationView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CustomizeAppIconView()
                    } label: {
                        TextWithColorfulIcon(title: "App Icon", systemName: "app.fill", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    NavigationLink {
                        CustomizeThemeView()
                    } label: {
                        TextWithColorfulIcon(title: "Theme", systemName: "paintbrush.fill", foregroundStyle: .white, backgroundStyle: .pink.gradient)
                    }
                }
            }
            .navigationTitle("Personalization")
        }
    }
}
