import AppFoundation
import SwiftUI

struct BYOKOnboardingView: View {
  let onCompletion: @MainActor () -> Void

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

      VStack(spacing: compact ? 11 : 17) {
        Spacer(minLength: compact ? 0 : 8)

        demo(for: page, isSelected: context.isSelected)
          .frame(maxWidth: .infinity)

        copy(for: page, context: context, compact: compact)

        Spacer(minLength: compact ? 0 : 6)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
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
        eyebrow: "NATIVE AI CHAT",
        title: "Chat with any model",
        message: "Streaming answers, reasoning, files, and tools in one native workspace.",
        context: context,
        compact: compact
      )

    case .providers:
      onboardingCopy(
        eyebrow: "YOUR PROVIDERS",
        title: "Your providers. Your API keys.",
        message: "Connect cloud models, private endpoints, and local servers directly.",
        context: context,
        compact: compact
      )

    case .workspace:
      onboardingCopy(
        eyebrow: "AI WORKSPACE",
        title: "More than chat",
        message: "Projects, tools, and usage insights in one focused workspace.",
        context: context,
        compact: compact
      )
    }
  }

  private func onboardingCopy(
    eyebrow: String,
    title: String,
    message: String,
    context: FoundationOnboardingPageContext,
    compact: Bool
  ) -> some View {
    VStack(spacing: compact ? 7 : 9) {
      Text(eyebrow)
        .font(.caption2.weight(.bold))
        .tracking(1.4)
        .foregroundStyle(context.theme.primary)

      Text(title)
        .font(.system(size: compact ? 26 : 30, weight: .bold, design: .rounded))
        .foregroundStyle(context.primaryForeground)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.88)
        .fixedSize(horizontal: false, vertical: true)

      Text(message)
        .font(compact ? .caption : .subheadline)
        .foregroundStyle(context.secondaryForeground)
        .multilineTextAlignment(.center)
        .lineSpacing(compact ? 1 : 3)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 330)
    }
    .frame(maxWidth: .infinity)
  }
}
