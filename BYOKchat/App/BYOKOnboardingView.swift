import AppFoundation
import SwiftUI

struct BYOKOnboardingView: View {
  let onCompletion: @MainActor () -> Void

  private enum Page: String, CaseIterable, Identifiable {
    case chat
    case providers
    case workspace

    var id: String { rawValue }
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

  @ViewBuilder
  private func pageContent(_ page: Page, context: FoundationOnboardingPageContext) -> some View {
    VStack(spacing: 18) {
      Spacer(minLength: 4)

      Group {
        switch page {
        case .chat:
          BYOKOnboardingChatDemo(isSelected: context.isSelected)

        case .providers:
          BYOKOnboardingProvidersDemo(isSelected: context.isSelected)

        case .workspace:
          BYOKOnboardingWorkspaceDemo(isSelected: context.isSelected)
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: 390)

      switch page {
      case .chat:
        onboardingCopy(
          eyebrow: "NATIVE AI CHAT",
          title: "Chat with any model",
          message: "Streaming answers, reasoning, files, and tools in one native workspace.",
          context: context
        )

      case .providers:
        onboardingCopy(
          eyebrow: "YOUR PROVIDERS",
          title: "Your providers. Your API keys.",
          message: "Connect cloud models, private endpoints, and local servers directly.",
          context: context
        )

      case .workspace:
        onboardingCopy(
          eyebrow: "AI WORKSPACE",
          title: "More than chat",
          message: "Projects, tools, usage insights, and controls built into one workspace.",
          context: context
        )
      }

      Spacer(minLength: 2)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func onboardingCopy(
    eyebrow: String,
    title: String,
    message: String,
    context: FoundationOnboardingPageContext
  ) -> some View {
    VStack(spacing: 9) {
      Text(eyebrow)
        .font(.caption2.weight(.bold))
        .tracking(1.4)
        .foregroundStyle(context.theme.primary)

      Text(title)
        .font(.system(size: 30, weight: .bold, design: .rounded))
        .foregroundStyle(context.primaryForeground)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      Text(message)
        .font(.subheadline)
        .foregroundStyle(context.secondaryForeground)
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 340)
    }
    .frame(maxWidth: .infinity)
  }
}
