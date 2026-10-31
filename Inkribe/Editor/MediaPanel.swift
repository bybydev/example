import SwiftUI

/// Clip-only Form sections. Project trim, canvas and master mute never appear
/// beneath a clip scope, and resets restore standard values without inheritance.
struct MediaPanel: View {
    let draft: MediaDraft
    let clipID: UUID
    private var edits: MediaEdits { draft.media(for: clipID) }

    var body: some View {
        Section("Framing") {
            Picker("Framing", selection: value(\.fit)) {
                Text("Fit").tag(MediaFit.fit)
                Text("Fill").tag(MediaFit.fill)
            }.pickerStyle(.menu)
            DisclosureGroup {
                Slider(value: value(\.zoom), in: 1...3)
                    .accessibilityLabel("Zoom")
                    .accessibilityValue(String(format: "%.2f×", edits.zoom))
            } label: {
                LabeledContent("Zoom", value: String(format: "%.2f×", edits.zoom))
            }
            DisclosureGroup {
                positionSlider("Horizontal", key: \.positionX)
                positionSlider("Vertical", key: \.positionY)
                Text("Position moves the part of the image extending beyond the canvas.")
                    .font(.footnote).foregroundStyle(.secondary)
            } label: {
                LabeledContent("Position", value: "X \(percent(edits.positionX)) · Y \(percent(edits.positionY))")
            }
        }
        Section {
            DisclosureGroup {
                Slider(value: value(\.volume), in: 0...1)
                    .accessibilityLabel("Original audio volume")
                    .accessibilityValue(percent(edits.volume))
            } label: {
                LabeledContent("Volume", value: edits.volume == 0 ? "Muted" : percent(edits.volume))
            }
        } header: { Text("Original audio") } footer: {
            if draft.originalAudioMuted {
                Text("All original audio is muted in Project settings. This clip’s volume is preserved.")
            }
        }
        Section {
            Button("Reset framing", systemImage: "arrow.counterclockwise") { draft.resetFraming(for: clipID) }
                .disabled(edits.fit == .fit && edits.zoom == 1 && edits.positionX == 0.5 && edits.positionY == 0.5)
            Button("Reset volume", systemImage: "arrow.counterclockwise") { draft.resetVolume(for: clipID) }
                .disabled(edits.volume == 1)
        }
    }

    private func value<T>(_ key: WritableKeyPath<MediaEdits, T>) -> Binding<T> {
        Binding(get: { edits[keyPath: key] }, set: { value in
            var next = edits; next[keyPath: key] = value
            draft.setMedia(next, for: clipID)
        })
    }
    private func positionSlider(_ title: String, key: WritableKeyPath<MediaEdits, Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: percent(edits[keyPath: key]))
            Slider(value: value(key), in: 0...1)
                .accessibilityLabel(title + " crop position")
                .accessibilityValue(percent(edits[keyPath: key]))
        }
    }
    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
