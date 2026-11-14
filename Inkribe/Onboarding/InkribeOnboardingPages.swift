import AppFoundation
import SwiftUI

struct InkribeOnboardingPageView: View {
    let page: InkribeOnboardingPage
    let context: FoundationOnboardingPageContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 30

    var body: some View {
        ViewThatFits(in: .vertical) {
            pageContent(compact: false)
            pageContent(compact: true)
        }
        .accessibilityIdentifier("onboarding.\(page.rawValue)")
    }

    private func pageContent(compact: Bool) -> some View {
        VStack(spacing: compact ? 16 : 24) {
            hero(compact: compact)
                .scaleEffect(heroScale)
                .opacity(heroOpacity)
                .animation(reduceMotion ? nil : Animation.smooth(duration: 0.35), value: context.isSelected)
                .accessibilityHidden(true)

            copy
        }
        .padding(.horizontal, 4)
        .padding(.vertical, compact ? 2 : 8)
    }

    private var heroScale: CGFloat {
        reduceMotion || context.isSelected ? 1 : 0.94
    }

    private var heroOpacity: Double {
        reduceMotion || context.isSelected ? 1 : 0.55
    }

    private var copy: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: page.systemImage)
                    .accessibilityHidden(true)
                Text(page.eyebrow.uppercased())
                    .tracking(1.4)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(context.theme.primary)

            Text(page.title)
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(context.primaryForeground)
                .fixedSize(horizontal: false, vertical: true)

            Text(page.message)
                .font(.body)
                .foregroundStyle(context.secondaryForeground)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func hero(compact: Bool) -> some View {
        switch page {
        case .importVideo:
            ImportOnboardingHero(context: context, compact: compact)
        case .transcribe:
            TranscribeOnboardingHero(context: context, compact: compact)
        case .style:
            StyleOnboardingHero(context: context, compact: compact)
        }
    }
}

private struct ImportOnboardingHero: View {
    let context: FoundationOnboardingPageContext
    let compact: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(context.theme.primary.opacity(0.14))
                .frame(width: compact ? 160 : 190, height: compact ? 112 : 136)
                .rotationEffect(.degrees(-8))

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(context.theme.secondary.opacity(0.14))
                .frame(width: compact ? 160 : 190, height: compact ? 112 : 136)
                .rotationEffect(.degrees(7))

            VStack(spacing: compact ? 8 : 12) {
                HStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        context.theme.primary.opacity(0.60),
                                        context.theme.secondary.opacity(0.42),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: compact ? 30 : 38, height: compact ? 42 : 52)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add clips")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(context.primaryForeground)
            }
            .padding(compact ? 12 : 16)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous)
                    .strokeBorder(context.theme.primary.opacity(0.18))
            }
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
        .frame(height: compact ? 150 : 190)
    }
}

private struct TranscribeOnboardingHero: View {
    let context: FoundationOnboardingPageContext
    let compact: Bool

    private let levels: [CGFloat] = [
        18, 32, 22, 46, 28, 58, 34, 48, 24, 40, 20, 34, 16, 28, 14, 22, 12,
    ]

    var body: some View {
        ZStack {
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array(levels.enumerated()), id: \.offset) { item in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    context.theme.primary.opacity(0.70),
                                    context.theme.secondary.opacity(0.50),
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 4, height: compact ? item.element * 0.65 : item.element)
                }
            }
            .frame(height: compact ? 74 : 112)
            .padding(.horizontal, compact ? 14 : 20)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(context.theme.primary.opacity(0.12))
            }

            VStack(spacing: 5) {
                Text("Your words,")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(context.primaryForeground)

                Text("captioned.")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(context.theme.primary)

                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                    Text("On-device")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(context.secondaryForeground)
            }
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 10 : 13)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(context.theme.primary.opacity(0.20))
            }
            .offset(y: compact ? 30 : 46)
        }
        .frame(height: compact ? 150 : 190)
    }
}

private struct StyleOnboardingHero: View {
    let context: FoundationOnboardingPageContext
    let compact: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(context.theme.secondary.opacity(0.13))
                .frame(width: compact ? 200 : 238, height: compact ? 126 : 150)
                .rotationEffect(.degrees(-5))

            VStack(spacing: compact ? 10 : 14) {
                HStack(spacing: 8) {
                    styleCard("Aa", filled: true, compact: compact)
                    styleCard("Aa", filled: false, compact: compact)
                    styleCard("Aa", filled: false, compact: compact)
                }

                HStack(spacing: 8) {
                    exportChip("MP4", systemImage: "film.fill", compact: compact)
                    exportChip("SRT", systemImage: "doc.text.fill", compact: compact)
                }
            }
            .padding(compact ? 14 : 18)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: compact ? 22 : 26, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 22 : 26, style: .continuous)
                    .strokeBorder(context.theme.primary.opacity(0.18))
            }
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
        .frame(height: compact ? 150 : 190)
    }

    private func styleCard(_ text: String, filled: Bool, compact: Bool) -> some View {
        Text(text)
            .font(.system(size: compact ? 18 : 22, weight: .heavy, design: .rounded))
            .foregroundStyle(filled ? Color.white : context.theme.primary)
            .frame(width: compact ? 46 : 56, height: compact ? 40 : 48)
            .background(
                filled ? context.theme.primary.opacity(0.85) : context.theme.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(context.theme.primary.opacity(0.16))
            }
    }

    private func exportChip(_ title: String, systemImage: String, compact: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(context.primaryForeground)
            .padding(.horizontal, compact ? 9 : 11)
            .padding(.vertical, compact ? 6 : 7)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(context.theme.primary.opacity(0.14))
            }
    }
}