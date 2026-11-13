import AppFoundation
import SwiftUI

enum InkribeOnboardingStorage {
    /// Versioned so a future onboarding redesign can opt into a fresh first run.
    static let completedKey = "com.hoangbkit.inkribe.ios.onboarding.v1"
}

enum InkribeOnboardingPage: String, CaseIterable, Identifiable {
    case importVideo
    case transcribe
    case style

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .importVideo: "film.stack.fill"
        case .transcribe: "captions.bubble.fill"
        case .style: "sparkles"
        }
    }

    var eyebrow: String {
        switch self {
        case .importVideo: "Import"
        case .transcribe: "On device"
        case .style: "Finish"
        }
    }

    var title: String {
        switch self {
        case .importVideo: "Bring your videos"
        case .transcribe: "Captions, without the cloud"
        case .style: "Style it. Share it."
        }
    }

    var message: String {
        switch self {
        case .importVideo:
            "Pick clips from Photos or Files, trim them, and arrange your story on the timeline."
        case .transcribe:
            "Whisper transcribes privately on your iPhone. Download a model once, then fix any word or timing."
        case .style:
            "Apply animated caption styles, add music, and export MP4 or SRT ready to share."
        }
    }
}

/// App-owned three-page flow. AppFoundation owns paging, skip/continue,
/// theme resolution, the page indicator and completion.
struct InkribeOnboardingView: View {
    let onCompletion: @MainActor () -> Void

    var body: some View {
        FoundationOnboardingView(
            pages: InkribeOnboardingPage.allCases,
            configuration: FoundationOnboardingConfiguration(
                headerTitle: "INKRIBE",
                headerSystemImage: "captions.bubble.fill",
                showsSkipButton: true,
                skipTitle: "Skip",
                continueTitle: "Continue",
                completionTitle: "Start creating",
                showsPageIndicator: true,
                centersPageContent: true,
                contentHorizontalPadding: 24,
                contentVerticalPadding: 8
            )
        ) { page, context in
            InkribeOnboardingPageView(page: page, context: context)
        } onCompletion: {
            onCompletion()
        }
        .accessibilityIdentifier("onboarding.flow")
    }
}