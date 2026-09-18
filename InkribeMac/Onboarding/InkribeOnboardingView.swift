import MacAppFoundation
import SwiftUI

enum InkribeOnboardingConfiguration {
    static let id = "inkribe"
    static let stepCount = 4
    static let defaultWidth: CGFloat = 700
    static let defaultHeight: CGFloat = 540
}

@MainActor
struct InkribeOnboardingView: View {
    let onboarding: OnboardingState

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.macAppTheme) private var theme

    var body: some View {
        OnboardingView {
            content
                .id(onboarding.currentStep)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.985))
                )
                .padding(.horizontal, 52)
                .padding(.top, contentTopPadding)
                .padding(.bottom, contentBottomPadding)
        } leadingActions: {
            if onboarding.canGoBack {
                Button("Back") {
                    moveBack()
                }
            }
        } message: {
            OnboardingStepMessage(
                title: stepTitle,
                currentStep: onboarding.currentStep,
                stepCount: onboarding.stepCount
            )
        } trailingActions: {
            Button(onboarding.isLastStep ? "Get Started" : "Continue") {
                continueFlow()
            }
        }
        .frame(
            width: InkribeOnboardingConfiguration.defaultWidth,
            height: InkribeOnboardingConfiguration.defaultHeight
        )
        .background(theme.canvas)
        .clipped()
        .accessibilityIdentifier("Inkribe.Onboarding")
    }

    @ViewBuilder
    private var content: some View {
        switch onboarding.currentStep {
        case 0:
            heroStep(
                systemImage: "waveform.badge.mic",
                title: "Welcome to Inkribe",
                message: "Private speech-to-text for Mac, built around local transcription and durable transcript documents."
            )

        case 1:
            VStack(alignment: .leading, spacing: 16) {
                stepHeading(
                    "Record or import",
                    message: "Start with a microphone recording or existing audio and video. Both paths feed the same local transcription workspace."
                )

                VStack(spacing: 12) {
                    featureRow(
                        icon: "mic.fill",
                        title: "Record",
                        detail: "Capture audio with input-device selection, pause/resume, and level metering."
                    )
                    featureRow(
                        icon: "square.and.arrow.down",
                        title: "Import",
                        detail: "Drop in audio or video and process multiple files through the persistent queue."
                    )
                    featureRow(
                        icon: "text.badge.checkmark",
                        title: "Review",
                        detail: "Edit the transcript beside synchronized playback and timestamped segments."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case 2:
            VStack(alignment: .leading, spacing: 16) {
                stepHeading(
                    "Local by design",
                    message: "Core speech recognition and transcript AI run on this Mac with bundled models."
                )

                VStack(spacing: 12) {
                    featureRow(
                        icon: "lock.shield.fill",
                        title: "No cloud transcription",
                        detail: "Audio and transcript processing stay in Inkribe's local workflow."
                    )
                    featureRow(
                        icon: "cpu",
                        title: "Bundled local models",
                        detail: "Whisper handles speech recognition and Qwen powers transcript cleanup and derived notes."
                    )
                    featureRow(
                        icon: "person.crop.circle.badge.xmark",
                        title: "No account or API key",
                        detail: "The core Record → Transcribe → Edit → AI → Export workflow does not require a service login."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        default:
            heroStep(
                systemImage: "checkmark.circle.fill",
                title: "Ready to transcribe",
                message: "Record something new or import a file. Inkribe will keep the transcript, edits, local AI results, and exports under your control."
            )
        }
    }

    private var contentTopPadding: CGFloat {
        switch onboarding.currentStep {
        case 1, 2: 28
        default: 48
        }
    }

    private var contentBottomPadding: CGFloat {
        switch onboarding.currentStep {
        case 1, 2: 52
        default: 76
        }
    }

    private var stepTitle: String {
        switch onboarding.currentStep {
        case 0: "Welcome"
        case 1: "Create"
        case 2: "Privacy"
        default: "Ready"
        }
    }

    private func heroStep(
        systemImage: String,
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 68, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.accent)

            VStack(spacing: 10) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(theme.textPrimary)

                Text(message)
                    .font(.title3)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stepHeading(_ title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title.bold())
                .foregroundStyle(theme.textPrimary)
            Text(message)
                .font(.body)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featureRow(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 30, height: 30)
                .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(theme.border, lineWidth: 1)
        }
    }

    private func moveBack() {
        if reduceMotion {
            onboarding.goBack()
        } else {
            withAnimation(.snappy(duration: 0.22)) {
                onboarding.goBack()
            }
        }
    }

    private func continueFlow() {
        guard onboarding.isLastStep else {
            if reduceMotion {
                onboarding.goForward()
            } else {
                withAnimation(.snappy(duration: 0.22)) {
                    onboarding.goForward()
                }
            }
            return
        }

        onboarding.complete()
        openWindow(id: InkribeWindowID.main)
        dismissWindow(id: InkribeWindowID.onboarding)
    }
}
