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
    private var selected: Bool { session.selectedCueID == cue.id }
    private var text: String { session.snapshot?.text(for: cue) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selected {
                ViewThatFits(in: .horizontal) {
                    HStack { editingLabel; Spacer(minLength: 4); timestamp }
                    VStack(alignment: .leading, spacing: 4) { editingLabel; timestamp }
                }
                .font(.caption)
                TextField("Hidden caption", text: Binding(get: { session.workspace.captionDraft?.value(for: cue.id, canonical: text) ?? text }, set: { value in
                    guard session.editCueText(cueID: cue.id, value: value) else { return }
                    session.workspace.captionDraft = EditorTextDraft(id: cue.id, text: value, canonical: text)
                }), axis: .vertical)
                .font(.body)
                .focused($focused, equals: .caption(cue.id))
                .id(EditorField.caption(cue.id))
                .accessibilityLabel("Caption text")
                if let error = session.commandError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if cue.wordIDs.contains(where: { session.snapshot?.wordsByID[$0]?.timingProvenance == "whisper-segment" }) {
                    Label("Phrase timing", systemImage: "text.alignleft")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { correctionActions }
                    VStack(alignment: .leading, spacing: 8) { correctionActions }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .tint(theme.accentColor)
                if session.workspace.expandedCaptionTiming == cue.id, let interval = session.timingCue?.interval {
                    TimingFields(interval: interval, identity: cue.id,
                        detail: "Original project seconds. Timing changes are manual adjustments.",
                        apply: session.retimeCue, workspace: Binding(get: { session.workspace }, set: { session.workspace = $0 }), focused: $focused)
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
    }

    private var editingLabel: some View {
        Label("Editing caption", systemImage: "pencil").foregroundStyle(theme.accentColor)
    }

    private var correctionActions: some View {
        Group {
            Button("Timing", systemImage: "timer") {
                focused = nil
                session.workspace.expandedCaptionTiming = session.workspace.expandedCaptionTiming == cue.id ? nil : cue.id
            }
            Button("Split / Words", systemImage: "scissors") { focused = nil; openWords() }
        }
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
