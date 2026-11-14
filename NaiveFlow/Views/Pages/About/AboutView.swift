import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "network").font(.system(size: 38, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 76, height: 76).background(.blue.gradient, in: RoundedRectangle(cornerRadius: 21))
                    Text("NaiveFlow").designText(.sectionTitle, weight: .semibold)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .designText(.secondary).foregroundStyle(DesignSystem.Colors.secondaryText)
                }.frame(maxWidth: .infinity).padding(.vertical, 22)
            }
            Section {
                NavigationLink("Licenses and Acknowledgements") { AcknowledgementsView() }
                Link(destination: URL(string: "mailto:hello@cathayepic.com")!) {
                    HStack {
                        Label("Feedback", systemImage: "envelope")
                        Spacer()
                        Text("hello@cathayepic.com").designText(.secondary).foregroundStyle(DesignSystem.Colors.secondaryText)
                    }
                }
            }
        }.navigationTitle("About").clientInlineTitle()
    }
}
