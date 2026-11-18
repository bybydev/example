import AppFoundation
import SwiftUI
import UIKit

struct ReasoningSheet: View {
  let reasoning: String

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(reasoning)
          .font(.system(size: 15))
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
