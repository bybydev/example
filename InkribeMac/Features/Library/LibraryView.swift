import InkribeCore
import SwiftUI

@MainActor
struct LibraryView: View {
    let appState: InkribeAppState
    let onOpenTranscript: (TranscriptID) -> Void
    let onRecord: () -> Void
    let onImport: () -> Void

    @State private var transcripts: [Transcript] = []
    @State private var searchText = ""
    @State private var sort: TranscriptLibrarySort = .newest
    @State private var isLoading = true
    @State private var errorDescription: String?
    @State private var renameTarget: Transcript?
    @State private var renameText = ""
    @State private var deleteTarget: Transcript?

    private var visibleTranscripts: [Transcript] {
        TranscriptLibraryQuery.apply(
            to: transcripts,
            searchText: searchText,
            sort: sort
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await reload()
        }
        .sheet(item: $renameTarget) { transcript in
            renameSheet(transcript)
        }
        .confirmationDialog(
            "Delete transcript?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Transcript and Source Media", role: .destructive) {
                guard let transcript = deleteTarget else { return }
                deleteTarget = nil
                Task { await delete(transcript) }
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("This removes the transcript and its app-owned source media. Active transcription must finish or be cancelled first.")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search title or transcript text", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 420)

            Picker("Sort", selection: $sort) {
                ForEach(TranscriptLibrarySort.allCases, id: \.self) { option in
                    Text(sortTitle(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120)

            Spacer(minLength: 12)

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh Library")

            Menu {
                Button("Record Audio", action: onRecord)
                Button("Import File", action: onImport)
            } label: {
                Label("New", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && transcripts.isEmpty {
            ProgressView("Loading transcripts…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if transcripts.isEmpty, let errorDescription {
            ContentUnavailableView(
                "Couldn't load Library",
                systemImage: "exclamationmark.triangle",
                description: Text(errorDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if transcripts.isEmpty {
            ContentUnavailableView {
                Label("No Transcripts Yet", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Record audio or import a file to create your first local transcript.")
            } actions: {
                HStack {
                    Button("Record Audio", action: onRecord)
                    Button("Import File", action: onImport)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleTranscripts.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleTranscripts) { transcript in
                        transcriptRow(transcript)
                        Divider()
                            .padding(.leading, 58)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let errorDescription {
                    errorBanner(errorDescription)
                        .padding(16)
                }
            }
        }
    }

    private func transcriptRow(_ transcript: Transcript) -> some View {
        HStack(spacing: 12) {
            Button {
                onOpenTranscript(transcript.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 19))
                        .frame(width: 30, height: 30)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(transcript.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(excerpt(for: transcript))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Text(transcript.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            if transcript.duration > 0 {
                                Text("•")
                                Text(Self.formatDuration(transcript.duration))
                            }
                            if let languageCode = transcript.languageCode, !languageCode.isEmpty {
                                Text("•")
                                Text(languageCode.uppercased())
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("Rename…") {
                    renameText = transcript.title
                    renameTarget = transcript
                }
                Button("Delete…", role: .destructive) {
                    deleteTarget = transcript
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func renameSheet(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Transcript")
                .font(.headline)

            TextField("Title", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await rename(transcript) }
                }

            HStack {
                Spacer()
                Button("Cancel") {
                    renameTarget = nil
                }
                Button("Save") {
                    Task { await rename(transcript) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func errorBanner(_ description: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(description)
                .lineLimit(2)
            Button("Dismiss") {
                errorDescription = nil
            }
            .buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            transcripts = try await appState.transcripts()
            errorDescription = nil
        } catch {
            errorDescription = error.localizedDescription
        }
    }

    private func rename(_ transcript: Transcript) async {
        do {
            let updated = try await appState.renameTranscript(id: transcript.id, title: renameText)
            replace(updated)
            renameTarget = nil
            errorDescription = nil
        } catch {
            errorDescription = error.localizedDescription
        }
    }

    private func delete(_ transcript: Transcript) async {
        do {
            try await appState.deleteTranscript(id: transcript.id)
            transcripts.removeAll { $0.id == transcript.id }
            errorDescription = nil
        } catch {
            errorDescription = error.localizedDescription
        }
    }

    private func replace(_ transcript: Transcript) {
        if let index = transcripts.firstIndex(where: { $0.id == transcript.id }) {
            transcripts[index] = transcript
        }
    }

    private func sortTitle(_ sort: TranscriptLibrarySort) -> String {
        switch sort {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .title: "Title"
        }
    }

    private func excerpt(for transcript: Transcript) -> String {
        let text = transcript.editedText.isEmpty ? transcript.rawText : transcript.editedText
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "No transcript text yet" : collapsed
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
