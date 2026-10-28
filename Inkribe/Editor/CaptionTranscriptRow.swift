import AppFoundation
import SwiftUI

/// Row taps select/seek; only the selected row's top-left action opens editing.
struct CaptionTranscriptRow: View {
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    let cue: CaptionCue
    let active: Bool
    let openEditor: () -> Void
    private var selected: Bool { session.selectedCueID == cue.id }
    private var text: String { session.snapshot?.text(for: cue) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selected {
                ViewThatFits(in: .horizontal) {
                    HStack { editButton; Spacer(minLength: 4); timestamp }
                    VStack(alignment: .leading, spacing: 4) { editButton; timestamp }
                }
                .font(.caption)
            }
            Button { session.selectCue(cue.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    if !selected {
                        Text(EditorTime.display(cue.interval.start))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(text.isEmpty ? "Hidden caption" : text)
                        .font(.body).foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select caption at " + EditorTime.display(cue.interval.start))
            .accessibilityValue((active ? "Current caption. " : "") + (text.isEmpty ? "Hidden caption" : text))
            .accessibilityHint("Selects this caption and jumps the video to it")
        }
        .padding(.horizontal, 12).padding(.vertical, selected ? 10 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? theme.accentColor.opacity(0.20) : selected ? theme.accentColor.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if active {
                RoundedRectangle(cornerRadius: 2).fill(theme.accentColor)
                    .frame(width: 3).padding(.vertical, 6)
            }
        }
        .id(cue.id)
    }

    private var editButton: some View {
        Button("Edit caption", systemImage: "pencil", action: openEditor)
            .buttonStyle(.plain).foregroundStyle(theme.accentColor)
            .frame(minHeight: 44)
    }

    private var timestamp: some View {
        Text(EditorTime.display(cue.interval.start) + "–" + EditorTime.display(cue.interval.end))
            .monospacedDigit().foregroundStyle(.secondary)
    }
}

struct CaptionGapRow: View {
    let gap: CaptionGap
    let busy: Bool
    let seek: () -> Void
    let retry: () -> Void
    let add: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: seek) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(EditorTime.display(gap.interval.start) + "–" + EditorTime.display(gap.interval.end))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text("Transcription unfinished here").font(.subheadline).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 0) {
                Button("Add caption", systemImage: "plus", action: add)
                    .font(.caption).frame(minHeight: 44)
                Button("Retry", systemImage: "arrow.clockwise", action: retry)
                    .font(.caption).frame(minHeight: 44).disabled(busy)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unfinished transcription, clip \(gap.clipNumber)")
    }
}
