import AppFoundation
import CoreMedia
import SwiftUI

struct ManualCaptionDraft: Identifiable {
    let id = UUID()
    let clipID: UUID
    /// Output-clock seed, matching the transport and the visible missing-range row.
    let interval: MediaInterval
}

struct ManualCaptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let session: EditorSession
    @Binding var previewIsActive: Bool
    @State private var clipID: UUID
    @State private var text = ""
    @State private var start: String
    @State private var end: String
    @State private var error: String?
    @State private var renderError: String?
    @FocusState private var focused: Field?
    @State private var exactStart: MediaTime
    @State private var exactEnd: MediaTime
    @State private var overlapCount = 0
    private enum Field: Hashable { case text, start, end }
    private struct ReviewKey: Equatable {
        let snapshotID: UUID?
        let clipID: UUID
        let start: String
        let end: String
        let exactStart: MediaTime
        let exactEnd: MediaTime
    }
    private var reviewKey: ReviewKey {
        ReviewKey(snapshotID: session.snapshot?.id, clipID: clipID, start: start, end: end,
            exactStart: exactStart, exactEnd: exactEnd)
    }

    init(session: EditorSession, draft: ManualCaptionDraft, previewIsActive: Binding<Bool>) {
        self.session = session
        _previewIsActive = previewIsActive
        _clipID = State(initialValue: draft.clipID)
        _start = State(initialValue: EditorTime.field(draft.interval.start))
        _end = State(initialValue: EditorTime.field(draft.interval.end))
        _exactStart = State(initialValue: draft.interval.start)
        _exactEnd = State(initialValue: draft.interval.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let document = session.document {
                    previewSection(document)
                    captionSection(document)
                    timingSection
                    replacementNotice
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add caption").navigationBarTitleDisplayMode(.inline).themedSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.pause(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(overlapCount > 0 ? "Add & replace" : "Add", action: submit)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.document == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil; session.pause() }
                }
            }
            .onChange(of: clipID) { _, id in
                guard let document = session.document, let clip = document.clips.first(where: { $0.id == id }),
                      let interval = OutputTimeline(document).outputInterval(clip.timelineInterval) else { return }
                exactStart = interval.start
                start = EditorTime.field(exactStart)
                let proposedEnd = (try? EditorTime.stamp(EditorTime.seconds(interval.start) + 2)) ?? interval.end
                exactEnd = min(interval.end, proposedEnd)
                end = EditorTime.field(exactEnd)
                error = nil; session.pause(); session.seek(to: interval.start)
            }
            .onChange(of: reviewKey, initial: true) { _, _ in overlapCount = recognizedOverlapCount() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { session.pause() } }
            .onDisappear { session.pause() }
        }
        .presentationDetents([.large])
    }

    private func previewSection(_ document: ProjectDocument) -> some View {
        Section {
            preview(document)
            CaptionTimeline(snapshot: session.snapshot, selectedCueID: session.selectedCueID,
                duration: EditorTime.seconds(session.duration), seconds: EditorTime.seconds(session.time),
                showsOverview: false, seek: { focused = nil; session.scrub(seconds: $0) })
            Button(session.isPlaying ? "Pause" : "Play", systemImage: session.isPlaying ? "pause.fill" : "play.fill") {
                focused = nil; session.togglePlayback()
            }
            .frame(minHeight: 44)
            .disabled(session.isPreparingPreview || session.previewError != nil)
            if let message = session.previewError ?? renderError {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        } header: { Text("Find the missing speech") }
    }

    private func captionSection(_ document: ProjectDocument) -> some View {
        Section("Caption") {
            if document.clips.count > 1 {
                Picker("Clip", selection: $clipID) {
                    ForEach(retainedClips(document)) { clip in
                        Text(document.editorClipTitle(clip)).tag(clip.id)
                    }
                }
            }
            TextField("Caption text", text: $text, axis: .vertical)
                .lineLimit(3...8).focused($focused, equals: .text)
                .accessibilityLabel("New caption text")
            Text("Manual captions use phrase timing. Individual word timing is not generated.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var timingSection: some View {
        Section {
            timingField("Start", value: $start, field: .start)
            timingField("End", value: $end, field: .end)
            Text("Seconds on the playback timeline, after trim. Keep the whole caption inside the selected clip.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: { Text("Timing") }
    }

    @ViewBuilder private var replacementNotice: some View {
        if overlapCount > 0 {
            Section {
                Label("This replaces \(overlapCount) overlapping recognized \(overlapCount == 1 ? "caption" : "captions") in preview and export.", systemImage: "exclamationmark.bubble")
                Text("The whole recognized caption is replaced, including text outside your selected range. Original recognition stays saved. You can review it in Captions or restore it by removing the manual caption.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func retainedClips(_ document: ProjectDocument) -> [ProjectClip] {
        let timeline = OutputTimeline(document)
        return document.orderedClips.filter { timeline.outputInterval($0.timelineInterval) != nil }
    }

    private func timingField(_ title: String, value: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title + " (s)").font(.caption).foregroundStyle(.secondary)
            TextField(title + " seconds", text: value).keyboardType(.decimalPad)
                .focused($focused, equals: field).accessibilityLabel(title + " seconds")
            Button("Set \(title.lowercased()) at playhead") {
                session.pause(); focused = nil
                if field == .start { exactStart = session.time } else { exactEnd = session.time }
                value.wrappedValue = EditorTime.field(session.time)
                error = nil
            }.font(.caption).frame(minHeight: 44)
        }
    }

    private func preview(_ document: ProjectDocument) -> some View {
        EditorPlayerPreview(session: session, isActive: previewIsActive, onError: { renderError = $0 })
        .frame(maxWidth: .infinity).frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Video preview, " + (session.presentation?.text ?? "no caption at playhead"))
    }

    private func originalInterval() throws -> MediaInterval {
        guard let document = session.document, let clip = document.clips.first(where: { $0.id == clipID }) else {
            throw ManualCaptionError.invalidCaption
        }
        func parse(_ field: String, preserving exact: MediaTime) throws -> MediaTime {
            if field == EditorTime.field(exact) { return exact }
            guard let seconds = Double(field.replacingOccurrences(of: ",", with: ".")) else { throw ManualCaptionError.invalidCaption }
            return try EditorTime.stamp(seconds)
        }
        let output = try MediaInterval(start: parse(start, preserving: exactStart), end: parse(end, preserving: exactEnd))
        let timeline = OutputTimeline(document)
        let original = try MediaInterval(start: timeline.originalTime(forOutput: output.start),
                                         end: timeline.originalTime(forOutput: output.end, precedingBoundary: true))
        guard original.start >= clip.timelineInterval.start, original.end <= clip.timelineInterval.end else {
            throw ManualCaptionError.invalidCaption
        }
        return original
    }

    private func recognizedOverlapCount() -> Int {
        guard let document = session.document, let interval = try? originalInterval(),
              let recognition = document.recognition else { return 0 }
        let words = Dictionary(uniqueKeysWithValues: recognition.words.map { ($0.id, $0.text) })
        return recognition.cues.filter { cue in
            ManualCaption.overlaps(cue.interval, interval) &&
                cue.wordIDs.contains { !(words[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }.count
    }

    private func submit() {
        do {
            let interval = try originalInterval()
            let currentOverlaps = recognizedOverlapCount()
            if currentOverlaps > 0, currentOverlaps != overlapCount {
                overlapCount = currentOverlaps
                error = "Recognition changed. Review the replacement notice, then add the caption again."
                return
            }
            guard session.addManualCaption(text: text, clipID: clipID, interval: interval) else {
                error = session.commandError ?? ManualCaptionError.invalidCaption.localizedDescription
                return
            }
            focused = nil; session.pause()
            if let cue = session.selectedCue { session.seek(to: cue.interval.start) }
            dismiss()
        } catch { self.error = ManualCaptionError.invalidCaption.localizedDescription }
    }
}

/// Manual phrases have priority; no native text or timestamps are deleted.
/// The same snapshot policy is used by live preview, MP4 and SRT.
struct ManualCaptionConflictReview: View {
    let session: EditorSession
    var body: some View {
        if let conflicts = session.snapshot?.manualConflicts, !conflicts.isEmpty {
            DisclosureGroup("Review \(conflicts.count) replaced recognized \(conflicts.count == 1 ? "caption" : "captions")") {
                Text("Manual captions replace whole overlapping recognized captions in preview and export. Remove a manual caption to restore the recognized text. Undo restores the manual caption.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recognized: " + conflict.text).font(.subheadline)
                        Text(EditorTime.display(conflict.cue.interval.start) + "–" + EditorTime.display(conflict.cue.interval.end) + " · original project time")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(conflict.manuals) { manual in
                            Text("Manual: " + manual.text).font(.subheadline)
                            Button("Edit manual caption") { session.selectCue(manual.id) }.frame(minHeight: 44)
                            Button("Remove manual caption", role: .destructive) { session.deleteManualCaption(manual.id) }.frame(minHeight: 44)
                        }
                    }.padding(.vertical, 8)
                }
            }
            .font(.subheadline)
        }
    }
}
