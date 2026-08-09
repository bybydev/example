import AppFoundation
import SwiftUI

struct BYOKOnboardingView: View {
  let onCompletion: @MainActor () -> Void

  private enum Page: String, CaseIterable, Identifiable {
    case welcome
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
        completionTitle: "Start Chatting",
        showsPageIndicator: true,
        centersPageContent: true,
        contentHorizontalPadding: 24,
        contentVerticalPadding: 8,
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
    VStack(spacing: 22) {
      switch page {
      case .welcome:
        coloredWordmark
          .font(.system(size: 48, weight: .bold, design: .rounded))
          .padding(.bottom, 2)

        onboardingCopy(
          eyebrow: "YOUR AI",
          title: "Chat your way",
          message: "Use one focused chat app with the AI providers and models you already choose.",
          context: context
        )

      case .providers:
        onboardingSymbol("key.horizontal.fill", context: context)
        onboardingCopy(
          eyebrow: "YOUR PROVIDERS",
          title: "Bring your own keys",
          message: "Connect provider accounts directly. Credentials stay in Keychain on this iPhone.",
          context: context
        )

      case .workspace:
        onboardingSymbol("square.stack.3d.up.fill", context: context)
        onboardingCopy(
          eyebrow: "YOUR WORKSPACE",
          title: "Projects and plugins",
          message: "Organize chats into projects and connect MCP tools when you need a more capable workflow.",
          context: context
        )
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var coloredWordmark: some View {
    HStack(spacing: 0) {
      Text("B").foregroundStyle(Color(red: 0.25, green: 0.49, blue: 1.00))
      Text("Y").foregroundStyle(Color(red: 0.66, green: 0.34, blue: 0.96))
      Text("O").foregroundStyle(Color(red: 0.13, green: 0.79, blue: 0.89))
      Text("K").foregroundStyle(Color(red: 1.00, green: 0.38, blue: 0.47))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("BYOK")
  }

  private func onboardingSymbol(
    _ systemImage: String,
    context: FoundationOnboardingPageContext
  ) -> some View {
    Image(systemName: systemImage)
      .font(.system(size: 38, weight: .semibold))
      .foregroundStyle(context.theme.primary)
      .frame(width: 92, height: 92)
      .background(context.theme.primary.opacity(0.12), in: Circle())
      .overlay(Circle().stroke(context.theme.primary.opacity(0.16), lineWidth: 1))
  }

  private func onboardingCopy(
    eyebrow: String,
    title: String,
    message: String,
    context: FoundationOnboardingPageContext
  ) -> some View {
    VStack(spacing: 11) {
      Text(eyebrow)
        .font(.caption2.weight(.bold))
        .tracking(1.4)
        .foregroundStyle(context.theme.primary)

      Text(title)
        .font(.system(size: 31, weight: .bold, design: .rounded))
        .foregroundStyle(context.primaryForeground)
        .multilineTextAlignment(.center)

      Text(message)
        .font(.body)
        .foregroundStyle(context.secondaryForeground)
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
