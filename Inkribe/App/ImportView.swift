import PhotosUI
import AppFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One creation transaction always publishes exactly one project.
struct ImportView: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var photosSelection: [PhotosPickerItem] = []
    @State private var isPickingFiles = false
    @State private var fileSelectionID: UUID?
    @State private var preset = CanvasPreset.original
    @State private var title = ""
    @State private var customWidth = "1080"
    @State private var customHeight = "1920"
    @State private var mediaURL = ""
    @State private var confirmRights = false
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
                .onChange(of: photosSelection) { _, picked in
                    guard !picked.isEmpty else { return }
                    photosSelection = []; model.beginPhotoPreparation(picked)
                }
                .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.movie, .audio], allowsMultipleSelection: true) { result in
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
            Group { sources; selectedMedia; preparationFailures; projectSettings; directURL; creation }
                .listRowBackground(theme.surfaceColor).listRowSeparatorTint(theme.borderColor)
        }
    }
    private var sources: some View {
        Section {
            Label("Start with your media", systemImage: "captions.bubble").font(.headline)
            Text("Choose one video or combine several clips in one project.").font(.subheadline).foregroundStyle(.secondary)
            PhotosPicker(selection: $photosSelection, maxSelectionCount: 0, selectionBehavior: .ordered, matching: .videos) {
                Label("Photos", systemImage: "photo.on.rectangle")
            }.disabled(busy)
            Button("Files", systemImage: "folder") { fileSelectionID = model.importSelectionID; isPickingFiles = true }.disabled(busy)
            if model.isPreparingPhotos {
                ProgressView("Preparing videos from Photos…")
                Button("Cancel preparation", role: .cancel) { model.cancelPhotoPreparation() }
            }
        }
    }
    @ViewBuilder private var selectedMedia: some View {
        if !model.selectedSources.isEmpty {
            Section {
                ForEach(Array(model.selectedSources.enumerated()), id: \.element.id) { index, source in sourceRow(source, index: index) }
            } header: { Text("Clips · \(model.selectedSources.count)") }
            footer: { Text("Clips play from top to bottom. Originals are copied into this project on your iPhone.") }
        }
    }
    private func sourceRow(_ source: ImportInput, index: Int) -> some View {
        let review = model.sourceReviews[source.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                MediaThumbnail(data: review?.thumbnail, audio: review?.kind == .audio)
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
    @ViewBuilder private var preparationFailures: some View {
        if !model.photoFailures.isEmpty && !model.isPreparingPhotos {
            Section("Videos not prepared") {
                ForEach(model.photoFailures) { failure in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure.name).font(.subheadline)
                        Text(failure.message).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Retry") { model.retryPhotoPreparation(failure.id) }
                            Button("Remove", role: .destructive) { model.removePhotoFailure(failure.id) }
                        }.buttonStyle(.borderless)
                    }
                }
                Text("Retry or remove these videos before creating the project.").font(.footnote)
            }
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
    @ViewBuilder private var directURL: some View {
        if model.selectedSources.isEmpty && model.photoFailures.isEmpty {
            Section {
                DisclosureGroup("Import a direct media URL") {
                    TextField("https://example.com/video.mp4", text: $mediaURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Toggle("I have the rights to import this media", isOn: $confirmRights)
                    Button("Create Project from URL") {
                        do { model.beginURLImport(text: mediaURL, rightsConfirmed: confirmRights, preset: preset, canvas: try dimensions(), title: title) }
                        catch { model.alertMessage = error.localizedDescription }
                    }.disabled(busy || !confirmRights || mediaURL.isEmpty || title.count > 256)
                }
            } footer: { Text("Direct downloadable media only. Transcription starts when you ask for it in the project.") }
        }
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
