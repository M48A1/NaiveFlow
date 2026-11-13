//
//  ToolboxView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/29/26.
//

import SwiftUI

struct ToolboxView: View {
    @Binding var path: [Page]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: Page.data) {
                        TextWithColorfulIcon(title: "Data", systemName: "cylinder.split.1x2.fill", foregroundStyle: .white, backgroundStyle: .gray.gradient)
                    }
                }
                
                Section {
                    NavigationLink(value: Page.configuration) {
                        TextWithColorfulIcon(title: "Configuration", systemName: "doc.text.fill", foregroundStyle: .white, backgroundStyle: .indigo.gradient)
                    }
                }
                
                
                Section {
                    NavigationLink(value: Page.diagnosis) {
                        TextWithColorfulIcon(title: "Diagnosis", systemName: "stethoscope", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    NavigationLink(value: Page.about) {
                        TextWithColorfulIcon(title: "About", systemName: "info.circle.fill", foregroundStyle: .white, backgroundStyle: .gray.gradient)
                    }
                }
            }
            .navigationTitle("Toolbox")
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .data: DataView()
                case .configuration: ProfileView()
                case .diagnosis: DiagnosisView()
                case .about: AboutView()
                case .launchpad, .dashboard, .proxies, .toolbox: EmptyView()
                }
            }
        }
    }
}
