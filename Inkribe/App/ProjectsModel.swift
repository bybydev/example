import CoreTransferable
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// PhotosPicker's URL transfers are not durable. Copy while its
/// FileRepresentation callback owns the security scope; never load movie Data.
struct PickedMovie: Transferable {
    let localURL: URL
    let displayName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("InkribePhotoTransfers", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = received.file.pathExtension
            let copy = directory.appendingPathComponent(UUID().uuidString
                + (ext.isEmpty ? ".mov" : "." + ext))
            do {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: received.file, to: copy)
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
            // The owned copy has an intentionally opaque name. Keep the
            // provider's display name separate from that storage identity.
            let name = received.file.lastPathComponent
            let stem = received.file.deletingPathExtension().lastPathComponent
            let displayName = name.isEmpty || UUID(uuidString: stem) != nil ? "Imported Video" : name
            return PickedMovie(localURL: copy, displayName: displayName)
        }
    }
}

struct ImportCompletion: Identifiable, Sendable {
    let id = UUID()
    let projectIDs: [UUID]
    let hasFailures: Bool
}

/// Main-actor UI state only. One ProjectRepository actor owns every project
/// transaction; this model is shared by all P1 navigation and sheets.
@MainActor
@Observable
final class ProjectsModel {
    let repository = ProjectRepository.shared
    let access: ProAccess
    let processing: ProcessingCoordinator
    let editors: EditorSessions
    var transcription: TranscriptionController { processing.transcription }
    var exports: ExportController { processing.exports }
    private let importer = MediaImporter(repository: .shared)
    private let thumbnails = ProjectThumbnails(repository: .shared)

