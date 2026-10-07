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

    var body: some View {
        if let runtime = runtimeManager.activeRuntime,
           runtime.activity.hasActivePlaybackWork {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.project?.title ?? "ReadAloud")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(activityLabel(runtime.activity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    runtime.stopPlayback()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop Playback")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
    }

    private func activityLabel(
        _ activity: ProjectRuntimeActivity
    ) -> String {
        switch activity.playbackState {
        case .idle:
            return "Idle"
        case .loading:
            return "Loading…"
        case .warmingUp:
            return "Preparing…"
        case .synthesizing(let current, let total):
            return "Preparing \(current) of \(total)…"
        case .playing:
            return "Playing"
        case .finished:
            return "Finished"
        case .failed:
            return "Playback needs attention"
        }
    }
}
