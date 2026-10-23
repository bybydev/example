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
            return PickedMovie(localURL: copy)
        }
    }
}

/// Main-actor UI state only. One ProjectRepository actor owns every project
/// transaction; this model is shared by all P1 navigation and sheets.
@MainActor
@Observable
final class ProjectsModel {
    let repository = ProjectRepository.shared
    let access: ProAccess
    let transcription: TranscriptionController
    let exports: ExportController
    private let importer = MediaImporter(repository: .shared)
    private let thumbnails = ProjectThumbnails(repository: .shared)

    var projects: [ProjectSummary] = []
    var libraryIssues: [LibraryIssue] = []
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
    private var importTask: Task<Void, Never>?
    private var libraryGeneration = 0
    private var storageGeneration = 0

    init() {
        let access = ProAccess()
        self.access = access
        transcription = TranscriptionController(access: access)
        exports = ExportController(access: access)
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
        } catch {
            alertMessage = "An unfinished import could not be recovered: " + error.localizedDescription
        }
        await refreshLibrary()
        await refreshStorage()
    }

    /// Search, filters and thumbnail work all publish through the same guard.
    private func refreshLibrary() async {
        libraryGeneration += 1
        let generation = libraryGeneration
        let query = search, requestedSort = sort, requestedFilter = filter
        isLoading = true
        defer { if generation == libraryGeneration { isLoading = false } }
        do {
            let snapshot = try await repository.list(titleQuery: query, sort: requestedSort, filter: requestedFilter)
            guard generation == libraryGeneration, query == search, requestedSort == sort, requestedFilter == filter else { return }
            projects = snapshot.projects
            libraryIssues = snapshot.issues
        } catch {
            if generation == libraryGeneration { alertMessage = error.localizedDescription }
        }
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
        } catch {
            if generation == storageGeneration { alertMessage = error.localizedDescription }
        }
    }

    func addFiles(_ urls: [URL]) {
        guard !isImporting, !isPreparingPhotos else { return }
        selectedSources += urls.map {
            ImportInput(localURL: $0, origin: .files, displayName: $0.lastPathComponent)
        }
    }

    func addPhotos(_ items: [PhotosPickerItem]) async {
        guard !isImporting, !isPreparingPhotos else { return }
        isPreparingPhotos = true
        defer { isPreparingPhotos = false }
        let session = selectionSession
        for item in items {
            do {
                try Task.checkCancellation()
                guard let file = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw ProjectStoreError.unsupportedMedia
                }
                guard selectionSession == session else {
                    try? FileManager.default.removeItem(at: file.localURL)
                    return
                }
                ownedPhotoURLs.insert(file.localURL)
                selectedSources.append(ImportInput(localURL: file.localURL, origin: .photos,
                                                       displayName: file.localURL.lastPathComponent))
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

    func clearSelection() {
        selectionSession = UUID()
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
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            do {
                let result = try await importer.importFiles(
                    sources, disposition: disposition, preset: preset,
                    customCanvas: canvas
                )
                if result.failures.isEmpty {
                    clearSelection()
                    importMessage = "\(result.documents.count) project(s) imported."
                } else {
                    importMessage = result.failures.map {
                        $0.filename + ": " + $0.reason
                    }.joined(separator: "\n")
                }
                await refresh()
                await generateMissingThumbnails(for: result.documents)
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
                        preset: CanvasPreset) {
        guard !isImporting, !isPreparingPhotos else { return }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            alertMessage = "Enter a valid HTTPS media URL."
            return
        }
        isImporting = true
        importMessage = nil
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            do {
                let document = try await importer.importDirectURL(
                    url, rightsConfirmed: rightsConfirmed, preset: preset
                )
                importMessage = "Imported " + document.title
                await refresh()
                await generateMissingThumbnails(for: [document])
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

    func generateMissingThumbnails(for documents: [ProjectDocument]) async {
        for document in documents {
            do {
                _ = try await thumbnails.regenerate(projectID: document.id)
            } catch {
                // A derived thumbnail may fail for a valid unsupported frame.
                // Don't recast a committed media project as an import failure.
            }
        }
        await refreshLibrary()
    }

    func regenerateThumbnail(_ id: UUID) async {
        do {
            _ = try await thumbnails.regenerate(projectID: id)
            await refreshLibrary()
        } catch {
            // No thumbnail is a supported recoverable cache state.
        }
    }

    /// Return the committed revision to the editor; refreshing/reopening here
    /// must not replace a title draft that changed while the write was pending.
    func rename(_ project: ProjectDocument, to title: String) async throws -> ProjectDocument {
        try await repository.rename(project.id, title: title,
                                    expectedRevision: project.contentRevision)
    }

    func duplicate(_ id: UUID) async {
        do {
            let copied = try await repository.duplicate(id)
            await refresh()
            await generateMissingThumbnails(for: [copied])
        } catch { alertMessage = error.localizedDescription }
    }

    func trash(_ id: UUID) async {
        guard transcription.persistenceError == nil else {
            alertMessage = "Resolve the transcription storage problem before moving projects to Trash."
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
        do { try await repository.restoreFromTrash(id); await refresh() }
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
