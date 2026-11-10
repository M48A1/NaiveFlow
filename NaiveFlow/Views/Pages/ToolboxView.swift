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
                    NavigationLink(value: Page.personalization) {
                        TextWithColorfulIcon(title: "Personalization", systemName: "paintpalette.fill", foregroundStyle: .white, backgroundStyle: .pink.gradient)
                    }
                }
                
                Section {
                    NavigationLink(value: Page.tunnel) {
                        TextWithColorfulIcon(title: "Tunnel", systemName: "hammer.fill", foregroundStyle: .white, backgroundStyle: .gray.gradient)
                    }
                    NavigationLink(value: Page.purify) {
                        TextWithColorfulIcon(title: "Purify", systemName: "drop.fill", foregroundStyle: .white, backgroundStyle: .blue.gradient)
                    }
                    NavigationLink(value: Page.routing) {
                        TextWithColorfulIcon(title: "Routing", systemName: "arrow.triangle.branch", foregroundStyle: .white, backgroundStyle: .purple.gradient)
                    }
                    NavigationLink(value: Page.mitm) {
                        TextWithColorfulIcon(title: "MITM", systemName: "key.horizontal.fill", foregroundStyle: .white, backgroundStyle: .teal.gradient)
                    }
                    NavigationLink(value: Page.modules) {
                        TextWithColorfulIcon(title: "Modules", systemName: "shippingbox.fill", foregroundStyle: .white, backgroundStyle: .orange.gradient)
                    }
                    NavigationLink(value: Page.configuration) {
                        TextWithColorfulIcon(title: "Configuration", systemName: "doc.text.fill", foregroundStyle: .white, backgroundStyle: .indigo.gradient)
                    }
                }
                
                Section {
                    NavigationLink(value: Page.trustedCertificates) {
                        TextWithColorfulIcon(title: "Trusted Certificates", systemName: "checkmark.seal.fill", foregroundStyle: .white, backgroundStyle: .green.gradient)
                    }
                    NavigationLink(value: Page.trustedNetwork) {
                        TextWithColorfulIcon(title: "Trusted Network", systemName: "wifi", foregroundStyle: .white, backgroundStyle: .blue.gradient)
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
                case .personalization: PersonalizationView()
                case .tunnel: TunnelView()
                case .purify: PurifyView()
                case .routing: RoutingView()
                case .mitm: MITMView()
                case .modules: ModulesView()
                case .configuration: ProfileView()
                case .trustedCertificates: TrustedCertificatesView()
                case .trustedNetwork: TrustedNetworkView()
                case .diagnosis: DiagnosisView()
                case .about: AboutView()
                case .launchpad, .dashboard, .toolbox: EmptyView()
                }
            }
        }
    }
}
