import AppFoundation
import SwiftUI

/// Shared controls keep the Reader, mini-player, and runtime in agreement.
struct ProjectPlayerPlayButton: View {
    @Environment(\.appFoundationTheme) private var theme
    let runtime: ProjectRuntime
    let itemID: UUID
    var diameter: CGFloat = 64
    let onError: (String) -> Void

    var body: some View {
        Button {
            do { try runtime.togglePlayer(itemID: itemID) }
            catch { onError(error.localizedDescription) }
        } label: {
            Image(systemName: runtime.isPlaybackActive && !runtime.isPlaybackPaused
                ? "pause.fill" : "play.fill")
                .font(.system(size: diameter * 0.36, weight: .semibold))
                .foregroundStyle(theme.backgroundColor)
                .frame(width: diameter, height: diameter)
                .background(Color.accentColor.gradient, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(runtime.playerActionLabel)
        .accessibilityHint(runtime.isPlayerPreparing ? "Audio is preparing. You can pause while waiting." : "")
    }
}

struct ProjectPlayerSkipButton: View {
    let forward: Bool
    let approximate: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: forward ? "goforward" : "gobackward")
                .font(.system(size: 30, weight: .regular))
                .overlay {
                    Text("\(ReadAloudPreferences.skipInterval)")
                        .font(.system(size: 10, weight: .semibold))
                        .offset(y: 2)
                        .accessibilityHidden(true)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Skip \(forward ? "forward" : "backward") \(approximate ? "about " : "")\(ReadAloudPreferences.skipInterval) seconds")
    }
}

struct ProjectPlayerScrubber: View {
    let runtime: ProjectRuntime
    let itemID: UUID
    let onError: (String) -> Void
    var onSeek: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            PlayerScrubberContent(
                itemID: itemID,
                progress: runtime.playerProgress(for: itemID),
                duration: runtime.playerDuration(for: itemID),
                enabled: !runtime.isPlayerPreparing,
                onSeek: { progress in
                    do {
                        try runtime.seekPlayer(toProgress: progress, itemID: itemID)
                        onSeek()
                    }
                    catch { onError(error.localizedDescription) }
                }
            )
        }
    }
}

struct ProjectPlayerSleepTimer: View {
    let runtime: ProjectRuntime

    var body: some View {
        Menu {
            Button("Off") { runtime.clearSleepTimer() }
            ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") { runtime.setSleepTimer(minutes: minutes) }
            }
            Button("End of chapter") { runtime.stopAtChapterEnd() }
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Label(label(at: context.date), systemImage: "moon.zzz")
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(runtime.stopsAtChapterEnd ? "End of chapter"
            : runtime.sleepTimerDeadline == nil ? "Off" : "On")
    }

    private func label(at date: Date) -> String {
        if runtime.stopsAtChapterEnd { return "Chapter" }
        if let deadline = runtime.sleepTimerDeadline {
            return "\(max(1, Int(ceil(deadline.timeIntervalSince(date) / 60))))m"
        }
        return "Sleep"
    }
}

private struct PlayerScrubberContent: View {
    let itemID: UUID
    let progress: Double
    let duration: Double?
    let enabled: Bool
    let onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var draggedProgress = 0.0
    @State private var dragItemID: UUID?
    @State private var dragDuration: Double?

    private var value: Double { isDragging ? draggedProgress : progress }

    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(
                get: { value },
                set: { newValue in
                    draggedProgress = newValue
                }
            ), in: 0...1, onEditingChanged: { editing in
                if editing {
                    draggedProgress = progress
                    dragItemID = itemID
                    dragDuration = duration
                    isDragging = true
                } else {
                    let target = draggedProgress
                    let canCommit = isDragging && dragItemID == itemID
                        && dragDuration == duration && enabled
                    isDragging = false
                    if canCommit { onSeek(target) }
                }
            })
            .disabled(!enabled)
            .accessibilityLabel(duration == nil ? "Chapter position" : "Playback position")
            .accessibilityValue(duration.map { Self.time(value * $0) }
                ?? value.formatted(.percent.precision(.fractionLength(0))))
            .accessibilityHint(duration == nil ? "Jumps to the nearest passage." : "Seeks within this chapter.")
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                switch direction {
                case .increment: onSeek(min(1, progress + 0.05))
                case .decrement: onSeek(max(0, progress - 0.05))
                @unknown default: break
                }
            }

            HStack {
                if let duration {
                    Text(Self.time(value * duration))
                    Spacer()
                    Text("−" + Self.time((1 - value) * duration))
                } else {
                    Text("Chapter position · jumps to passages")
                    Spacer(minLength: 8)
                    Text(value, format: .percent.precision(.fractionLength(0)))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onChange(of: itemID) { _, _ in isDragging = false }
        .onChange(of: duration) { _, _ in isDragging = false }
        .onChange(of: enabled) { _, enabled in if !enabled { isDragging = false } }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(min(seconds, 359_999))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ProjectPlayerCard: ViewModifier {
    @Environment(\.appFoundationTheme) private var theme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(theme.primaryForegroundColor)
            .padding(16)
            .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(theme.primaryForegroundColor.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: theme.primaryForegroundColor.opacity(0.10), radius: 14, y: 5)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

extension View {
    func projectPlayerCard() -> some View { modifier(ProjectPlayerCard()) }
}
