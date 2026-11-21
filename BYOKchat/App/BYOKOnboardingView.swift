import AppFoundation
import SwiftUI

struct BYOKOnboardingView: View {
  let onCompletion: @MainActor () -> Void

  @Environment(\.appFoundationTheme) private var theme

  private enum Page: String, CaseIterable, Identifiable, FoundationOnboardingHeaderProviding {
    case chat
    case providers
    case workspace

    var id: String { rawValue }

    var onboardingHeaderTitle: String? {
      switch self {
      case .chat:
        "WELCOME"
      case .providers:
        "PROVIDERS"
      case .workspace:
        "WORKSPACE"
      }
    }

    var onboardingHeaderSystemImage: String? {
      switch self {
      case .chat:
        "sparkles"
      case .providers:
        "key.horizontal"
      case .workspace:
        "square.grid.2x2"
      }
    }
  }

  var body: some View {
    FoundationOnboardingView(
      pages: Page.allCases,
      configuration: FoundationOnboardingConfiguration(
        headerTitle: nil,
        headerSystemImage: nil,
        showsSkipButton: true,
        skipTitle: "Skip",
        continueTitle: "Continue",
        completionTitle: "Get Started",
        showsPageIndicator: true,
        centersPageContent: false,
        contentHorizontalPadding: 20,
        contentVerticalPadding: 0,
        buttonAppearance: .themed
      )
    ) { page, context in
      pageContent(page, context: context)
    } onCompletion: {
      onCompletion()
    }
  }

  private func pageContent(
    _ page: Page,
    context: FoundationOnboardingPageContext
  ) -> some View {
    GeometryReader { geometry in
      let compact = geometry.size.height < 470

      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: compact ? 12 : 18) {
          Spacer(minLength: compact ? 0 : 8)

          demo(for: page, isSelected: context.isSelected)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: compact ? 236 : 268, alignment: .center)
            .background(
              theme.surfaceColor.opacity(0.92),
              in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(theme.borderColor)
            }
            .shadow(color: theme.appearance.shadow.color.opacity(0.42), radius: 16, y: 8)
            .padding(.bottom, compact ? 8 : 14)

          copy(for: page, context: context, compact: compact)

          Spacer(minLength: compact ? 0 : 6)
        }
        .frame(width: geometry.size.width)
        .frame(minHeight: geometry.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }

  @ViewBuilder
  private func demo(for page: Page, isSelected: Bool) -> some View {
    switch page {
    case .chat:
      BYOKOnboardingChatDemo(isSelected: isSelected)
    case .providers:
      BYOKOnboardingProvidersDemo(isSelected: isSelected)
    case .workspace:
      BYOKOnboardingWorkspaceDemo(isSelected: isSelected)
    }
  }

  @ViewBuilder
  private func copy(
    for page: Page,
    context: FoundationOnboardingPageContext,
    compact: Bool
  ) -> some View {
    switch page {
    case .chat:
      onboardingCopy(
        title: "Chat with any model",
        message: "Streaming answers, reasoning, files, and per-chat controls in one native workspace.",
        context: context,
        compact: compact
      )

    case .providers:
      onboardingCopy(
        title: "Your providers. Your API keys.",
        message: "Keys stay on-device in Keychain. Requests go straight to cloud and local models with no proxy.",
        context: context,
        compact: compact
      )

    case .workspace:
      onboardingCopy(
        title: "More than chat",
        message: "Projects, MCP tools with approval, and on-device usage insights in one focused app.",
        context: context,
        compact: compact
      )
    }
  }

  private func onboardingCopy(
    title: String,
    message: String,
    context: FoundationOnboardingPageContext,
    compact: Bool
  ) -> some View {
    VStack(spacing: compact ? 7 : 9) {
      Text(title)
        .font(.system(size: compact ? 25 : 29, weight: .bold, design: .rounded))
        .foregroundStyle(context.primaryForeground)
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .minimumScaleFactor(0.85)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)

      Text(message)
        .font(compact ? .footnote : .subheadline)
        .foregroundStyle(context.secondaryForeground)
        .multilineTextAlignment(.center)
        .lineSpacing(compact ? 1.5 : 3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 340)
    }
    .frame(maxWidth: .infinity)
  }
}
