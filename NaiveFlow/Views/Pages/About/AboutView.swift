//
//  AboutView.swift
//  NaiveFlow
//
//  Created by NodePassProject on 8/21/26.
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        TextWithColorfulIcon(title: "Acknowledgements", systemName: "doc.text.fill", foregroundStyle: .white, backgroundStyle: .gray.gradient)
                    }
                } footer: {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        HStack {
                            Text("Advanced Settings")
                                .font(.body)
                            Image(systemName: "chevron.right")
                                .font(.footnote.bold())
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("About")
        }
    }
}