    private(set) var allProjects: [ProjectSummary] = []
    private(set) var mutatingProjectIDs: Set<UUID> = []
    private(set) var importCompletion: ImportCompletion?
    var isFiltering: Bool { !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter != .all }
    var projects: [ProjectSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return allProjects.filter { project in
            let matches: Bool
            switch filter {
            case .all: matches = true
            case .video: matches = project.mediaKind == .video
            case .audio: matches = project.mediaKind == .audio
            case .missingMedia: matches = !project.available
            }
            return matches && (query.isEmpty || project.title.localizedStandardContains(query))
        }.sorted { a, b in
            switch sort {
            case .recent: if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            case .oldest: if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
            case .title:
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return a.id.uuidString < b.id.uuidString
        }
    }
    var libraryIssues: [LibraryIssue] = []
    private(set) var libraryError: String?
    private(set) var storageError: String?
    private(set) var recoveryIssue: String?
    var pendingEdits: [ProjectSaveItem] {
        editors.pending.filter { $0.saveError != nil }.map { session in
            let title = session.document?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProjectSaveItem(id: session.projectID,
                title: title?.isEmpty == false ? title! : "Untitled project",
                detail: "Couldn’t save changes. Open to try again.")
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var search = ""
    var sort: LibrarySort = .recent
    var filter: LibraryFilter = .all
    var cacheGeneration = 0
    var isLoading = false
    var isImporting = false
    private(set) var isPreparingPhotos = false
    var alertMessage: String?
    var importMessage: String?
    var selectedSources: [ImportInput] = []
    var storage: ProjectRepository.StorageUsage?
    var trashed: [ProjectRepository.TrashedProject] = []
    var pendingStaging: [UUID] = []
    private var ownedPhotoURLs: Set<URL> = []
    private var selectionSession = UUID()
    var importSelectionID: UUID { selectionSession }
    private var importTask: Task<Void, Never>?
    private var importedInSession: [UUID] = []
    private var photoTask: Task<Void, Never>?
    private var libraryGeneration = 0
    private var storageGeneration = 0
    private var thumbnailJobs: Set<UUID> = []

    init() {
        let access = ProAccess()
        self.access = access
        processing = ProcessingCoordinator(access: access)
        editors = EditorSessions(access: access)
        // These ingress copies have no durable authority: committed projects
        // own their originals in the repository. Safe once, before new picks.
        for name in ["InkribePhotoTransfers", "InkribeURLImports"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { alertMessage = "Temporary import files could not be cleaned up: " + error.localizedDescription }
            }
        }
    }

    func refresh() async {
        do {
            _ = try await repository.recoverCommittedStaging()
            recoveryIssue = nil
        } catch {
            recoveryIssue = "An unfinished import needs attention: " + error.localizedDescription
        }
        await refreshLibrary()
        await refreshStorage()
    }

    /// Disk snapshots refresh on actual library events. Query/filter/sort are
    /// pure projections of this cache and cannot enqueue filesystem scans.
    func refreshLibrary() async {
        libraryGeneration += 1
        let generation = libraryGeneration
        isLoading = true
        defer { if generation == libraryGeneration { isLoading = false } }
        do {
            let snapshot = try await repository.list()
            guard generation == libraryGeneration else { return }
            allProjects = snapshot.projects
            libraryIssues = snapshot.issues
            libraryError = nil
        } catch {
            if generation == libraryGeneration { libraryError = error.localizedDescription }
        }
    }

    func clearLibraryFilters() { search = ""; filter = .all }

    func prepareImport() {
        guard !isImporting, !isPreparingPhotos else { return }
        importCompletion = nil
        importMessage = nil
        importedInSession = []
        clearSelection()
    }

    func refreshStorage() async {
        storageGeneration += 1
        let generation = storageGeneration
        do {
            let usage = try await repository.storageUsage()
            let trash = try await repository.trashedProjects()
            let pending = try await repository.pendingStagingIDs()
            guard generation == storageGeneration else { return }
            storage = usage; trashed = trash; pendingStaging = pending
            storageError = nil
        } catch {
            if generation == storageGeneration { storageError = error.localizedDescription }
        }
    }

    func addFiles(_ urls: [URL], selectionID: UUID) {
        guard selectionID == selectionSession, !isImporting, !isPreparingPhotos else { return }
        selectedSources += urls.map {
            ImportInput(localURL: $0, origin: .files, displayName: $0.lastPathComponent)
        }
    }

    func beginPhotoPreparation(_ items: [PhotosPickerItem]) {
        guard !isImporting, !isPreparingPhotos, !items.isEmpty else { return }
        isPreparingPhotos = true
        let session = selectionSession
        photoTask = Task { await addPhotos(items, session: session) }
    }

    private func addPhotos(_ items: [PhotosPickerItem], session: UUID) async {
        guard selectionSession == session else { return }
        defer {
            if selectionSession == session { isPreparingPhotos = false; photoTask = nil }
        }
        for item in items {
            do {
                try Task.checkCancellation()
                guard session == selectionSession else { return }
                guard let file = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw ProjectStoreError.unsupportedMedia
                }
                guard selectionSession == session else {
                    try? FileManager.default.removeItem(at: file.localURL)
                    return
                }
                ownedPhotoURLs.insert(file.localURL)
                selectedSources.append(ImportInput(localURL: file.localURL, origin: .photos,
                                                       displayName: file.displayName))
            } catch is CancellationError {
                return
            } catch {
                guard selectionSession == session else { return }
                alertMessage = "A Photos video could not be prepared: " + error.localizedDescription
            }
        }
    }

    func removeSource(_ id: UUID) {
        guard !isImporting, !isPreparingPhotos else { return }
        for source in selectedSources where source.id == id {
            if ownedPhotoURLs.remove(source.localURL) != nil {
                try? FileManager.default.removeItem(at: source.localURL)
            }
        }
        selectedSources.removeAll { $0.id == id }
    }

    func cancelPhotoPreparation() {
        photoTask?.cancel(); photoTask = nil
        selectionSession = UUID()
        isPreparingPhotos = false
    }

    func clearSelection() {
        cancelPhotoPreparation()
        for url in ownedPhotoURLs { try? FileManager.default.removeItem(at: url) }
        ownedPhotoURLs.removeAll()
        selectedSources.removeAll()
    }

    func beginImport(disposition: ImportDisposition, preset: CanvasPreset,
                     canvas: ProjectCanvas? = nil) {
        guard !isImporting, !isPreparingPhotos, !selectedSources.isEmpty else { return }
        let sources = selectedSources
        isImporting = true
        importMessage = nil
        importCompletion = nil
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            do {
                let result = try await importer.importFiles(
                    sources, disposition: disposition, preset: preset,
                    customCanvas: canvas
                )
                for document in result.documents where !importedInSession.contains(document.id) {
                    importedInSession.append(document.id)
                }
                if disposition == .separateProjects {
                    let committed = Set(result.documents.map(\.id))
                    for source in selectedSources where committed.contains(source.id) {
                        if ownedPhotoURLs.remove(source.localURL) != nil { try? FileManager.default.removeItem(at: source.localURL) }
                    }
                    selectedSources.removeAll { committed.contains($0.id) }
                }
                let stopped = result.wasCancelled || Task.isCancelled
                if (result.failures.isEmpty && !stopped) || (disposition == .combineAsClips && !result.documents.isEmpty) {
                    clearSelection()
                }
                let count = importedInSession.count
                let saved = count == 1 ? "1 project saved." : "\(count) projects saved."
                importMessage = (count > 0 ? saved + "\n" : "")
                    + (stopped ? "Import stopped. Remaining files have not been imported.\n" : "")
                    + result.failures.map { $0.filename + ": " + $0.reason }.joined(separator: "\n")
                await refreshLibrary()
                importCompletion = ImportCompletion(projectIDs: importedInSession,
                    hasFailures: !result.failures.isEmpty || stopped)
                // Publication/navigation do not wait for derived JPEGs or storage accounting.
                Task { await generateMissingThumbnails(for: result.documents); await refreshStorage() }
            } catch is CancellationError {
                importMessage = "Import cancelled. Already committed projects are preserved."
                await refresh()
            } catch {
                alertMessage = error.localizedDescription
                await refresh()
            }
        }
    }

