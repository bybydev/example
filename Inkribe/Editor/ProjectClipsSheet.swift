import AppFoundation
import SwiftUI

/// One sheet for clip selection and management. New selections are saved
/// automatically as each import finishes; Done only closes the sheet.
struct ProjectClipsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    @Bindable var clipImport: AddClipsModel
    @State private var renamingClip: ProjectClip?
    @State private var pickingFiles = false
    @State private var fileSelectionID: UUID?
    @State private var removingClip: ProjectClip?
    @State private var highlightedClipID: UUID?
    @State private var revealRequest = UUID()
    @State private var error: String?
    @State private var movingClipID: UUID?
    @State private var pendingClose: CloseAction?
    @State private var showingUnfinishedImportAlert = false

    private enum CloseAction: Equatable {
        case dismiss
        case select(UUID)
    }

    init(session: EditorSession, clipImport: AddClipsModel, initialClipID: UUID?) {
        self.session = session
        _clipImport = Bindable(wrappedValue: clipImport)
        _highlightedClipID = State(initialValue: initialClipID)
    }

    var body: some View {
        navigation
            .onChange(of: clipImport.lastAddedClipID) { _, id in
                guard let id else { return }
                highlightedClipID = id
                revealRequest = UUID()
            }
            .onChange(of: session.canChangeClips) { _, ready in
                if ready { clipImport.resumeAutoAppend() }
            }
            .alert("Clips are still being added", isPresented: $showingUnfinishedImportAlert) {
                Button("Wait", role: .cancel) { pendingClose = nil }
                Button("Cancel Unfinished Clips", role: .destructive) { cancelUnfinishedAndClose() }
            } message: {
                Text("Wait for the selected clips to finish, or cancel them. Clips already added stay in the project.")
            }
            .sheet(item: $renamingClip) { clip in
                ClipRenameView(session: session, clipID: clip.id)
            }
            .interactiveDismissDisabled(
                clipImport.hasUnfinishedImports || session.isChangingClips || movingClipID != nil)
    }

    private var navigation: some View {
        NavigationStack {
            clipList
                .navigationTitle("Clips")
                .navigationBarTitleDisplayMode(.inline)
                .themedSurface()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { requestClose() }
                    }
                }
                .fullScreenCover(item: $clipImport.photoPicker) { request in
                    // PHPicker is built for full-screen presentation on iPhone;
                    // presenting it inside a nested sheet proved unreliable on device.
                    PhotosVideoPicker(selectionLimit: request.selectionLimit) { picks in
                        clipImport.receivePhotos(picks, request: request)
                    }
                }
                .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.movie],
                              allowsMultipleSelection: true) { result in
                    guard let fileSelectionID else { return }
                    self.fileSelectionID = nil
                    clipImport.receiveFiles(result, selectionID: fileSelectionID)
                }
        }
    }

    private var clipList: some View {
        ScrollViewReader { scroll in
            List {
                Section {
                    if let document = session.document {
                        let clips = document.orderedClips
                        ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                            clipRow(clip, index: index, clips: clips, document: document)
                                .id(clip.id)
                        }
                    }
                    AddClipsRows(session: session, model: clipImport,
                                 onPhotos: { openPhotos() }, onFiles: { openFiles() })
                        .listRowBackground(theme.surfaceColor)
                        .listRowSeparatorTint(theme.borderColor)
                    clipStatus
                } header: {
                    Text("Clips · \(session.document?.clips.count ?? 0)")
                } footer: {
                    clipsFooter
                }
            }
            .alert("Remove clip?", isPresented: removalBinding, presenting: removingClip) { clip in
                Button("Remove clip", role: .destructive) { remove(clip) }
                Button("Cancel", role: .cancel) { removingClip = nil }
            } message: { Text(removalMessage($0)) }
            .task(id: revealRequest) {
                await Task.yield()
                guard !Task.isCancelled, let highlightedClipID else { return }
                scroll.scrollTo(highlightedClipID, anchor: .center)
            }
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { removingClip != nil }, set: { if !$0 { removingClip = nil } })
    }

    @ViewBuilder private var clipStatus: some View {
        if !session.canChangeClips && !session.isChangingClips {
            Text("Finish or cancel transcription before changing clips.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if let error {
            Text(error).font(.footnote).foregroundStyle(.orange)
        }
        if let saveError = session.saveError {
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn’t save changes", systemImage: "exclamationmark.circle")
                Text(saveError).font(.footnote).foregroundStyle(.secondary)
                Button("Try again") { Task { await session.retrySave() } }.disabled(session.isSaving)
            }
        }
    }

    @ViewBuilder private var clipsFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if clipImport.sourceOrder.isEmpty {
                Text("Tap a clip to jump to it. Use the ellipsis for move, rename and removal. Keep at least one clip.")
            } else {
                if clipImport.hasUnfinishedImports {
                    Text("New clips are saved as soon as they finish. Tap Done to close; you’ll be asked to wait or cancel unfinished clips.")
                }
                if clipImport.pendingFailureCount > 0 {
                    Text("Retry or remove the clips that couldn’t be added. Unfinished clips are discarded when you close.")
                }
                if !clipImport.hasUnfinishedImports && clipImport.pendingFailureCount == 0 {
                    Text("Clips are added to the end as they finish. Use the ellipsis or swipe a clip for more actions.")
                }
            }
            if let count = session.document?.clips.count, count >= ProjectLimits.maximumClips {
                Text("A project can include up to \(ProjectLimits.maximumClips) clips.")
            }
        }
        .font(.footnote)
    }

    private func beginAddSelection() -> Bool {
        guard session.canChangeClips else { return false }
        let remaining = max(0, ProjectLimits.maximumClips - (session.document?.clips.count ?? 0))
        // Pending failures keep their reserved slots until they are removed.
        guard remaining > clipImport.sourceOrder.count else {
            error = "A project can include up to \(ProjectLimits.maximumClips) clips."
            return false
        }
        error = nil
        clipImport.prepareSelection(session: session, remainingCapacity: remaining)
        return true
    }

    private func openPhotos() {
        guard beginAddSelection() else { return }
        clipImport.openPhotos()
    }

    private func openFiles() {
        guard beginAddSelection() else { return }
        fileSelectionID = clipImport.selectionID
        pickingFiles = true
    }

    private func requestClose(selecting clipID: UUID? = nil) {
        guard !session.isChangingClips, movingClipID == nil else { return }
        if clipImport.hasUnfinishedImports {
            pendingClose = clipID.map(CloseAction.select) ?? .dismiss
            showingUnfinishedImportAlert = true
        } else {
            finishClose(selecting: clipID)
        }
    }

    private func finishClose(selecting clipID: UUID?) {
        if let clipID { session.seekToClip(clipID) }
        dismiss()
    }

    private func cancelUnfinishedAndClose() {
        let action = pendingClose
        pendingClose = nil
        clipImport.endSelection()
        switch action {
        case .some(.select(let id)): finishClose(selecting: id)
        case .some(.dismiss), .none: finishClose(selecting: nil)
        }
    }

    private func clipRow(_ clip: ProjectClip, index: Int, clips: [ProjectClip],
                         document: ProjectDocument) -> some View {
        let output = OutputTimeline(document).outputInterval(clip.timelineInterval)
        let canEdit = session.canChangeClips && !clipImport.adding &&
            movingClipID == nil && !session.isChangingClips
        return HStack(spacing: 4) {
            Button { requestClose(selecting: clip.id) } label: {
                clipLabel(clip, index: index, document: document, output: output)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Clip \(index + 1), \(document.clipName(clip))")
            .accessibilityValue(output == nil ? "Trimmed out" : EditorTime.display(clip.timelineInterval.durationTime))
            .accessibilityHint(output == nil
                ? "Select to restore footage using the timeline trim handles"
                : "Jumps to this clip in the editor")
            .accessibilityAddTraits(clip.id == highlightedClipID ? .isSelected : [])

            Menu {
                clipActions(clip, index: index, clips: clips, document: document, canEdit: canEdit)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Actions for \(document.clipName(clip))")
        }
        .listRowBackground(clip.id == highlightedClipID ? theme.accentColor.opacity(0.1) : theme.surfaceColor)
        .listRowSeparatorTint(theme.borderColor)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Rename", systemImage: "pencil") {
                if canEdit { renamingClip = clip }
            }
            .disabled(!canEdit)
            Button("Remove", systemImage: "trash", role: .destructive) {
                if canEdit, document.clips.count > 1 { removingClip = clip }
            }
            .disabled(document.clips.count <= 1 || !canEdit)
        }
        .contextMenu {
            clipActions(clip, index: index, clips: clips, document: document, canEdit: canEdit)
        }
        .accessibilityActions {
            if canEdit {
                if index > 0 { Button("Move earlier") { move(clip, offset: -1) } }
                if index + 1 < clips.count { Button("Move later") { move(clip, offset: 1) } }
                Button("Rename clip") { renamingClip = clip }
                if document.clips.count > 1 { Button("Remove clip") { removingClip = clip } }
            }
        }
    }

    @ViewBuilder private func clipActions(_ clip: ProjectClip, index: Int, clips: [ProjectClip],
                                          document: ProjectDocument, canEdit: Bool) -> some View {
        Button("Move earlier", systemImage: "arrow.up") { move(clip, offset: -1) }
            .disabled(index == 0 || !canEdit)
        Button("Move later", systemImage: "arrow.down") { move(clip, offset: 1) }
            .disabled(index + 1 >= clips.count || !canEdit)
        Divider()
        Button("Rename clip", systemImage: "pencil") { renamingClip = clip }
            .disabled(!canEdit)
        Button("Remove clip", systemImage: "trash", role: .destructive) { removingClip = clip }
            .disabled(document.clips.count <= 1 || !canEdit)
    }

    private func move(_ clip: ProjectClip, offset: Int) {
        guard session.canChangeClips, !clipImport.adding, movingClipID == nil,
              !session.isChangingClips, let document = session.document else { return }
        let clips = document.orderedClips
        guard let index = clips.firstIndex(where: { $0.id == clip.id }),
              clips.indices.contains(index + offset) else { return }
        var ids = clips.map(\.id)
        ids.swapAt(index, index + offset)
        error = nil
        movingClipID = clip.id
        Task {
            defer { movingClipID = nil }
            do {
                try await session.reorderClips(ids, replacing: ClipGraphState(document))
            } catch is CancellationError {
                error = "Reordering cancelled. Your video is unchanged."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func remove(_ clip: ProjectClip) {
        removingClip = nil; error = nil
        guard !clipImport.adding, movingClipID == nil, !session.isChangingClips else {
            error = "Wait for the clips to finish adding, then remove this clip."
            return
        }
        Task {
            do {
                try await session.removeClip(clip.id)
                if highlightedClipID == clip.id { highlightedClipID = session.currentClip?.id }
                revealRequest = UUID()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func removalMessage(_ clip: ProjectClip) -> String {
        let name = session.document?.clipName(clip) ?? "this clip"
        var message = "Remove “\(name)” and its captions? Original media stays in project storage for Undo. Completed exports are kept."
        if let trim = session.document?.mediaEdits?.trim,
           trim.start >= clip.timelineInterval.start, trim.end <= clip.timelineInterval.end {
            message += " The remaining clips will be shown in full."
        }
        return message
    }

    private func clipLabel(_ clip: ProjectClip, index: Int, document: ProjectDocument,
                           output: MediaInterval?) -> some View {
        HStack(spacing: 12) {
            ClipThumbnail(projectID: document.id, clip: clip,
                source: document.assets.first { $0.id == clip.sourceAssetID })
            VStack(alignment: .leading, spacing: 5) {
                Text("Clip \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(document.clipName(clip)).font(.subheadline).foregroundStyle(.primary)
                    .lineLimit(2).truncationMode(.middle)
                Text(EditorTime.display(clip.timelineInterval.durationTime) + " · " +
                    (output.map { "In video " + EditorTime.display($0.start) } ?? "Trimmed out"))
                    .font(.caption).foregroundStyle(.secondary)
                if session.originalAvailable[clip.sourceAssetID] == false {
                    Label("Original unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
    }
}
