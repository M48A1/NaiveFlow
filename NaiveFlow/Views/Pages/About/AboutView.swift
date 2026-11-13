import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "network").font(.system(size: 38, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 76, height: 76).background(.blue.gradient, in: RoundedRectangle(cornerRadius: 21))
                    Text("NaiveFlow").font(.title2.weight(.semibold))
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 22)
            }
            Section {
                NavigationLink("开源许可与致谢") { AcknowledgementsView() }
            }
        }.navigationTitle("关于").navigationBarTitleDisplayMode(.inline)
    }
}
