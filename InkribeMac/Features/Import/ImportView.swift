import InkribeCore
import InkribeTranscription
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ImportView: View {
    let appState: InkribeAppState
    let onOpenTranscript: (TranscriptID) -> Void

    @State private var preferences = InkribePreferences.shared
    @State private var isImporterPresented = false
    @State private var isImporting = false
    @State private var language = TranscriptionLanguageCatalog.automaticCode
    @State private var hasLoadedDefaults = false
    @State private var errorDescription: String?

    private var queueItems: [TranscriptionQueueItem] {
        appState.transcriptionQueue?.items ?? []
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 20) {
                Spacer(minLength: 24)

                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("Import Audio or Video")
                        .font(.title2.weight(.semibold))
                    Text("Drop files here or choose them from Finder. Inkribe copies source media into its local workspace before queueing transcription.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 480)
                }

                TranscriptionLanguagePicker(selection: $language)
                    .disabled(isImporting)

                Button {
                    isImporterPresented = true
                } label: {
                    Label(isImporting ? "Importing…" : "Choose Files…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)

                if let errorDescription {
                    Text(errorDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: 480)
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty, !isImporting else { return false }
                Task { await importURLs(urls) }
                return true
            }

            Divider()

            TranscriptionQueueListView(
                items: queueItems,
                isPaused: appState.transcriptionQueue?.isPaused ?? false,
                onPause: pauseQueue,
                onResume: resumeQueue,
                onCancel: cancel,
                onRetry: retry,
                onOpenTranscript: onOpenTranscript
            )
            .frame(width: 340)
            .padding(20)
        }
        .task {
            loadWorkflowDefaultsIfNeeded()
        }
        .onChange(of: preferences.defaultTranscriptionLanguage) { _, newValue in
            guard !isImporting else { return }
            language = TranscriptionLanguageCatalog.normalizedSelection(newValue)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await importURLs(urls) }
            case .failure(let error):
                errorDescription = String(describing: error)
            }
        }
    }

    private func loadWorkflowDefaultsIfNeeded() {
        guard !hasLoadedDefaults else { return }
        language = TranscriptionLanguageCatalog.normalizedSelection(
            preferences.defaultTranscriptionLanguage
        )
        hasLoadedDefaults = true
    }

    private func importURLs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        errorDescription = nil
        defer { isImporting = false }

        var failures: [String] = []
        for url in urls {
            do {
                _ = try await appState.importMedia(
                    from: url,
                    requestedLanguage: TranscriptionLanguagePicker.requestedLanguage(for: language)
                )
            } catch {
                failures.append("\(url.lastPathComponent): \(String(describing: error))")
            }
        }

        if !failures.isEmpty {
            errorDescription = failures.joined(separator: "\n")
        }
    }

    private func pauseQueue() {
        do {
            try appState.transcriptionQueue?.pause()
        } catch {
            errorDescription = String(describing: error)
        }
    }

    private func resumeQueue() {
        do {
            try appState.transcriptionQueue?.resume()
        } catch {
            errorDescription = String(describing: error)
        }
    }

    private func cancel(_ id: UUID) {
        do {
            try appState.transcriptionQueue?.cancel(id: id)
        } catch {
            errorDescription = String(describing: error)
        }
    }

    private func retry(_ id: UUID) {
        do {
            try appState.transcriptionQueue?.retry(id: id)
        } catch {
            errorDescription = String(describing: error)
        }
    }
}
