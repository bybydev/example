import Foundation
import SwiftUI

enum InkribeSettingsSupport {
    @ViewBuilder
    static func scroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    static func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}
