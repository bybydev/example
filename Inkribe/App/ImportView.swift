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
    @State private var showDiscardConfirmation = false
    @FocusState private var focusedField: Field?
    var onImported: ([UUID]) -> Void = { _ in }
    private enum Field: Hashable { case title, width, height }
    private var busy: Bool { model.isImporting || model.isPreparingPhotos }
    private var isDirty: Bool {
        busy || !model.selectedSources.isEmpty || !model.photoEntries.isEmpty ||
            !model.reviewingSources.isEmpty || preset != .original ||
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            customWidth != "1080" || customHeight != "1920"
    }

    var body: some View {
        NavigationStack {
            importForm.navigationTitle("New Project").navigationBarTitleDisplayMode(.inline).themedSurface()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: requestCancel)
                            .disabled(model.isCommittingProject)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isImporting {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(model.isCommittingProject ? "Finishing…" : "Creating…")
                            }
                            .accessibilityElement(children: .combine)
                        } else {
                            Button("Create", action: createProject).disabled(busy)
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = nil }
                    }
                }
                .interactiveDismissDisabled(busy || isDirty)
                .onChange(of: model.isCommittingProject) { _, committing in
                    if committing { showDiscardConfirmation = false }
                }
                .onChange(of: model.importCompletion?.id) { _, _ in
                    guard let completion = model.importCompletion else { return }
                    finish(completion)
                }
                .fullScreenCover(item: Binding(
                    get: { model.photoPicker },
                    set: { model.photoPicker = $0 })) { request in
                    PhotosVideoPicker(selectionLimit: request.selectionLimit) { picks in
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
                .alert("Can’t create project", isPresented: Binding(get: { model.alertMessage != nil },
                    set: { if !$0 { model.alertMessage = nil } })) {
                    Button("OK", role: .cancel) { model.alertMessage = nil }
                } message: { Text(model.alertMessage ?? "") }
        }
    }

    private var importForm: some View {
        Form {
            Group { projectSettings; clips }
                .listRowBackground(theme.surfaceColor).listRowSeparatorTint(theme.borderColor)
        }
        .scrollDismissesKeyboard(.interactively)
        .alert("Discard new project?", isPresented: $showDiscardConfirmation) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard", role: .destructive, action: discard)
        } message: {
            Text("Your selected clips and project settings will be discarded.")
        }
    }
    private var projectSettings: some View {
        Section("Project") {
            TextField("Project name", text: $title)
                .focused($focusedField, equals: .title)
                .submitLabel(.done)
                .onSubmit { focusedField = nil }
                .accessibilityLabel("Project name")
            Picker("Format", selection: $preset) {
                Text("Original media").tag(CanvasPreset.original)
                Text("Portrait 9:16").tag(CanvasPreset.portrait)
                Text("Square 1:1").tag(CanvasPreset.square)
                Text("Landscape 16:9").tag(CanvasPreset.landscape)
                Text("Custom").tag(CanvasPreset.custom)
            }
            if preset == .custom {
                HStack {
                    TextField("Width", text: $customWidth)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .width)
                        .accessibilityLabel("Canvas width")
                    Text("×")
                    TextField("Height", text: $customHeight)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .height)
                        .accessibilityLabel("Canvas height")
                }
            }
        }.disabled(model.isImporting)
    }
    private var clips: some View {
        Section {
            ForEach(Array(model.sourceOrder.enumerated()), id: \.element) { index, id in
                selectionRow(index: index, id: id)
            }
            addClipsRow
        } header: {
            Text(model.sourceOrder.isEmpty ? "Clips" : "Clips · \(model.sourceOrder.count)")
        } footer: {
            clipsFooter
        }
    }
    private var addClipsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add clips", systemImage: "plus")
            HStack(spacing: 10) {
                Button("Photos", systemImage: "photo.on.rectangle") {
                    guard model.remainingClipCapacity > 0 else {
                        model.alertMessage = model.clipLimitMessage
                        return
                    }
                    model.openPhotos()
                }
                .buttonStyle(.bordered)
                Button("Files", systemImage: "folder") {
                    guard model.remainingClipCapacity > 0 else {
                        model.alertMessage = model.clipLimitMessage
                        return
                    }
                    fileSelectionID = model.importSelectionID
                    isPickingFiles = true
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
        .disabled(busy)
    }
    @ViewBuilder private var clipsFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.photoFailures.isEmpty
                ? "Clips play from top to bottom. Originals are copied into this project on your iPhone."
                : "Retry or remove these selections before creating the project. Clips play in this order.")
            if model.remainingClipCapacity == 0 {
                Text(model.clipLimitMessage)
            }
        }
        .font(.footnote)
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
        let position = model.selectedSources.firstIndex { $0.id == source.id } ?? 0
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
                    Button("Move earlier", systemImage: "arrow.up") { model.moveSource(source.id, offset: -1) }.disabled(position == 0)
                    Button("Move later", systemImage: "arrow.down") { model.moveSource(source.id, offset: 1) }.disabled(position == model.selectedSources.count - 1)
                    Button("Remove", systemImage: "trash", role: .destructive) { model.removeSource(source.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
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
    private var creationValidationMessage: String? {
        if model.isImporting { return "A project is already being created." }
        if model.isPreparingPhotos { return "Wait for the selected videos to finish preparing." }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a project name." }
        if name.count > 256 { return "Enter a project name up to 256 characters." }
        if model.allProjects.contains(where: {
            $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) { return "That project name is already taken. Choose another name." }
        if model.sourceOrder.isEmpty { return "Choose at least one video to create a project." }
        if model.sourceOrder.count > ProjectLimits.maximumClips { return model.clipLimitMessage }
        if !model.photoFailures.isEmpty { return "Retry or remove the videos that failed to load." }
        if !model.reviewingSources.isEmpty { return "Wait for the selected videos to finish checking." }
        if !model.canCreateProject { return "Choose a valid video for each clip before creating the project." }
        return nil
    }
    private func createProject() {
        focusedField = nil
        if let message = creationValidationMessage {
            model.alertMessage = message
            return
        }
        do { model.beginImport(preset: preset, canvas: try dimensions(), title: title) }
        catch { model.alertMessage = error.localizedDescription }
    }
    private func finish(_ completion: ImportCompletion) {
        guard !handedOff, completion.projectIDs.count == 1 else { return }
        handedOff = true; onImported(completion.projectIDs); dismiss()
    }
    private func requestCancel() {
        focusedField = nil
        guard !model.isCommittingProject else { return }
        guard isDirty else {
            handedOff = true
            dismiss()
            return
        }
        showDiscardConfirmation = true
    }
    private func discard() {
        focusedField = nil
        guard !model.isCommittingProject else { return }
        handedOff = true
        if model.isImporting { model.cancelImport() }
        if model.isPreparingPhotos { model.cancelPhotoPreparation() }
        dismiss()
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
        RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemFill)).frame(width: 48, height: 48).overlay {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(width: 48, height: 48).clipped() }
            else { Image(systemName: symbol ?? (audio ? "waveform" : "film")).foregroundStyle(.secondary) }
        }.clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }
}
