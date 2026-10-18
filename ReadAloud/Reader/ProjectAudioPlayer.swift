import AppFoundation
import SwiftUI

/// Shared controls keep the Reader, mini-player, and runtime in agreement.
struct ProjectPlayerPlayButton: View {
    @Environment(\.appFoundationTheme) private var theme
    let runtime: ProjectRuntime
    let itemID: UUID
    var diameter: CGFloat = 64
    var isProminent = true
    let onError: (String) -> Void

    var body: some View {
        Button {
            do { try runtime.togglePlayer(itemID: itemID) }
            catch { onError(error.localizedDescription) }
        } label: {
            Image(systemName: runtime.playerActionSymbol)
                .font(.system(size: max(20, diameter * 0.36), weight: .semibold))
                .foregroundStyle(isProminent ? theme.backgroundColor : theme.primaryForegroundColor)
                .frame(width: diameter, height: diameter)
                .background(isProminent ? Color.accentColor : Color.clear, in: Circle())
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

/// One normalized timeline for both player sizes. Each distinct chunk cache
/// interval is drawn at its actual chapter position, never as a leading fill.
private struct PlayerBufferedTrack: View {
    let runtime: ProjectRuntime
    let itemID: UUID
    let progress: Double
    let barHeight: CGFloat
    var showsThumb = false

    @State private var ranges: [PlayerBufferedRange] = []

    private var identity: String {
        runtime.playerBufferIdentity(for: itemID)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let played = CGFloat(min(1, max(0, progress)))

            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.18))
                    ForEach(Array(ranges.enumerated()), id: \.offset) { entry in
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.27))
                            .frame(width: width * CGFloat(entry.element.end - entry.element.start))
                            .offset(x: width * CGFloat(entry.element.start))
                    }
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: width * played)
                }
                .frame(height: barHeight)
                .clipShape(Capsule())

                if showsThumb {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 19, height: 19)
                        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                        .offset(x: min(max(0, width * played - 9.5), max(0, width - 19)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .allowsHitTesting(false)
        .task(id: identity) {
            ranges = []
            while !Task.isCancelled {
                let updated = await runtime.playerBufferedRanges(for: itemID)
                guard !Task.isCancelled else { return }
                if ranges != updated { ranges = updated }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
        .onChange(of: identity) { _, _ in ranges = [] }
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
                runtime: runtime,
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
    let runtime: ProjectRuntime
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
            ZStack {
                PlayerBufferedTrack(
                    runtime: runtime,
                    itemID: itemID,
                    progress: value,
                    barHeight: 4,
                    showsThumb: true
                )
                .padding(.horizontal, 12)

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
                // Retain the native seek and VoiceOver behavior.
                .opacity(0.02)
            }
            .frame(height: 36)

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

/// Artwork and labels expand the player. Playback and close have separate
/// hit regions, so neither control changes the player's size.
struct ProjectPlayerCompactContent: View {
    let runtime: ProjectRuntime
    let itemID: UUID
    let onError: (String) -> Void
    let onExpand: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                Button(action: onExpand) {
                    HStack(spacing: 11) {
                        ProjectArtworkView(
                            url: runtime.artworkURL,
                            sourceType: runtime.project?.source.type ?? .paste,
                            width: 38, height: 46
                        )
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(runtime.project?.title ?? "ReadAloud")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand audio player")
                .accessibilityValue("\(runtime.project?.title ?? "ReadAloud"), \(subtitle)")
                .accessibilityHint("Expands the audio player without changing playback.")

                ProjectPlayerPlayButton(
                    runtime: runtime, itemID: itemID,
                    diameter: 44, isProminent: false,
                    onError: onError
                )
                .disabled(runtime.isApplyingPDFReadingPolicy)

                ProjectPlayerCloseButton(action: onClose)
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                PlayerBufferedTrack(
                    runtime: runtime,
                    itemID: itemID,
                    progress: runtime.playerProgress(for: itemID),
                    barHeight: 2
                )
                .frame(height: 2)
                .accessibilityLabel("Chapter playback progress")
                .accessibilityValue(
                    runtime.playerProgress(for: itemID)
                        .formatted(.percent.precision(.fractionLength(0)))
                )
                // This is a passive indicator, not a hard-to-use mini scrubber.
                .allowsHitTesting(false)
            }
        }
    }

    private var subtitle: String {
        if runtime.isPlayerPreparing { return runtime.playerStatus }
        if case .failed = runtime.activity.playbackState {
            return runtime.playerStatus
        }
        return runtime.itemState(itemID)?.item.title ?? "Chapter"
    }
}

private struct ProjectPlayerCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close audio player")
        .accessibilityHint("Stops playback and keeps your listening position.")
    }
}

/// Full controls for the single app-level player.
/// Collapse and close are explicit, separate actions.
struct ProjectPlayerExpandedContent: View {
    let runtime: ProjectRuntime
    let itemID: UUID
    let onError: (String) -> Void
    let onSeek: () -> Void
    let onChapterChanged: () -> Void
    let onVoice: () -> Void
    let onSpeed: () -> Void
    let onCollapse: () -> Void
    let onClose: () -> Void
    var onOpenReader: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse audio player")
                .accessibilityHint("Keeps playback running in the compact player.")

                Spacer(minLength: 8)
                Text("NOW PLAYING")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ProjectPlayerCloseButton(action: onClose)
            }

            if let onOpenReader {
                Button(action: onOpenReader) {
                    bookDetails
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the reader without stopping playback.")
            } else {
                bookDetails
            }

            if runtime.isPlayerPreparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(runtime.playerStatus).font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if case .failed = runtime.activity.playbackState {
                Text(runtime.playerStatus)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Playback error: \(runtime.playerStatus)")
            }

            ProjectPlayerScrubber(
                runtime: runtime, itemID: itemID,
                onError: onError, onSeek: onSeek
            )
            .disabled(!runtime.isPDFReadingReady)

            HStack(spacing: 0) {
                chapterButton(forward: false)
                Spacer(minLength: 0)
                ProjectPlayerSkipButton(
                    forward: false,
                    approximate: runtime.playerDuration(for: itemID) == nil,
                    enabled: runtime.canSkipPlayback
                ) {
                    seek(by: -Double(ReadAloudPreferences.skipInterval))
                }
                Spacer(minLength: 0)
                ProjectPlayerPlayButton(
                    runtime: runtime, itemID: itemID,
                    onError: onError
                )
                Spacer(minLength: 0)
                ProjectPlayerSkipButton(
                    forward: true,
                    approximate: runtime.playerDuration(for: itemID) == nil,
                    enabled: runtime.canSkipPlayback
                ) {
                    seek(by: Double(ReadAloudPreferences.skipInterval))
                }
                Spacer(minLength: 0)
                chapterButton(forward: true)
            }
            .disabled(runtime.isApplyingPDFReadingPolicy)

            HStack(spacing: 12) {
                Button(action: onVoice) {
                    Label(
                        ReadAloudNarrationCatalog.voiceName(
                            runtime.itemState(itemID)?.resolved.voiceID ?? ""
                        ),
                        systemImage: "waveform"
                    )
                    .lineLimit(1)
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("Change narration voice")
                Spacer(minLength: 4)
                Button(action: onSpeed) {
                    Label(
                        (runtime.itemState(itemID)?.resolved.speed ?? 1)
                            .formatted(.number.precision(.fractionLength(1))) + "×",
                        systemImage: "speedometer"
                    )
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("Change narration speed")
                Spacer(minLength: 0)
                ProjectPlayerSleepTimer(runtime: runtime)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .disabled(!runtime.isPDFReadingReady)
        }
    }

    private var bookDetails: some View {
        HStack(spacing: 13) {
            ProjectArtworkView(
                url: runtime.artworkURL,
                sourceType: runtime.project?.source.type ?? .paste,
                width: 48, height: 64
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(runtime.project?.title ?? "ReadAloud")
                    .font(.headline)
                    .lineLimit(2)
                if let author = runtime.project?.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(runtime.itemState(itemID)?.item.title ?? "Chapter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if onOpenReader != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func seek(by seconds: Double) {
        do {
            try runtime.seekPlayback(by: seconds)
            onSeek()
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func chapterButton(forward: Bool) -> some View {
        let targetID = runtime.adjacentPlayerItem(
            to: itemID, delta: forward ? 1 : -1
        )
        return Button {
            guard let targetID else { return }
            do {
                try runtime.changePlayerChapter(to: targetID)
                onChapterChanged()
            } catch {
                onError(error.localizedDescription)
            }
        } label: {
            Image(systemName:
                forward ? "forward.end.fill" : "backward.end.fill"
            )
            .font(.system(size: 17, weight: .semibold))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(targetID == nil)
        .accessibilityLabel(forward ? "Next chapter" : "Previous chapter")
    }
}

/// Contents own their buttons. Empty card space never toggles the player,
/// and outer margins cannot activate reader rows behind the safe-area inset.
struct ProjectPlayerExpandableCard<Compact: View, Expanded: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isExpanded: Bool
    private let compact: () -> Compact
    private let expanded: () -> Expanded

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder compact: @escaping () -> Compact,
        @ViewBuilder expanded: @escaping () -> Expanded
    ) {
        _isExpanded = isExpanded
        self.compact = compact
        self.expanded = expanded
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isExpanded {
                    expanded()
                } else {
                    compact()
                }
            }
            .frame(maxWidth: .infinity)
            .projectPlayerCard(compact: !isExpanded)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isExpanded)
        // Consume the outer margin too; it must not activate Reader rows
        // behind the safe-area-inset player.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { }
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ProjectPlayerCard: ViewModifier {
    @Environment(\.appFoundationTheme) private var theme
    var compact = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(theme.primaryForegroundColor)
            .padding(.horizontal, compact ? 10 : 18)
            .padding(.vertical, 8)
            .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: compact ? 20 : 24))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 20 : 24)
                    .strokeBorder(theme.primaryForegroundColor.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: theme.primaryForegroundColor.opacity(0.08), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .padding(.vertical, compact ? 3 : 8)
    }
}

extension View {
    func projectPlayerCard(compact: Bool = false) -> some View {
        modifier(ProjectPlayerCard(compact: compact))
    }
}
