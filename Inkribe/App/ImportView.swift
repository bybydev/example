import AppFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One creation transaction always publishes exactly one project.
struct ImportView: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isPickingFiles = false
    @State private var fileSelectionID: UUID?
    @State private var preset = CanvasPreset.original
    @State private var title = ""
    @State private var customWidth = "1080"
    @State private var customHeight = "1920"
    @State private var handedOff = false
    var onImported: ([UUID]) -> Void = { _ in }
    private var busy: Bool { model.isImporting || model.isPreparingPhotos }

    var body: some View {
        NavigationStack {
            importForm.navigationTitle("New Project").navigationBarTitleDisplayMode(.inline).themedSurface()
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                } }
                .interactiveDismissDisabled(busy)
                .onChange(of: model.importCompletion?.id) { _, _ in
                    guard let completion = model.importCompletion, !completion.hasFailures else { return }
                    finish(completion)
                }
                .fullScreenCover(item: Binding(
                    get: { model.photoPicker },
                    set: { model.photoPicker = $0 })) { request in
                    PhotosVideoPicker { picks in
                        model.receivePhotos(picks, request: request)
                    }
                }
                .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
                    guard let fileSelectionID, fileSelectionID == model.importSelectionID else { return }
                    switch result {
                    case .success(let urls): model.addFiles(urls, selectionID: fileSelectionID)
                    case .failure(let error):
                        let failure = error as NSError
                        if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError { model.alertMessage = error.localizedDescription }
                    }
                }
                .alert("Import problem", isPresented: Binding(get: { model.alertMessage != nil },
                    set: { if !$0 { model.alertMessage = nil } })) {
                    Button("OK", role: .cancel) { model.alertMessage = nil }
                } message: { Text(model.alertMessage ?? "") }
        }
    }

    private var importForm: some View {
        Form {
            Group { introduction; sources; photoPreparation; selectedMedia; projectSettings; creation }
                .listRowBackground(theme.surfaceColor).listRowSeparatorTint(theme.borderColor)
        }
    }
    private var introduction: some View {
        Section {
            Label("Start with your videos", systemImage: "captions.bubble").font(.headline)
            Text("Choose one video or combine several clips in one project.").font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var sources: some View {
        // Photos presents the same native ordered picker as Add clips, so every
        // video hands off an NSItemProvider instead of a loadTransferable item.
        Section {
            Button { model.openPhotos() } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            Button("Files", systemImage: "folder") { fileSelectionID = model.importSelectionID; isPickingFiles = true }
        }.disabled(busy)
    }
    @ViewBuilder private var photoPreparation: some View {
        if model.isPreparingPhotos {
            Section {
                ProgressView("Preparing videos from Photos…")
                Button("Cancel preparation", role: .cancel) { model.cancelPhotoPreparation() }
            }
        }
    }
    @ViewBuilder private var selectedMedia: some View {
        if !model.sourceOrder.isEmpty {
            Section {
                ForEach(Array(model.sourceOrder.enumerated()), id: \.element) { index, id in
                    selectionRow(index: index, id: id)
                }
            } header: { Text("Clips · \(model.sourceOrder.count)") }
            footer: {
                Text(model.photoFailures.isEmpty
                    ? "Clips play from top to bottom. Originals are copied into this project on your iPhone."
                    : "Retry or remove these selections before creating the project. Clips play in this order.")
            }
        }
    }
    @ViewBuilder private func selectionRow(index: Int, id: UUID) -> some View {
        if let source = model.selectedSources.first(where: { $0.id == id }) {
            sourceRow(source, index: index)
        } else if let entry = model.photoEntries[id], case .failed(let message) = entry.stage {
            failedPhotoRow(entry, number: index + 1, message: message)
        } else if let entry = model.photoEntries[id] {
            pendingPhotoRow(entry, number: index + 1)
        }
    }
    private func sourceRow(_ source: ImportInput, index: Int) -> some View {
        let review = model.sourceReviews[source.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let metadata = review?.metadata {
                    SourceThumbnail(source: source, duration: metadata.duration)
                } else { MediaThumbnail(data: nil) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(index + 1). \(source.displayName)").font(.subheadline).lineLimit(2)
                    if let metadata = review?.metadata { Text(EditorTime.display(metadata.duration)).font(.caption).foregroundStyle(.secondary) }
                    else if model.reviewingSources.contains(source.id) { ProgressView("Checking media…").font(.caption) }
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Move earlier", systemImage: "arrow.up") { model.moveSource(source.id, offset: -1) }.disabled(index == 0)
                    Button("Move later", systemImage: "arrow.down") { model.moveSource(source.id, offset: 1) }.disabled(index == model.selectedSources.count - 1)
                    Button("Remove", systemImage: "trash", role: .destructive) { model.removeSource(source.id) }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .disabled(busy).accessibilityLabel("Actions for \(source.displayName)")
            }
            if let error = review?.error {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Retry media check") { model.reviewSources(retry: source.id) }.disabled(busy)
            }
        }
    }
    private func pendingPhotoRow(_ entry: PhotoMovieSelection, number: Int) -> some View {
        HStack(spacing: 10) {
            MediaThumbnail(data: nil)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number). \(entry.name)").font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    ProgressView()
                    Text(photoStageTitle(entry.stage)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
    private func failedPhotoRow(_ entry: PhotoMovieSelection, number: Int, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                MediaThumbnail(data: nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(number). \(entry.name)").font(.subheadline).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            Text(message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Retry") { model.retryPhotoPreparation(entry.id) }
                Button("Remove", role: .destructive) { model.removePhotoFailure(entry.id) }
            }.buttonStyle(.borderless)
        }
    }
    private func photoStageTitle(_ stage: PhotoMovieSelection.Stage) -> String {
        switch stage {
        case .waiting: "Waiting…"
        case .loading: "Loading from Photos…"
        case .retrying: "Retrying Photos access…"
        case .copying: "Copying video…"
        case .failed: ""
        }
    }
    private var projectSettings: some View {
        Section("Project") {
            TextField("Project name (optional)", text: $title).accessibilityLabel("Project name")
            Picker("Format", selection: $preset) {
                Text("Original media").tag(CanvasPreset.original)
                Text("Portrait 9:16").tag(CanvasPreset.portrait)
                Text("Square 1:1").tag(CanvasPreset.square)
                Text("Landscape 16:9").tag(CanvasPreset.landscape)
                Text("Custom").tag(CanvasPreset.custom)
            }
            if preset == .custom {
                HStack {
                    TextField("Width", text: $customWidth).keyboardType(.numberPad).accessibilityLabel("Canvas width")
                    Text("×")
                    TextField("Height", text: $customHeight).keyboardType(.numberPad).accessibilityLabel("Canvas height")
                }
            }
        }.disabled(busy)
    }
    @ViewBuilder private var creation: some View {
        if model.isImporting {
            Section {
                ProgressView("Copying, checking and saving your project…")
                Button("Cancel creation", role: .cancel) { model.cancelImport() }
            }
        } else if !model.selectedSources.isEmpty {
            Section {
                Button("Create Project", systemImage: "checkmark.circle") {
                    do { model.beginImport(preset: preset, canvas: try dimensions(), title: title) }
                    catch { model.alertMessage = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(!model.canCreateProject || title.count > 256)
            }
        }
        if let message = model.importMessage {
            Section {
                Text(message).font(.footnote).textSelection(.enabled)
                if let completion = model.importCompletion, !completion.projectIDs.isEmpty { Button("Open project") { finish(completion) } }
            }
        }
    }
    private func finish(_ completion: ImportCompletion) {
        guard !handedOff, completion.projectIDs.count == 1 else { return }
        handedOff = true; onImported(completion.projectIDs); dismiss()
    }
    private func dimensions() throws -> ProjectCanvas? {
        guard preset == .custom else { return nil }
        guard let width = Int(customWidth), let height = Int(customHeight) else { throw ProjectStoreError.invalidDocument("Enter dimensions between 64 and 8192 pixels.") }
        let value = ProjectCanvas(width: width, height: height); try value.validate(); return value
    }
}

struct MediaThumbnail: View {
    let data: Data?
    var audio = false
    var symbol: String? = nil
    var body: some View {
        RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 48, height: 60).overlay {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 60).clipped() }
            else { Image(systemName: symbol ?? (audio ? "waveform" : "film")).foregroundStyle(.secondary) }
        }.clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }
}
