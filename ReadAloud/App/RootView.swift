import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase)
    private var scenePhase

    @Environment(ProjectRuntimeManager.self)
    private var runtimeManager

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProjectMiniPlayerHost()
        }
        .onChange(of: scenePhase) {
            _, phase in

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

private struct ProjectMiniPlayerHost: View {
    @Environment(ProjectRuntimeManager.self) private var runtimeManager
    @State private var isPlayerExpanded = false
    @State private var readerPresented = false
    @State private var readerRuntime: ProjectRuntime?
    @State private var voicePresented = false
    @State private var speedPresented = false
    @State private var narrationItemID: UUID?
    @State private var settingsModel: ProjectDetailModel?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let runtime = runtimeManager.playerRuntime,
               runtimeManager.readerProjectID != runtime.id,
               let itemID = runtime.playerControlItemID() {
                ProjectPlayerExpandableCard(isExpanded: $isPlayerExpanded) {
                    ProjectPlayerCompactContent(
                        runtime: runtime,
                        itemID: itemID,
                        onError: { errorMessage = $0 }
                    )
                } expanded: {
                    ProjectPlayerExpandedContent(
                        runtime: runtime,
                        itemID: itemID,
                        onError: { errorMessage = $0 },
                        onSeek: {},
                        onChapterChanged: {},
                        onVoice: {
                            openNarrationPicker(runtime: runtime, itemID: itemID, voice: true)
                        },
                        onSpeed: {
                            openNarrationPicker(runtime: runtime, itemID: itemID, voice: false)
                        },
                        onOpenReader: {
                            openReader(runtime)
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $readerPresented, onDismiss: { readerRuntime = nil }) {
            if let runtime = readerRuntime {
                NavigationStack {
                    ProjectReaderView(
                        runtime: runtime,
                        initialItemID: runtime.playerControlItemID() ?? runtime.continueItemID
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { readerPresented = false }
                        }
                    }
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
        .onChange(of: runtimeManager.loadedRuntimeIDs) { _, ids in
            if let runtime = readerRuntime, !ids.contains(runtime.id) {
                readerPresented = false
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

    private func openReader(_ runtime: ProjectRuntime) {
        readerRuntime = runtime
        runtimeManager.makeActive(runtime)
        readerPresented = true
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
              let runtime = runtimeManager.playerRuntime,
              runtime.activity.activeItemID == itemID else { return }
        runtime.stopPlayback()
    }
}
