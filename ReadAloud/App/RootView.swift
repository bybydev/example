import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack {
                    LibraryView()
                }
            }

            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProjectMiniPlayerHost()
        }
    }
}

private struct ProjectMiniPlayerHost: View {
    @Environment(ProjectRuntimeManager.self) private var runtimeManager
    @State private var readerPresented = false

    var body: some View {
        Group {
            if let runtime = runtimeManager.activeRuntime,
               runtimeManager.readerProjectID != runtime.id,
               runtime.activity.hasActivePlaybackWork {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        Button {
                            readerPresented = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "waveform")
                                    .foregroundStyle(.secondary)

                                VStack(
                                    alignment: .leading,
                                    spacing: 2
                                ) {
                                    Text(
                                        runtime.project?.title
                                            ?? "ReadAloud"
                                    )
                                    .font(
                                        .subheadline.weight(
                                            .semibold
                                        )
                                    )
                                    .lineLimit(1)

                                    Text(
                                        miniPlayerSubtitle(runtime)
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            if runtime.isPlaybackPaused {
                                runtime.resumePlayback()
                            } else {
                                runtime.pausePlayback()
                            }
                        } label: {
                            Image(
                                systemName:
                                    runtime.isPlaybackPaused
                                    ? "play.fill"
                                    : "pause.fill"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            runtime.isPlaybackPaused
                                ? "Resume"
                                : "Pause"
                        )

                        Button {
                            runtime.stopPlayback()
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop Playback")
                    }

                    ProgressView(
                        value: runtime.activity.projectProgress
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.regularMaterial)
            }
        }
        .sheet(isPresented: $readerPresented) {
            if let runtime = runtimeManager.activeRuntime {
                NavigationStack {
                    ProjectReaderView(
                        runtime: runtime,
                        initialItemID:
                            runtime.activity.activeItemID
                            ?? runtime.continueItemID
                    )
                }
            }
        }
    }

    private func miniPlayerSubtitle(
        _ runtime: ProjectRuntime
    ) -> String {
        let itemTitle = runtime.activity.activeItemID
            .flatMap { runtime.itemState($0)?.item.title }

        switch runtime.activity.playbackState {
        case .idle:
            return itemTitle ?? "Idle"
        case .loading:
            return itemTitle.map { "\($0) · Loading…" }
                ?? "Loading…"
        case .warmingUp:
            return itemTitle.map { "\($0) · Preparing…" }
                ?? "Preparing…"
        case .synthesizing(let current, let total):
            let status = "Preparing \(current) of \(total)…"
            return itemTitle.map { "\($0) · \(status)" }
                ?? status
        case .playing:
            return itemTitle.map { "\($0) · Playing" }
                ?? "Playing"
        case .paused:
            return itemTitle.map { "\($0) · Paused" }
                ?? "Paused"
        case .finished:
            return itemTitle ?? "Finished"
        case .failed:
            return itemTitle.map {
                "\($0) · Needs attention"
            } ?? "Playback needs attention"
        }
    }
}
