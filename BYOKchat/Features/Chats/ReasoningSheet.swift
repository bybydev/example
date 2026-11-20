import AppFoundation
import SwiftUI

struct ReasoningSheet: View {
  let reasoning: String

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(reasoning)
          .font(.system(size: fontSize))
          .lineSpacing(5)
          .foregroundStyle(theme.primaryForegroundColor)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20)
          .padding(.vertical, 18)
      }
      .background(theme.backgroundColor.ignoresSafeArea())
      .navigationTitle("Reasoning")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          CopyButton(text: reasoning, accessibilityTitle: "Copy reasoning", size: .toolbar)
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}
