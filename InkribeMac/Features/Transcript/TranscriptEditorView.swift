import InkribeAI
import InkribeCore
import InkribeTranscription
import MacAppFoundation
import SwiftUI

@MainActor
struct TranscriptEditorView: View {
    let transcriptID: TranscriptID
    let appState: InkribeAppState
    let purchaseManager: PurchaseManager
    let onOpenPaywall: () -> Void

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
    @State private var aiController = TranscriptLocalAIController.shared
    @State private var aiTask: Task<Void, Never>?
    @State private var aiResult: TranscriptAIResult?
    @State private var inspectorPane: InspectorPane = .segments
    @State private var upsellCapability: InkribeProCapability?
    @State private var speakerToRename: TranscriptSpeaker?
    @State private var speakerNameDraft = ""

    private enum TextMode: String, CaseIterable, Hashable {
        case edited = "Edited"
        case raw = "Raw"
    }

    private enum InspectorPane: Hashable {
        case segments
        case aiResults
    }

    private var completedTranscriptionCount: Int {
        appState.transcriptionQueue?.items.filter {
            $0.transcriptID == transcriptID && $0.state == .complete
        }.count ?? 0
    }

    private var transcriptLoadGeneration: String {
        "\(transcriptID.rawValue.uuidString):\(completedTranscriptionCount)"
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: transcriptLoadGeneration) {
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
        .sheet(item: $aiResult) { result in
            TranscriptAIResultSheet(result: result) { applyMode in
                try await applyAIResult(result, mode: applyMode)
            }
        }
        .sheet(item: $upsellCapability) { capability in
            InkribeProUpsellView(
                capability: capability,
                onUpgrade: {
                    upsellCapability = nil
                    onOpenPaywall()
                },
                onDismiss: {
                    upsellCapability = nil
                }
            )
        }
        .alert(
            "Rename Speaker",
            isPresented: Binding(
                get: { speakerToRename != nil },
                set: { if !$0 { speakerToRename = nil } }
            )
        ) {
            TextField("Speaker name", text: $speakerNameDraft)
            Button("Cancel", role: .cancel) {
                speakerToRename = nil
            }
            Button("Save") {
                Task { await renameSelectedSpeaker() }
            }
            .disabled(speakerNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This name is used for every segment assigned to this speaker.")
        }
        .onDisappear {
            aiTask?.cancel()
            aiTask = nil
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

            if aiController.isGenerating {
                Divider()
                aiProgressBar
            }

            Divider()

            HStack(spacing: 0) {
                textPane(transcript)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                inspector(transcript)
                    .frame(width: 330)
            }

            Divider()
            playerBar(transcript)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

            aiMenu(transcript)

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

    private func aiMenu(_ transcript: Transcript) -> some View {
        Menu {
            ForEach(TranscriptAIAction.allCases, id: \.self) { action in
                Button {
                    requestAI(action)
                } label: {
                    HStack {
                        Label(action.displayName, systemImage: action.systemImage)
                        if !purchaseManager.hasPro {
                            ProBadge(style: .icon)
                        }
                    }
                }
            }

            Divider()

            Button {
                inspectorPane = .aiResults
            } label: {
                Label(
                    transcript.derivedDocuments.isEmpty
                        ? "Show AI Results"
                        : "Show AI Results (\(transcript.derivedDocuments.count))",
                    systemImage: "tray.full"
                )
            }
        } label: {
            Image(systemName: "sparkles")
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .help("Local AI")
        .disabled(aiController.isGenerating)
        .accessibilityLabel("Local AI actions")
    }

    private var aiProgressBar: some View {
        HStack(spacing: 10) {
            ProgressView(value: aiController.progress?.fraction ?? 0)
                .frame(width: 120)

            Text(transcriptAIProgressLabel(aiController.progress))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Button("Cancel") {
                aiTask?.cancel()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(.quaternary.opacity(0.15))
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

    private func inspector(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Inspector", selection: $inspectorPane) {
                Text("Segments")
                    .tag(InspectorPane.segments)
                Text(
                    transcript.derivedDocuments.isEmpty
                        ? "AI Results"
                        : "AI Results \(transcript.derivedDocuments.count)"
                )
                .tag(InspectorPane.aiResults)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .frame(height: 42)

            Divider()

            switch inspectorPane {
            case .segments:
                segmentPane(transcript)
            case .aiResults:
                aiResultsPane(transcript)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.12))
    }

    private func segmentPane(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !transcript.speakers.isEmpty {
                    Text("\(transcript.speakers.count) speakers")
                } else {
                    Text("Segments")
                }
                Spacer()
                Text("\(filteredSegments.count)")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 32)

            Divider()

            if transcript.segments.isEmpty {
                ContentUnavailableView(
                    "No timestamped segments",
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSegments.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func aiResultsPane(_ transcript: Transcript) -> some View {
        let documents = transcript.derivedDocuments.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        return Group {
            if documents.isEmpty {
                ContentUnavailableView(
                    "No AI Results",
                    systemImage: "sparkles",
                    description: Text("Generate a summary, notes, action items, or save a Clean/Polish copy.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(documents) { document in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Text(document.kind.displayName)
                                        .font(.headline)
                                    if document.sourceRevision != transcript.revision {
                                        Text("Older revision")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                    Spacer(minLength: 4)
                                }

                                Text(document.content)
                                    .font(.system(size: 12.5))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)

                                HStack {
                                    Text("Revision \(document.sourceRevision)")
                                    Spacer()
                                    Text(document.createdAt.formatted(date: .abbreviated, time: .shortened))
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(
                                .quaternary.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
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

                VStack(alignment: .leading, spacing: 4) {
                    if let speakerID = segment.speakerID {
                        Text(transcript?.speakerName(for: speakerID) ?? "Speaker \(speakerID + 1)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text(segment.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        .contextMenu {
            if let speakerID = segment.speakerID {
                Button("Rename \(transcript?.speakerName(for: speakerID) ?? "Speaker \(speakerID + 1)")…") {
                    beginRenamingSpeaker(speakerID)
                }
            }
        }
        .accessibilityLabel(
            [
                Self.formatTime(segment.startTime),
                segment.speakerID.map { transcript?.speakerName(for: $0) ?? "Speaker \($0 + 1)" },
                segment.text
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }

    private func beginRenamingSpeaker(_ speakerID: Int) {
        guard let speaker = transcript?.speakers.first(where: { $0.id == speakerID }) else { return }
        speakerNameDraft = speaker.name
        speakerToRename = speaker
    }

    private func renameSelectedSpeaker() async {
        guard let speaker = speakerToRename else { return }
        do {
            transcript = try await appState.renameSpeaker(
                transcriptID: transcriptID,
                speakerID: speaker.id,
                name: speakerNameDraft
            )
            speakerToRename = nil
            errorDescription = nil
        } catch {
            errorDescription = error.localizedDescription
        }
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

    private func requestAI(_ action: TranscriptAIAction) {
        switch InkribeProCapability.localAI.decision(hasPro: purchaseManager.hasPro) {
        case .allowed:
            startAI(action)
        case .requiresPro:
            upsellCapability = .localAI
        }
    }

    private func startAI(_ action: TranscriptAIAction) {
        guard aiTask == nil, !aiController.isGenerating else { return }

        aiTask = Task { @MainActor in
            defer { aiTask = nil }

            if editedText != lastSavedText {
                await saveEditedText()
                guard editedText == lastSavedText else { return }
            }

            guard let currentTranscript = transcript else { return }

            do {
                let result = try await aiController.generate(
                    action: action,
                    transcript: currentTranscript
                )
                try Task.checkCancellation()
                aiResult = result
                errorDescription = nil
            } catch is CancellationError {
                // User cancelled or navigated away.
            } catch {
                errorDescription = error.localizedDescription
            }
        }
    }

    private func applyAIResult(
        _ result: TranscriptAIResult,
        mode applyMode: TranscriptAIApplyMode
    ) async throws {
        let updated = try await appState.applyTranscriptAIResult(
            transcriptID: transcriptID,
            result: result,
            mode: applyMode
        )
        transcript = updated

        if applyMode == .replaceEditedText {
            editedText = updated.editedText
            lastSavedText = updated.editedText
            mode = .edited
        } else if applyMode == .saveDerivedDocument {
            inspectorPane = .aiResults
        }

        aiResult = nil
        errorDescription = nil
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
