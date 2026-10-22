import CoreTransferable
import Foundation
import Observation
import PhotosUI
import UniformTypeIdentifiers

/// PhotosPicker's URL transfers are not durable. Copy while its
/// FileRepresentation callback owns the security scope; never load movie Data.
struct IOSPickedMovie: Transferable {
    let localURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("InkribePhotoTransfers", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = received.file.pathExtension
            let copy = directory.appendingPathComponent(UUID().uuidString
                + (ext.isEmpty ? ".mov" : "." + ext))
            try FileManager.default.copyItem(at: received.file, to: copy)
            return IOSPickedMovie(localURL: copy)
        }
    }
}

/// Main-actor UI state only. One IOSProjectRepository actor owns every project
/// transaction; this model is shared by all P1 navigation and sheets.
@MainActor
@Observable
final class IOSProjectsModel {
    let repository = IOSProjectRepository.shared
    let transcription = IOSTranscriptionController()
    let exports = IOSExportController()
    private let importer = IOSMediaImporter(repository: .shared)
    private let thumbnails = IOSProjectThumbnails(repository: .shared)

    var projects: [IOSProjectSummary] = []
    var libraryIssues: [IOSLibraryIssue] = []
    var search = ""
    var sort: IOSLibrarySort = .recent
    var filter: IOSLibraryFilter = .all
    var cacheGeneration = 0
    var isLoading = false
    var isImporting = false
    var alertMessage: String?
    var importMessage: String?
    var selectedSources: [IOSImportInput] = []
    var storage: IOSProjectRepository.StorageUsage?
    var trashed: [IOSProjectRepository.TrashedProject] = []
    var pendingStaging: [UUID] = []
    private var ownedPhotoURLs: Set<URL> = []
    private var selectionSession = UUID()
    private var importTask: Task<Void, Never>?

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            do {
                _ = try await repository.recoverCommittedStaging()
            } catch {
                alertMessage = "An unfinished import could not be recovered: " + error.localizedDescription
            }
            let snapshot = try await repository.list(titleQuery: search, sort: sort, filter: filter)
            projects = snapshot.projects
            libraryIssues = snapshot.issues
            await refreshStorage()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func refreshStorage() async {
        do {
            storage = try await repository.storageUsage()
            trashed = try await repository.trashedProjects()
            pendingStaging = try await repository.pendingStagingIDs()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func addFiles(_ urls: [URL]) {
        selectedSources += urls.map {
            IOSImportInput(localURL: $0, origin: .files, displayName: $0.lastPathComponent)
        }
    }

    func addPhotos(_ items: [PhotosPickerItem]) async {
        let session = selectionSession
        for item in items {
            do {
                try Task.checkCancellation()
                guard let file = try await item.loadTransferable(type: IOSPickedMovie.self) else {
                    throw IOSProjectStoreError.unsupportedMedia
                }
                guard selectionSession == session else {
                    try? FileManager.default.removeItem(at: file.localURL)
                    return
                }
                ownedPhotoURLs.insert(file.localURL)
                selectedSources.append(IOSImportInput(localURL: file.localURL, origin: .photos,
                                                       displayName: file.localURL.lastPathComponent))
            } catch {
                alertMessage = "A Photos video could not be prepared: " + error.localizedDescription
            }
        }
    }

    func removeSource(_ id: UUID) {
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

    func beginImport(disposition: IOSImportDisposition, preset: IOSCanvasPreset,
                     canvas: IOSCanvas? = nil) {
        guard !isImporting, !selectedSources.isEmpty else { return }
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
                        preset: IOSCanvasPreset) {
        guard !isImporting, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
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

    func generateMissingThumbnails(for documents: [IOSProjectDocument]) async {
        for document in documents {
            do {
                _ = try await thumbnails.regenerate(projectID: document.id)
            } catch {
                // A derived thumbnail may fail for a valid unsupported frame.
                // Don't recast a committed media project as an import failure.
            }
        }
        let snapshot = try? await repository.list(titleQuery: search, sort: sort, filter: filter)
        if let snapshot { projects = snapshot.projects; libraryIssues = snapshot.issues }
    }

    func regenerateThumbnail(_ id: UUID) async {
        do {
            _ = try await thumbnails.regenerate(projectID: id)
            let snapshot = try await repository.list(titleQuery: search, sort: sort, filter: filter)
            projects = snapshot.projects
        } catch {
            // No thumbnail is a supported recoverable cache state.
        }
    }

    /// Return the committed revision to the editor; refreshing/reopening here
    /// must not replace a title draft that changed while the write was pending.
    func rename(_ project: IOSProjectDocument, to title: String) async throws -> IOSProjectDocument {
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
