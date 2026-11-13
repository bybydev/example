import SwiftUI

/// Keeps the library and first-run onboarding behind one root switch while the
/// app-level environment, theme and purchase modifiers stay in `InkribeApp`.
struct InkribeRootView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(InkribeOnboardingStorage.completedKey)
    private var hasCompletedOnboarding = false
    @State private var didEnterBackground = false

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                ProjectsView()
            } else {
                InkribeOnboardingView {
                    withAnimation(.smooth(duration: 0.3)) {
                        hasCompletedOnboarding = true
                    }
                }
            }
        }
        // Durable jobs must recover even while the first-run flow covers the
        // library, so processing startup and scene tracking live above the switch.
        .task { await model.processing.start() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            updateProcessingScene(phase)
        }
    }

    private func updateProcessingScene(_ phase: ScenePhase) {
        if phase == .background { didEnterBackground = true }
        let returning = phase == .active && didEnterBackground
        if phase == .active { didEnterBackground = false }
        model.processing.setForeground(phase == .active, recoveringFromBackground: returning)
    }
}