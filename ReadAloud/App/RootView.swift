import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase)
    private var scenePhase

    @Environment(ProjectRuntimeManager.self)
    private var runtimeManager

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
    @Environment(ProjectRuntimeManager.self)
    private var runtimeManager

    @State private var readerPresented = false

    var body: some View {
        Group {
            if let runtime =
                    runtimeManager.playbackRuntime,
               runtimeManager.readerProjectID
                != runtime.id
            {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        Button {
                            runtimeManager
                                .makeActive(runtime)
                            readerPresented = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(
                                    systemName:
                                        "waveform"
                                )
                                .foregroundStyle(
                                    .secondary
                                )

                                VStack(
                                    alignment: .leading,
                                    spacing: 2
                                ) {
                                    Text(
                                        runtime.project?
                                            .title
                                            ?? "ReadAloud"
                                    )
                                    .font(
                                        .subheadline
                                            .weight(
                                                .semibold
                                            )
                                    )
                                    .lineLimit(1)

                                    Text(
                                        miniPlayerSubtitle(
                                            runtime
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(
                                        .secondary
                                    )
                                    .lineLimit(1)
                                }
                            }
                            .contentShape(
                                Rectangle()
                            )
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 8)

                        Button {
                            if runtime
                                .isPlaybackPaused
                            {
                                runtime
                                    .resumePlayback()
                            } else {
                                runtime
                                    .pausePlayback()
                            }
                        } label: {
                            Image(
                                systemName:
                                    runtime
                                        .isPlaybackPaused
                                    ? "play.fill"
                                    : "pause.fill"
                            )
                            .frame(
                                width: 34,
                                height: 34
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            runtime
                                .isPlaybackPaused
                            ? "Resume"
                            : "Pause"
                        )
                    }

                    ProgressView(
                        value:
                            runtime.activity
                                .itemProgress
                    )
                    .accessibilityLabel(
                        "Chapter playback progress"
                    )
                    .accessibilityValue(
                        Text(
                            runtime.activity
                                .itemProgress,
                            format:
                                .percent.precision(
                                    .fractionLength(0)
                                )
                        )
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.regularMaterial)
            }
        }
        .sheet(
            isPresented: $readerPresented
        ) {
            if let runtime =
                runtimeManager.playbackRuntime
                    ?? runtimeManager
                        .activeRuntime
            {
                NavigationStack {
                    ProjectReaderView(
                        runtime: runtime,
                        initialItemID:
                            runtime.activity
                                .activeItemID
                            ?? runtime
                                .continueItemID
                    )
                }
            }
        }
    }

    private func miniPlayerSubtitle(
        _ runtime: ProjectRuntime
    ) -> String {
        let itemTitle =
            runtime.activity
                .activeItemID
                .flatMap {
                    runtime.itemState($0)?
                        .item.title
                }
                ?? runtime.currentItemID
                    .flatMap {
                        runtime.itemState($0)?
                            .item.title
                    }

        let status: String =
            switch runtime
                .activity
                .playbackState
            {
            case .idle:
                "Idle"
            case .loading:
                "Loading…"
            case .warmingUp:
                "Preparing…"
            case .synthesizing(
                let current,
                let total
            ):
                "Preparing \(current) of \(total)…"
            case .playing:
                "Playing"
            case .paused:
                "Paused"
            case .finished:
                "Finished"
            case .failed:
                "Needs attention"
            }

        return itemTitle.map {
            "\($0) · \(status)"
        } ?? status
    }
}
