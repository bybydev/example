import Foundation
import MacAppFoundation
import SwiftUI

struct InkribeAboutSettingsPane: View {
    @Environment(\.macAppTheme) private var theme
    @State private var showsThirdPartyNotices = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        InkribeSettingsSupport.scroll {
            GroupBox("Inkribe") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Product", value: "Offline speech-to-text workspace")
                    LabeledContent("Processing", value: "Local by design")
                    LabeledContent("Platform", value: "macOS")
                    LabeledContent("Version", value: "\(version) (\(build))")
                    Divider()
                    Button("Third-Party Notices…") {
                        showsThirdPartyNotices = true
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .background(theme.canvas)
        .sheet(isPresented: $showsThirdPartyNotices) {
            ThirdPartyNoticesView()
        }
    }
}
