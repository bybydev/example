import AppFoundation
import SwiftUI

/// The caption itself is the editor. Fine-grained native word controls remain
/// available through Split/Words without hiding the readable transcript.
struct CaptionTranscriptRow: View {
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    let cue: CaptionCue
    let active: Bool
    let openWords: () -> Void
    @FocusState.Binding var focused: EditorField?
    @State private var draft = ""
    @State private var showsTiming = false
    private var selected: Bool { session.selectedCueID == cue.id }
    private var text: String { session.snapshot?.text(for: cue) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selected {
                HStack {
                    Label("Editing caption", systemImage: "pencil").foregroundStyle(theme.accentColor)
                    Spacer(minLength: 4)
                    timestamp
                }
                .font(.caption2)
                TextField("Hidden caption", text: Binding(get: { draft }, set: { value in
                    draft = value
                    session.editCueText(cueID: cue.id, value: value)
                }), axis: .vertical)
                .font(.body)
                .lineLimit(1...6)
                .focused($focused, equals: .caption(cue.id))
                .id(EditorField.caption(cue.id))
                .accessibilityLabel("Caption text")
                if cue.wordIDs.contains(where: { session.snapshot?.wordsByID[$0]?.timingProvenance == "whisper-segment" }) {
                    Label("Phrase timing", systemImage: "text.alignleft")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    Button("Timing", systemImage: "timer") { focused = nil; showsTiming.toggle() }
                    Button("Split / Words", systemImage: "scissors") { focused = nil; openWords() }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .tint(theme.accentColor)
                .frame(minHeight: 34)
                if showsTiming, let interval = session.timingCue?.interval {
                    TimingFields(interval: interval, identity: cue.id,
                        detail: "Original project seconds. Timing changes are manual adjustments.",
                        apply: session.retimeCue, focused: $focused)
                }
            } else {
                Button {
                    focused = nil
                    session.selectCue(cue.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(EditorTime.display(cue.interval.start))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Text(text.isEmpty ? "Hidden caption" : text)
                            .font(.body).foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit caption at " + EditorTime.display(cue.interval.start))
                .accessibilityValue(text.isEmpty ? "Hidden caption" : text)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, selected ? 10 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? theme.accentColor.opacity(0.12) : active ? theme.accentColor.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 12))
        .id(cue.id)
        .onAppear { draft = text }
        .onChange(of: text) { _, value in if focused != .caption(cue.id) { draft = value } }
        .onChange(of: focused) { _, value in if value != .caption(cue.id) { draft = text } }
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
    var body: some View {
        HStack(spacing: 12) {
            Button(action: seek) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(EditorTime.display(gap.interval.start) + "–" + EditorTime.display(gap.interval.end))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text("Captions missing here").font(.subheadline).foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Retry", systemImage: "arrow.clockwise", action: retry)
                .font(.caption).frame(minHeight: 44).disabled(busy)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Missing captions, clip \(gap.clipNumber)")
    }
}
