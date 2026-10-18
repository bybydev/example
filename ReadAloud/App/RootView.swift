import AppFoundation
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase)
    private var scenePhase

    @Environment(ProjectRuntimeManager.self)
    private var runtimeManager

    @Environment(PurchaseManager.self) private var purchases
    @Environment(ThemeManager.self) private var themes
    @AppStorage(ReadAloudPreferences.Key.hasCompletedOnboarding)
    private var hasCompletedOnboarding = false

    var body: some View {
        @Bindable var runtimeManager = runtimeManager
        NavigationStack {
            LibraryView()
                .navigationDestination(item: $runtimeManager.playerReaderTarget) { target in
                    ProjectReaderRuntimeHost(
                        projectID: target.projectID,
                        initialItemID: target.itemID,
                        initialTitle: target.title
                    )
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProjectGlobalPlayerHost()
        }
        .parsedOutputPreparationPresenter(priority: 0)
        .sheet(isPresented: $runtimeManager.isListeningLimitPresented) {
            ReadAloudProUpsell(reason: .listening)
        }
        // Keep the Library/navigation tree mounted while the first-run flow
        // is presented, matching the shared Spokio/AppFoundation pattern.
        .fullScreenCover(
            isPresented: Binding(
                get: { !hasCompletedOnboarding },
                set: { presented in
                    if !presented { hasCompletedOnboarding = true }
                }
            )
        ) {
            ReadAloudOnboardingView {
                hasCompletedOnboarding = true
            }
            .appFoundationTheme(themes, purchaseManager: purchases)
            .interactiveDismissDisabled()
        }
        .task {
            runtimeManager.setApplicationActive(scenePhase == .active)
            await runtimeManager.recoverPendingGeneration()
        }
        .onChange(of: scenePhase) {
            _, phase in
            runtimeManager.setApplicationActive(phase == .active)

            switch phase {
            case .active:
                SpeechPlaybackDiagnostics.applicationState("active")
                Task { await runtimeManager.recoverPendingGeneration() }
            case .inactive: SpeechPlaybackDiagnostics.applicationState("inactive")
            case .background: SpeechPlaybackDiagnostics.applicationState("background")
            @unknown default: break
            }
            guard phase != .active
            else {
                return
            }

            Task {
                await runtimeManager
                    .persistPlaybackCheckpoints()
            }
        }
    }
}

/// Production onboarding is shared with the Debug replay. Completion state
/// belongs to the host so replaying the flow never changes first-run state.
@MainActor
struct ReadAloudOnboardingView: View {
    // Developer replay supplies a plain closure. Keep it isolated in this view
    // and invoke it from Foundation's main-actor callback without converting it.
    let onCompletion: () -> Void

    var body: some View {
        FoundationOnboardingView(
            pages: Self.pages,
            completionTitle: "Open Library"
        ) {
            self.onCompletion()
        }
    }

    private static let pages: [FoundationOnboardingPage] = [
        FoundationOnboardingPage(
            id: "library",
            systemImage: "books.vertical.fill",
            eyebrow: "Your listening library",
            title: "Welcome to Riidrr",
            message: "Add EPUBs, PDFs, documents, web articles, or your own text. Keep everything together in one listening library.",
            headerTitle: "WELCOME",
            headerSystemImage: "headphones"
        ),
        FoundationOnboardingPage(
            id: "on-device",
            systemImage: "iphone",
            eyebrow: "On-device English speech",
            title: "Listen wherever you are",
            message: "Speech is generated on your iPhone with bundled English voices. Listen to imported content offline, or prepare chapters ahead of time.",
            headerTitle: "ON YOUR IPHONE",
            headerSystemImage: "iphone"
        ),
        FoundationOnboardingPage(
            id: "playback",
            systemImage: "play.circle.fill",
            eyebrow: "Listen your way",
            title: "Pick up where you left off",
            message: "Read along, adjust playback speed, and set a sleep timer. Your listening position is saved so you can continue later.",
            headerTitle: "READY TO LISTEN",
            headerSystemImage: "play.fill"
        ),
    ]
}

/// The only player-card host. Reader navigation stays on the root stack so
/// Library, book details, and Reader all share this same bottom inset.
private struct ProjectGlobalPlayerHost: View {
    @Environment(ProjectRuntimeManager.self) private var runtimeManager
    @State private var voicePresented = false
    @State private var speedPresented = false
    @State private var narrationItemID: UUID?
    @State private var settingsModel: ProjectDetailModel?
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var runtimeManager = runtimeManager
        Group {
            if let runtime = runtimeManager.playerRuntime,
               !runtime.isPlayerDismissed,
               let itemID = runtime.playerControlItemID() {
                ProjectPlayerExpandableCard(isExpanded: $runtimeManager.isPlayerExpanded) {
                    ProjectPlayerCompactContent(
                        runtime: runtime,
                        itemID: itemID,
                        onError: { errorMessage = $0 },
                        onExpand: { runtimeManager.isPlayerExpanded = true },
                        onClose: { closePlayer(runtime) }
                    )
                } expanded: {
                    ProjectPlayerExpandedContent(
                        runtime: runtime,
                        itemID: itemID,
                        onError: { errorMessage = $0 },
                        onSeek: { runtimeManager.requestReaderFollow() },
                        onChapterChanged: { runtimeManager.requestReaderFollow() },
                        onVoice: {
                            openNarrationPicker(runtime: runtime, itemID: itemID, voice: true)
                        },
                        onSpeed: {
                            openNarrationPicker(runtime: runtime, itemID: itemID, voice: false)
                        },
                        onCollapse: { runtimeManager.isPlayerExpanded = false },
                        onClose: { closePlayer(runtime) },
                        onOpenReader: {
                            runtimeManager.openPlayerReader()
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $voicePresented) {
            if let settingsModel, let narrationItemID {
                ItemVoicePicker(
                    model: settingsModel,
                    itemID: narrationItemID,
                    onChanged: { narrationChanged() }
                )
            }
        }
        .sheet(isPresented: $speedPresented) {
            if let settingsModel, let narrationItemID {
                ItemSpeedPicker(
                    model: settingsModel,
                    itemID: narrationItemID,
                    onChanged: { narrationChanged() }
                )
            }
        }
        .alert("Playback Unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func closePlayer(_ runtime: ProjectRuntime) {
        runtimeManager.closePlayer(runtime)
    }

    private func openNarrationPicker(
        runtime: ProjectRuntime,
        itemID: UUID,
        voice: Bool
    ) {
        narrationItemID = itemID
        settingsModel = ProjectDetailModel(runtime: runtime)
        if voice {
            voicePresented = true
        } else {
            speedPresented = true
        }
    }

    private func narrationChanged() {
        guard let itemID = narrationItemID,
              let runtime = settingsModel?.runtime,
              runtimeManager.playerRuntime === runtime,
              runtime.activity.activeItemID == itemID else { return }
        runtime.stopPlayback()
    }
}



