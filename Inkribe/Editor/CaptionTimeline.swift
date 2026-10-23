import SwiftUI
import AppFoundation

/// An overview and accessible scrubber, not a waveform or multi-track editor.
struct CaptionTimeline: View {
    @Environment(\.appFoundationTheme) private var theme
    let snapshot: CaptionSnapshot?
    let selectedCueID: UUID?
    let duration: Double
    let seconds: Double
    var showsOverview = true
    let seek: (Double) -> Void

    var body: some View {
        VStack(spacing: 2) {
            if showsOverview {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        TimelineBars(snapshot: snapshot, selectedCueID: selectedCueID, duration: duration, accent: theme.accentColor)
                            .equatable()
                        Rectangle().fill(.primary)
                            .frame(width: 2)
                            .offset(x: max(0, min(geometry.size.width - 2,
                                geometry.size.width * seconds / max(0.001, duration))))
                    }
                }
                .frame(height: 16)
                .accessibilityHidden(true)
            }
            Slider(value: Binding(get: { min(max(0, seconds), max(0.001, duration)) }, set: seek),
                   in: 0...max(0.001, duration))
                .accessibilityLabel("Project playhead")
                .accessibilityValue(String(format: "%.2f seconds of %.2f", seconds, duration))
                .disabled(duration <= 0)
        }
    }
}

private struct TimelineBars: View, Equatable {
    let snapshot: CaptionSnapshot?
    let selectedCueID: UUID?
    let duration: Double
    let accent: Color
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot?.id == rhs.snapshot?.id && lhs.selectedCueID == rhs.selectedCueID && lhs.duration == rhs.duration && lhs.accent == rhs.accent
    }
    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(.secondary.opacity(0.15)))
            guard let snapshot, duration > 0 else { return }
            for cue in snapshot.cues {
                let start = EditorTime.seconds(cue.interval.start) / duration * size.width
                let end = EditorTime.seconds(cue.interval.end) / duration * size.width
                let rect = CGRect(x: start, y: 2, width: max(1, end - start - 1), height: size.height - 4)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(cue.id == selectedCueID ? accent : accent.opacity(0.65)))
            }
        }
    }
}
