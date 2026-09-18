import Foundation
import SwiftUI

struct ThirdPartyNoticesView: View {
    @Environment(\.dismiss) private var dismiss

    private let notices: String

    init(bundle: Bundle = .main) {
        if let url = bundle.url(
            forResource: "ThirdPartyNotices",
            withExtension: "txt"
        ),
        let value = try? String(contentsOf: url, encoding: .utf8) {
            notices = value
        } else {
            notices = "Third-party notices are unavailable in this build."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Third-Party Notices")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                Text(notices)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}
