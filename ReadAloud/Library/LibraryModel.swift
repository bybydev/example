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

    func importFile(_ url: URL) async -> Bool {
        guard let importer else {
            errorMessage = initializationError ?? "Import is unavailable."
            return false
        }

        importProgress = ReadAloudImportProgress(
            stage: .preparing,
            fractionCompleted: 0,
            detail: url.lastPathComponent
        )

        do {
            _ = try await importer.importSource(
                .file(url),
                progress: { [weak self] value in
                    Task { @MainActor in
                        self?.importProgress = value
                    }
                }
            )
            importProgress = nil
            await refresh()
            return true
        } catch is CancellationError {
            importProgress = nil
            return false
        } catch {
            importProgress = nil
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func importPaste(
        text: String,
        suggestedTitle: String?
    ) async -> Bool {
        guard let importer else {
            errorMessage = initializationError ?? "Import is unavailable."
            return false
        }

        importProgress = ReadAloudImportProgress(
            stage: .preparing,
            fractionCompleted: 0,
            detail: "Pasted Text"
        )

        do {
            _ = try await importer.importSource(
                .pastedText(
                    text,
                    suggestedTitle: suggestedTitle
                ),
                progress: { [weak self] value in
                    Task { @MainActor in
                        self?.importProgress = value
                    }
                }
            )
            importProgress = nil
            await refresh()
            return true
        } catch is CancellationError {
            importProgress = nil
            return false
        } catch {
            importProgress = nil
            errorMessage = Self.message(for: error)
            return false
        }
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
