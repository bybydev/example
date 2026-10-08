import Foundation
import Observation

@Observable
@MainActor
final class LibraryModel {
    enum SortOption: String, CaseIterable, Identifiable {
        case recentlyUpdated
        case recentlyAdded
        case title

        var id: Self { self }

        var label: String {
            switch self {
            case .recentlyUpdated:
                return "Recently Updated"
            case .recentlyAdded:
                return "Recently Added"
            case .title:
                return "Title"
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let snapshot: ProjectSnapshot
        let artworkURL: URL?

        var id: UUID { snapshot.id }
    }

    private(set) var entries: [Entry] = []
    private(set) var catalogIssues: [ProjectCatalogIssue] = []
    private(set) var isLoading = false
    private(set) var didLoad = false
    private(set) var importProgress: ReadAloudImportProgress?

    var searchText = ""
    var sortOption: SortOption = .recentlyUpdated
    var errorMessage: String?

    private var importSessionID: UUID?
    private var importWorker: Task<ReadAloudImportResult, Error>?
    private var importCancellationRequested = false

    var isImporting: Bool { importSessionID != nil }

    private let projectStore: ProjectStore?
    private let importer: ReadAloudImportCoordinator?
    private let initializationError: String?

    init() {
        do {
            let store = try ProjectStore()
            projectStore = store
            importer = ReadAloudImportCoordinator(projectStore: store)
            initializationError = nil
        } catch {
            projectStore = nil
            importer = nil
            initializationError = Self.message(for: error)
        }
    }

    var filteredEntries: [Entry] {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let filtered = query.isEmpty ? entries : entries.filter { entry in
            let snapshot = entry.snapshot
            return snapshot.title.lowercased().contains(query)
                || (snapshot.author?.lowercased().contains(query) ?? false)
                || sourceLabel(snapshot.sourceType).lowercased().contains(query)
        }

        return filtered.sorted(by: sortPredicate)
    }

    var continueListening: Entry? {
        entries
            .filter {
                $0.snapshot.lastPlayedAt != nil
                    && $0.snapshot.projectProgress < 1
            }
            .max {
                ($0.snapshot.lastPlayedAt ?? .distantPast)
                    < ($1.snapshot.lastPlayedAt ?? .distantPast)
            }
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await refresh()
    }

    func refresh() async {
        guard let projectStore else {
            errorMessage = initializationError ?? "Unable to open the Library."
            didLoad = true
            return
        }

        isLoading = true
        defer {
            isLoading = false
            didLoad = true
        }

        do {
            let catalog = try await projectStore.catalog()
            let rootURL = await projectStore.rootURL

            entries = catalog.projects.map { snapshot in
                Entry(
                    snapshot: snapshot,
                    artworkURL: artworkURL(
                        snapshot: snapshot,
                        rootURL: rootURL
                    )
                )
            }
            catalogIssues = catalog.issues
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func rename(
        projectID: UUID,
        to title: String
    ) async -> Bool {
        guard let projectStore else { return false }

        do {
            _ = try await projectStore.renameProject(
                projectID: projectID,
                to: title
            )
            await refresh()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func delete(projectID: UUID) async -> Bool {
        guard let projectStore else { return false }

        do {
            try await projectStore.deleteProject(projectID: projectID)
            entries.removeAll { $0.id == projectID }
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func importFile(
        _ url: URL,
        hasPro: Bool
    ) async -> Bool {
        await importSource(
            .file(url),
            detail: url.lastPathComponent,
            hasPro: hasPro
        )
    }

    func importPaste(
        text: String,
        suggestedTitle: String?,
        hasPro: Bool
    ) async -> Bool {
        await importSource(
            .pastedText(text, suggestedTitle: suggestedTitle),
            detail: "Pasted Text",
            hasPro: hasPro
        )
    }

    func cancelImport() {
        guard isImporting else { return }
        importCancellationRequested = true
        importWorker?.cancel()
        // Dismiss immediately, even if a synchronous parser is still unwinding.
        importProgress = nil
    }

    private func importSource(
        _ source: ReadAloudImportSource,
        detail: String,
        hasPro: Bool
    ) async -> Bool {
        guard !isImporting, !Task.isCancelled else { return false }

        do {
            try ReadAloudAccessPolicy.requireLibraryCapacity(
                existingProjectCount: entries.count,
                hasPro: hasPro
            )
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }

        guard let importer else {
            errorMessage = initializationError ?? "Import is unavailable."
            return false
        }

        let sessionID = UUID()
        importSessionID = sessionID
        importCancellationRequested = false
        errorMessage = nil
        importProgress = ReadAloudImportProgress(
            stage: .preparing,
            fractionCompleted: 0,
            detail: detail
        )

        let reportProgress: @Sendable (ReadAloudImportProgress) -> Void = {
            [weak self] value in
            Task { @MainActor [weak self] in
                self?.receiveImportProgress(value, sessionID: sessionID)
            }
        }
        // Parsing, source copying, and normalization must not inherit MainActor.
        let worker = Task.detached(priority: .userInitiated) {
            try await importer.importSource(
                source,
                maximumProjectCount: hasPro
                    ? nil : ReadAloudAccessPolicy.freeProjectLimit,
                progress: reportProgress
            )
        }
        importWorker = worker
        defer { finishImport(sessionID: sessionID) }

        do {
            _ = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            // A successful result means the atomic publish already committed.
            // Keep it even when Cancel raced with the final move.
            finishImport(sessionID: sessionID)
            await refresh()
            return true
        } catch {
            let wasCancelled = importCancellationRequested
                || worker.isCancelled
                || Task.isCancelled
                || (error is CancellationError)
            finishImport(sessionID: sessionID)
            if !wasCancelled {
                errorMessage = Self.message(for: error)
            }
            return false
        }
    }

    private func receiveImportProgress(
        _ value: ReadAloudImportProgress,
        sessionID: UUID
    ) {
        guard importSessionID == sessionID,
              !importCancellationRequested,
              importWorker?.isCancelled == false,
              importProgress != nil,
              value.stage != .finished else {
            return
        }
        importProgress = value
    }

    private func finishImport(sessionID: UUID) {
        guard importSessionID == sessionID else { return }
        // Invalidate the session before any queued callback can run.
        importSessionID = nil
        importWorker = nil
        importCancellationRequested = false
        importProgress = nil
    }

    func sourceLabel(_ type: ProjectSourceType) -> String {
        switch type {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .document: "Document"
        case .paste: "Text"
        }
    }

    private var sortPredicate: (Entry, Entry) -> Bool {
        switch sortOption {
        case .recentlyUpdated:
            return { lhs, rhs in
                if lhs.snapshot.updatedAt != rhs.snapshot.updatedAt {
                    return lhs.snapshot.updatedAt > rhs.snapshot.updatedAt
                }
                return lhs.snapshot.title.localizedStandardCompare(
                    rhs.snapshot.title
                ) == .orderedAscending
            }
        case .recentlyAdded:
            return { lhs, rhs in
                if lhs.snapshot.createdAt != rhs.snapshot.createdAt {
                    return lhs.snapshot.createdAt > rhs.snapshot.createdAt
                }
                return lhs.snapshot.title.localizedStandardCompare(
                    rhs.snapshot.title
                ) == .orderedAscending
            }
        case .title:
            return { lhs, rhs in
                lhs.snapshot.title.localizedStandardCompare(
                    rhs.snapshot.title
                ) == .orderedAscending
            }
        }
    }

    private func artworkURL(
        snapshot: ProjectSnapshot,
        rootURL: URL
    ) -> URL? {
        guard let relativePath = snapshot.artworkRelativePath else {
            return nil
        }

        var url = ProjectPackagePaths.packageURL(
            projectID: snapshot.id,
            rootURL: rootURL
        )
        for component in relativePath.split(separator: "/") {
            url.append(
                path: String(component),
                directoryHint: .inferFromPath
            )
        }
        return url
    }

    nonisolated private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
