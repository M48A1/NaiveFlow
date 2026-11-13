//
//  TVRootView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/27/26.
//

import SwiftUI

struct TVRootView: View {
    let container: AppContainer

    var body: some View {
        TabView {
            Tab("Launchpad", image: "naiveflow.fill") {
                TVPageHost { TVLaunchpadViewController(container: container) }
                    .ignoresSafeArea()
            }
            Tab("Configuration", systemImage: "doc.text") {
                TVConfigurationView(container: container)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

private struct TVPageHost: UIViewControllerRepresentable {
    let makeController: () -> UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        makeController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
