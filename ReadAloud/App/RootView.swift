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
    @State private var readerPresented = false
    @State private var readerRuntime: ProjectRuntime?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let runtime = runtimeManager.playerRuntime,
               runtimeManager.readerProjectID != runtime.id,
               let itemID = runtime.playerControlItemID() {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            readerRuntime = runtime
                            runtimeManager.makeActive(runtime)
                            readerPresented = true
                        } label: {
                            HStack(spacing: 10) {
                                ProjectArtworkView(
                                    url: runtime.artworkURL,
                                    sourceType: runtime.project?.source.type ?? .paste,
                                    width: 32, height: 40
                                )
                                .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(runtime.project?.title ?? "ReadAloud")
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text(runtime.itemState(itemID)?.item.title ?? "Chapter")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the audio player and Reader.")

                        ProjectPlayerPlayButton(
                            runtime: runtime, itemID: itemID, diameter: 44,
                            onError: { errorMessage = $0 }
                        )

                        Button { runtime.stopPlayback() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop and close player")
                    }

                    HStack(spacing: 8) {
                        if runtime.isPlayerPreparing {
                            ProgressView().controlSize(.mini)
                        }
                        Text(runtime.playerStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        ProgressView(value: runtime.playerProgress(for: itemID))
                            .accessibilityLabel("Chapter playback progress")
                            .accessibilityValue(runtime.playerProgress(for: itemID)
                                .formatted(.percent.precision(.fractionLength(0))))
                    }
                }
                .projectPlayerCard()
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
}