    func beginURLImport(text: String, rightsConfirmed: Bool,
                        preset: CanvasPreset, canvas: ProjectCanvas? = nil) {
        guard !isImporting, !isPreparingPhotos else { return }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else {
            alertMessage = "Enter a valid HTTPS media URL."
            return
        }
        isImporting = true
        importMessage = nil
        importCompletion = nil
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            do {
                let document = try await importer.importDirectURL(
                    url, rightsConfirmed: rightsConfirmed, preset: preset, customCanvas: canvas
                )
                importMessage = "Imported " + document.title
                clearSelection()
                await refreshLibrary()
                if Task.isCancelled { importMessage = "Import stopped. The saved project is available." }
                if !importedInSession.contains(document.id) { importedInSession.append(document.id) }
                importCompletion = ImportCompletion(projectIDs: importedInSession, hasFailures: Task.isCancelled)
                Task { await generateMissingThumbnails(for: [document]); await refreshStorage() }
            } catch is CancellationError {
                importMessage = "Download cancelled."
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func makeThumbnail(_ id: UUID) async -> Bool {
        guard thumbnailJobs.insert(id).inserted else { return false }
        defer { thumbnailJobs.remove(id) }
        do { _ = try await thumbnails.regenerate(projectID: id); return true }
        catch { return false } // Derived images never turn a committed import into a failure.
    }

    func generateMissingThumbnails(for documents: [ProjectDocument]) async {
        for document in documents { _ = await makeThumbnail(document.id) }
        await refreshLibrary()
    }

    func regenerateThumbnail(_ id: UUID) async {
        if await makeThumbnail(id) { await refreshLibrary() }
    }

    func rename(_ summary: ProjectSummary, to title: String) async throws {
        guard !editors.hasPending(summary.id) else { throw CaptionEditError.unsavedChanges }
        guard !transcription.isActive(summary.id), !mutatingProjectIDs.contains(summary.id) else { throw SpeechError.busy }
        mutatingProjectIDs.insert(summary.id)
        defer { mutatingProjectIDs.remove(summary.id) }
        do {
            _ = try await repository.rename(summary.id, title: title, expectedRevision: summary.contentRevision)
            await refreshLibrary()
        } catch {
            await refreshLibrary()
            throw error
        }
    }

    func duplicate(_ id: UUID) async {
        guard mutatingProjectIDs.insert(id).inserted else { return }
        defer { mutatingProjectIDs.remove(id) }
        do {
            guard !editors.hasPending(id) else { throw CaptionEditError.unsavedChanges }
            let copied = try await repository.duplicate(id)
            await refresh()
            await generateMissingThumbnails(for: [copied])
        } catch { alertMessage = error.localizedDescription }
    }

    func trash(_ id: UUID) async {
        guard mutatingProjectIDs.insert(id).inserted else { return }
        defer { mutatingProjectIDs.remove(id) }
        guard transcription.persistenceError == nil else {
            alertMessage = "Resolve the transcription storage problem before moving projects to Trash."
            return
        }
        guard !editors.hasPending(id) else {
            alertMessage = "This project has changes that couldn’t be saved. Open it and try saving again before moving it to Trash."
            return
        }
        guard !transcription.isActive(id) else {
            alertMessage = "Cancel this project's transcription before moving it to Trash."
            return
        }
        do { try await repository.moveToTrash(id); await refresh() }
        catch { alertMessage = error.localizedDescription }
    }

    func restore(_ id: UUID) async {
        do {
            try await repository.restoreFromTrash(id)
            cacheGeneration += 1
            await refresh()
        }
        catch { alertMessage = error.localizedDescription }
    }

    func purgeCache() async {
        do {
            try await repository.purgeDerivedCache()
            cacheGeneration += 1
            await refresh()
        }
        catch { alertMessage = error.localizedDescription }
    }

    func emptyTrash() async {
        guard transcription.persistenceError == nil else {
            alertMessage = "Resolve the transcription storage problem before emptying Trash."
            return
        }
        do { try await repository.emptyTrash(); await refresh() }
        catch { alertMessage = error.localizedDescription }
    }

    func discardPending(_ id: UUID) async {
        do { try await repository.discardPendingImport(id: id); await refresh() }
        catch { alertMessage = error.localizedDescription }
    }

    func relink(projectID: UUID, assetID: UUID, from url: URL) async {
        do {
            try await repository.restoreMissingOriginal(projectID: projectID,
                                                       assetID: assetID, from: url)
            await refresh()
            await regenerateThumbnail(projectID)
        } catch { alertMessage = error.localizedDescription }
    }
}

struct ProjectSaveItem: Identifiable {
    let id: UUID
    let title: String
    let detail: String
}
