import InkribeCore
import SwiftUI

@MainActor
struct TranscriptEditorView: View {
    let transcriptID: TranscriptID
    let appState: InkribeAppState

    @State private var transcript: Transcript?
    @State private var editedText = ""
    @State private var lastSavedText = ""
    @State private var searchText = ""
    @State private var mode: TextMode = .edited
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorDescription: String?
    @State private var playbackIssueDescription: String?
    @State private var playback = TranscriptPlaybackController()

    private enum TextMode: String, CaseIterable, Hashable {
        case edited = "Edited"
        case raw = "Raw"
    }

    private var displayedText: String {
        guard let transcript else { return "" }
        return mode == .edited ? editedText : transcript.rawText
    }

    private var filteredSegments: [TranscriptSegment] {
        guard let transcript else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return transcript.segments }
        return transcript.segments.filter {
            $0.text.localizedCaseInsensitiveContains(query)
        }
    }

    private var currentSegmentID: UUID? {
        guard let transcript else { return nil }
        let time = playback.currentTime
        return transcript.segments.first(where: {
            time >= $0.startTime && time < max($0.endTime, $0.startTime + 0.01)
        })?.id
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading transcript…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let transcript {
                editor(transcript)
            } else {
                ContentUnavailableView(
                    "Transcript unavailable",
                    systemImage: "doc.badge.exclamationmark",
                    description: Text(errorDescription ?? "The transcript no longer exists.")
                )
            }
        }
        .task(id: transcriptID) {
            await load()
        }
        .task(id: editedText) {
            guard transcript != nil, editedText != lastSavedText else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                await saveEditedText()
            } catch is CancellationError {
                // A newer edit replaced this pending save.
            } catch {
                errorDescription = error.localizedDescription
            }
        }
        .onDisappear {
            playback.unload()
            guard editedText != lastSavedText else { return }
            let text = editedText
            Task {
                _ = try? await appState.saveEditedText(id: transcriptID, text: text)
            }
        }
    }

    private func editor(_ transcript: Transcript) -> some View {
        VStack(spacing: 0) {
            editorToolbar(transcript)
            Divider()

            HStack(spacing: 0) {
                textPane(transcript)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                segmentPane(transcript)
                    .frame(width: 330)
            }

            Divider()
            playerBar(transcript)
        }
        .overlay(alignment: .bottomLeading) {
            if let errorDescription {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorDescription)
                        .lineLimit(2)
                    Button("Dismiss") {
                        self.errorDescription = nil
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .padding(.leading, 16)
                .padding(.bottom, 58)
            }
        }
    }

    private func editorToolbar(_ transcript: Transcript) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 7) {
                    if let languageCode = transcript.languageCode, !languageCode.isEmpty {
                        Text(languageCode.uppercased())
                    }
                    if transcript.duration > 0 {
                        Text(Self.formatTime(transcript.duration))
                    }
                    Text("Revision \(transcript.revision)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .help("Saving")
            } else if editedText != lastSavedText {
                Button("Save") {
                    Task { await saveEditedText() }
                }
                .buttonStyle(.borderless)
            } else {
                Label("Saved", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Text", selection: $mode) {
                ForEach(TextMode.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcript", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Text("\(matchCount(in: displayedText))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 230, height: 28)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    @ViewBuilder
    private func textPane(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if mode == .edited {
                TextEditor(text: $editedText)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .accessibilityLabel("Edited transcript")
            } else {
                ScrollView {
                    Text(transcript.rawText.isEmpty ? "No raw transcript text." : transcript.rawText)
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(18)
                }
                .overlay(alignment: .topTrailing) {
                    Label("Original transcription", systemImage: "lock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
            }
        }
        .background(.background)
    }

    private func segmentPane(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Segments")
                    .font(.headline)
                Spacer()
                Text("\(filteredSegments.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            Divider()

            if transcript.segments.isEmpty {
                ContentUnavailableView(
                    "No timestamped segments",
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
            } else if filteredSegments.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredSegments) { segment in
                                segmentRow(segment)
                                    .id(segment.id)
                                Divider()
                                    .padding(.leading, 54)
                            }
                        }
                    }
                    .onChange(of: currentSegmentID) { _, id in
                        guard searchText.isEmpty, let id else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.12))
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        Button {
            playback.seek(to: segment.startTime)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(Self.formatTime(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(segment.id == currentSegmentID ? .primary : .secondary)
                    .frame(width: 42, alignment: .trailing)

                Text(segment.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                segment.id == currentSegmentID
                    ? Color.primary.opacity(0.08)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Self.formatTime(segment.startTime)), \(segment.text)")
    }

    private func playerBar(_ transcript: Transcript) -> some View {
        HStack(spacing: 10) {
            Button {
                playback.skip(by: -10)
            } label: {
                Image(systemName: "gobackward.10")
            }
            .disabled(!playback.isPrepared)

            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!playback.isPrepared)

            Button {
                playback.skip(by: 10)
            } label: {
                Image(systemName: "goforward.10")
            }
            .disabled(!playback.isPrepared)

            Text(Self.formatTime(playback.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            if let playbackIssueDescription {
                Text(playbackIssueDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(max(playback.duration, playback.currentTime), 1)
                )
                .disabled(!playback.isPrepared)

                Text(Self.formatTime(playback.duration > 0 ? playback.duration : transcript.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.bar)
    }

    private func load() async {
        isLoading = true
        errorDescription = nil
        playbackIssueDescription = nil
        playback.unload()
        defer { isLoading = false }

        do {
            guard let loaded = try await appState.transcript(id: transcriptID) else {
                transcript = nil
                return
            }
            transcript = loaded
            editedText = loaded.editedText
            lastSavedText = loaded.editedText

            guard let mediaURL = try await appState.mediaURL(for: loaded) else { return }
            do {
                try await playback.prepare(url: mediaURL)
            } catch {
                playbackIssueDescription = error.localizedDescription
            }
        } catch {
            transcript = nil
            errorDescription = error.localizedDescription
        }
    }

    private func saveEditedText() async {
        let textToSave = editedText
        guard textToSave != lastSavedText else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let saved = try await appState.saveEditedText(id: transcriptID, text: textToSave)
            transcript = saved
            lastSavedText = textToSave
            errorDescription = nil
        } catch {
            errorDescription = error.localizedDescription
        }
    }

    private func matchCount(in text: String) -> Int {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !text.isEmpty else { return 0 }

        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        ) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    private static func formatTime(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "0:00" }
        let total = max(0, Int(duration.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
