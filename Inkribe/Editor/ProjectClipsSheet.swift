import AppFoundation
import SwiftUI

/// Clip selection and management share one sheet and one app-owned session.
/// Native dragging edits a local order; Save publishes one expected-state change.
struct ProjectClipsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    let clipImport: AddClipsModel
    let onSelect: (UUID) -> Void
    let onOpenCaptions: () -> Void
    @State private var renamingClip: ProjectClip?
    @State private var addingClips = false
    @State private var removingClip: ProjectClip?
    @State private var highlightedClipID: UUID?
    @State private var revealRequest = UUID()
    @State private var error: String?
    @State private var orderBase: ClipGraphState?
    @State private var orderIDs: [UUID] = []
    @State private var savingOrder = false
    @State private var addedClipIDs: Set<UUID> = []
    private var isReordering: Bool { orderBase != nil }
    private var canSaveOrder: Bool {
        guard let orderBase else { return false }
        let originalIDs = orderBase.clips.sorted { $0.timelineInterval.start < $1.timelineInterval.start }.map(\.id)
        return !savingOrder && session.canChangeClips && orderIDs != originalIDs
    }

    init(session: EditorSession, clipImport: AddClipsModel, initialClipID: UUID?, onOpenCaptions: @escaping () -> Void,
         onSelect: @escaping (UUID) -> Void) {
        self.session = session; self.onSelect = onSelect; self.onOpenCaptions = onOpenCaptions
        self.clipImport = clipImport
        _highlightedClipID = State(initialValue: initialClipID)
    }

    var body: some View {
        navigation
            .alert("Remove clip?", isPresented: Binding(
                get: { removingClip != nil }, set: { if !$0 { removingClip = nil } }), presenting: removingClip) { clip in
                Button("Remove clip", role: .destructive) { remove(clip) }
                Button("Cancel", role: .cancel) { removingClip = nil }
            } message: { Text(removalMessage($0)) }
            .sheet(item: $renamingClip) { clip in
                ClipRenameView(session: session, clipID: clip.id)
            }
            .interactiveDismissDisabled(savingOrder || session.isChangingClips)
            .onChange(of: addingClips) { _, adding in
                if !adding { clipImport.endSelection(); revealRequest = UUID() }
            }
            .onChange(of: session.document?.contentRevision) { _, _ in
                guard !savingOrder, let orderBase, let document = session.document,
                      ClipGraphState(document) != orderBase else { return }
                cancelReordering()
                error = "The project changed. Start reordering again."
            }
    }

    private var navigation: some View {
        NavigationStack {
            clipList
                .navigationTitle(isReordering ? "Reorder clips" : "Clips")
                .navigationBarTitleDisplayMode(.inline)
                .themedSurface()
                .toolbar { clipToolbar }
                .navigationDestination(isPresented: $addingClips) {
                    AddClipsSheet(session: session, model: clipImport, selectionID: clipImport.selectionID,
                                  onCancel: { closeAddClips() }) { ids in
                        error = nil; highlightedClipID = ids.first
                        addedClipIDs.formUnion(ids)
                        if let first = ids.first { session.seekToClip(first) }
                        closeAddClips()
                    }
                }
        }
    }

    private var clipList: some View {
        ScrollViewReader { scroll in
            List {
                controls
                addedClipsStatus
                if let document = session.document {
                    let clips = displayedClips(in: document)
                    Section {
                        ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                            clipRow(clip, index: index, document: document)
                                .id(clip.id)
                                .moveDisabled(!isReordering || !session.canChangeClips || savingOrder)
                        }
                        .onMove(perform: moveClips)
                    } footer: {
                        if isReordering {
                            Text("Save applies this order. Cancel keeps the current video.")
                        } else {
                            Text("Tap a clip to jump to it. Swipe or touch and hold for rename and removal. Keep at least one clip.")
                        }
                    }
                }
                if let error = session.saveError {
                    Section {
                        Label("Couldn’t save changes", systemImage: "exclamationmark.circle")
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { Task { await session.retrySave() } }.disabled(session.isSaving)
                    }
                }
            }
            .environment(\.editMode, .constant(isReordering ? .active : .inactive))
            .disabled(session.isChangingClips || savingOrder)
            .task(id: revealRequest) {
                await Task.yield()
                guard !Task.isCancelled, let highlightedClipID, !isReordering else { return }
                scroll.scrollTo(highlightedClipID, anchor: .center)
            }
        }
    }

    private var controls: some View {
        Section {
            if !isReordering {
                Button("Add clips", systemImage: "plus") { clipImport.beginSelection(); addingClips = true }
                    .disabled(!session.canChangeClips)
            } else {
                Text("Drag the handles to change playback order. Captions and settings move with their clips.")
                    .font(.footnote).foregroundStyle(.secondary)
                if session.document?.mediaEdits?.trim != nil {
                    Text("The trim keeps its current start and end times; the footage inside may change.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !session.canChangeClips && !session.isChangingClips {
                Text("Finish or cancel transcription before changing clips.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if session.isChangingClips || savingOrder { ProgressView("Saving clip changes…") }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder private var addedClipsStatus: some View {
        if !isReordering, let document = session.document {
            let added = document.clips.filter { addedClipIDs.contains($0.id) }
            if !added.isEmpty {
                Section {
                    Label(added.count == 1 ? "1 clip added" : "\(added.count) clips added",
                          systemImage: "checkmark.circle")
                    if (document.recognition == nil || document.recognition?.isIncomplete == true),
                       added.contains(where: { clip in
                           document.assets.contains { $0.id == clip.sourceAssetID && $0.metadata.audioTrackCount > 0 }
                       }) {
                        Button("Open Captions", systemImage: "captions.bubble", action: onOpenCaptions)
                    }
                } footer: {
                    Text("Clips are saved. Open Captions when you’re ready to generate or edit captions.")
                }
            }
        }
    }

    @ToolbarContentBuilder private var clipToolbar: some ToolbarContent {
        if isReordering {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancelReordering).disabled(savingOrder)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: saveOrder).disabled(!canSaveOrder)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button("Reorder", action: beginReordering)
                    .disabled(!session.canChangeClips || (session.document?.clips.count ?? 0) < 2)
            }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private func closeAddClips() {
        clipImport.endSelection()
        addingClips = false
    }

    private func displayedClips(in document: ProjectDocument) -> [ProjectClip] {
        guard isReordering else { return document.orderedClips }
        let clips = Dictionary(uniqueKeysWithValues: document.clips.map { ($0.id, $0) })
        return orderIDs.compactMap { clips[$0] }
    }
    private func beginReordering() {
        guard session.canChangeClips, let document = session.document, document.clips.count > 1 else { return }
        session.pause(); session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
        error = nil; orderIDs = document.orderedClips.map(\.id); orderBase = ClipGraphState(document)
    }
    private func cancelReordering() {
        guard !savingOrder else { return }
        orderBase = nil; orderIDs = []; revealRequest = UUID()
    }
    private func moveClips(from source: IndexSet, to destination: Int) {
        guard isReordering, !savingOrder, session.canChangeClips,
              source.allSatisfy({ orderIDs.indices.contains($0) }),
              (0...orderIDs.count).contains(destination) else { return }
        orderIDs.move(fromOffsets: source, toOffset: destination)
    }
    private func saveOrder() {
        guard canSaveOrder, let expected = orderBase else { return }
        let ids = orderIDs
        savingOrder = true; error = nil
        Task {
            defer { savingOrder = false }
            do {
                try await session.reorderClips(ids, replacing: expected)
                orderBase = nil; orderIDs = []; revealRequest = UUID()
            } catch ClipGraphError.stale {
                orderBase = nil; orderIDs = []; revealRequest = UUID()
                error = "The project changed. Start reordering again."
            } catch is CancellationError {
                error = "Reordering cancelled. Your video is unchanged."
            } catch { self.error = error.localizedDescription }
        }
    }
    private func remove(_ clip: ProjectClip) {
        removingClip = nil; error = nil
        Task {
            do {
                try await session.removeClip(clip.id)
                if highlightedClipID == clip.id { highlightedClipID = session.currentClip?.id }
                revealRequest = UUID()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func clipRow(_ clip: ProjectClip, index: Int, document: ProjectDocument) -> some View {
        let output = OutputTimeline(document).outputInterval(clip.timelineInterval)
        return Group {
            if !isReordering {
                Button { onSelect(clip.id) } label: { clipLabel(clip, index: index, document: document, output: output) }
                    .buttonStyle(.plain)
            } else {
                clipLabel(clip, index: index, document: document, output: output)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Clip \(index + 1), \(document.clipName(clip))")
        .accessibilityValue(!isReordering && output == nil ? "Trimmed out" : EditorTime.display(clip.timelineInterval.durationTime))
        .accessibilityHint(isReordering ? "Use reorder actions to move this clip" : output == nil ? "Select to restore footage using the timeline trim handles" : "Jumps to this clip in the editor")
        .accessibilityAddTraits(clip.id == highlightedClipID ? .isSelected : [])
        .listRowBackground(clip.id == highlightedClipID ? theme.accentColor.opacity(0.1) : theme.surfaceColor)
        .listRowSeparatorTint(theme.borderColor)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isReordering {
                Button("Rename", systemImage: "pencil") { renamingClip = clip }
                Button("Remove", systemImage: "trash", role: .destructive) { removingClip = clip }
                    .disabled(document.clips.count <= 1 || !session.canChangeClips)
            }
        }
        .contextMenu {
            if !isReordering {
                Button("Rename clip", systemImage: "pencil") { renamingClip = clip }
                Button("Remove clip", systemImage: "trash", role: .destructive) { removingClip = clip }
                    .disabled(document.clips.count <= 1 || !session.canChangeClips)
            }
        }
        .accessibilityActions {
            if isReordering && session.canChangeClips && !savingOrder {
                if index > 0 { Button("Move earlier") { moveClips(from: IndexSet(integer: index), to: index - 1) } }
                if index + 1 < orderIDs.count { Button("Move later") { moveClips(from: IndexSet(integer: index), to: index + 2) } }
            } else if !isReordering {
                Button("Rename clip") { renamingClip = clip }
                if document.clips.count > 1 && session.canChangeClips {
                    Button("Remove clip") { removingClip = clip }
                }
            }
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

    private func clipLabel(_ clip: ProjectClip, index: Int, document: ProjectDocument, output: MediaInterval?) -> some View {
        HStack(spacing: 12) {
            ClipThumbnail(projectID: document.id, clip: clip,
                source: document.assets.first { $0.id == clip.sourceAssetID })
            VStack(alignment: .leading, spacing: 5) {
                Text("Clip \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(document.clipName(clip)).font(.subheadline).foregroundStyle(.primary)
                    .lineLimit(2).truncationMode(.middle)
                Text(isReordering ? EditorTime.display(clip.timelineInterval.durationTime) :
                    EditorTime.display(clip.timelineInterval.durationTime) + " · " +
                    (output.map { "In video " + EditorTime.display($0.start) } ?? "Trimmed out"))
                    .font(.caption).foregroundStyle(.secondary)
                if session.originalAvailable[clip.sourceAssetID] == false {
                    Label("Original unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isReordering {
                Image(systemName: clip.id == highlightedClipID ? "checkmark" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
    }
}
