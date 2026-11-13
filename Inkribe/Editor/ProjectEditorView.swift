import CoreMedia
import JobQueue
import SwiftUI
import AppFoundation
import UniformTypeIdentifiers

enum EditorField: Hashable { case title, caption(UUID), word(UUID), timing(UUID, Bool), trimStart, trimEnd }

private struct MusicSheetRoute: Identifiable {
    let id = UUID()
    let draft: MusicDraft
    let input: ImportInput?
}

struct ProjectEditorView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.queueProjectNavigation) private var openQueueProject
    let projectID: UUID
    private let sessions: EditorSessions
    private let renameOnOpen: Bool
    @State private var session: EditorSession
    @State private var presentationID = UUID()
    @State private var showClips = false
    @State private var clipImport = AddClipsModel()
    @State private var clipsInitialSelection: UUID?
    @State private var addingCaption: ManualCaptionDraft?
    @State private var relinkAsset: UUID?
    @State private var isRelinking = false
    @State private var showDeleteConfirmation = false
    @State private var activeToolSheet: EditorTool?
    @State private var captionEditorCueID: UUID?
    @State private var editingCaptionFromTranscript = false
    @State private var preparationAttempt = UUID()
    @State private var openingTask: Task<Void, Never>?
    @State private var isOpening = true
    @State private var isLeaving = false
    @State private var showStyleSheet = false
    @State private var musicSheet: MusicSheetRoute?
    @State private var choosingMusic = false
    @State private var captionRenderError: String?
    @State private var showExport = false
    @State private var preparingTranscription = false
    @State private var confirmingReTranscription = false
    @State private var showProjectInfo = false
    @State private var didRequestInitialRename = false
    @State private var showingRename = false
    @State private var renamedTitle = ""
    @State private var pendingQueueRoute: QueueProjectRoute?
    @State private var queueOwnerIsDismissing = false
    @State private var focusedExportID: UUID?
    @FocusState private var focused: EditorField?

    init(session: EditorSession, sessions: EditorSessions, renameOnOpen: Bool = false,
         queueRoute: QueueProjectRoute? = nil) {
        self.projectID = session.projectID
        self.sessions = sessions
        self.renameOnOpen = renameOnOpen
        _session = State(initialValue: session)
        _pendingQueueRoute = State(initialValue: queueRoute)
    }

    // Keep layout, toolbar and presentation as separate opaque expressions.
    // A single modifier chain exceeded Swift's type-checking budget in CI.
    var body: some View {
        editorPresentation
        .onAppear {
            isLeaving = false
            sessions.attach(session, owner: presentationID)
            finishQueueNavigation()
        }
        .onChange(of: session.clipEditGeneration) { _, _ in
            Task { await model.refreshAfterClipEdit(projectID) }
        }
        .onChange(of: session.isLoading) { _, _ in finishOpeningIfReady() }
        .onChange(of: session.isPreparingPreview) { _, _ in finishOpeningIfReady() }
        .onChange(of: model.transcription.resultGeneration) { _, _ in Task { await session.refreshSaved() } }
        .onChange(of: focused) { _, value in
            if case .word(let id)? = value { session.selectWord(id); session.beginTyping() }
            else { session.endTyping(); if value != nil { session.beginTyping() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.pause(); Task { await session.flush() } }
        }
        .onDisappear {
            guard !hasPresentedSheet else { return }
            isLeaving = true
            openingTask?.cancel()
            session.cancelPreparation()
            sessions.detach(session, owner: presentationID)
            Task { await session.flush(); await model.refreshLibrary() }
        }
        .environment(\.queueProjectNavigation, QueueProjectNavigation(open: handleQueueProject))
    }

    private var editorPresentation: some View {
        editorDocumentPresentation
            .task(id: preparationAttempt) { await prepareEditor() }
            .sheet(item: $activeToolSheet, onDismiss: finishActiveToolEditing) { tool in toolSheet(tool) }
            .background {
                NativeVideoPlayer(isPresented: $session.workspace.expandedPreview, player: session.player,
                    session: session, snapshot: session.snapshot, time: session.time,
                    mediaGeneration: session.previewGeneration,
                    onError: { session.commandError = $0 })
                    .frame(width: 0, height: 0)
            }
    }

    private var editorDocumentPresentation: some View {
        editorStylePresentation
            .sheet(isPresented: $showExport, onDismiss: {
                finishToolEditing()
                queueOwnerDidDismiss()
            }) {
                ExportView(session: session, focusedJobID: focusedExportID)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showProjectInfo) { projectInfoSheet }
            .sheet(item: Binding(get: { activeToolSheet == nil ? addingCaption : nil },
                set: { if activeToolSheet == nil { addingCaption = $0 } }), onDismiss: finishToolEditing) { draft in
                    ManualCaptionSheet(session: session, draft: draft, previewIsActive: manualPreviewBinding)
            }
            .sheet(isPresented: $showClips, onDismiss: {
                clipImport.endSelection()
                finishToolEditing()
            }) {
                ProjectClipsSheet(session: session, clipImport: clipImport,
                                  initialClipID: clipsInitialSelection)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }

    private var editorStylePresentation: some View {
        editorMusicPresentation
            .sheet(isPresented: $showStyleSheet, onDismiss: {
                finishToolEditing()
                Task { await session.refreshSaved() }
            }) { styleSheet }
            .sheet(item: Binding(get: { showStyleSheet || activeToolSheet != nil ? nil : session.proUpsell },
                set: { if !showStyleSheet && activeToolSheet == nil { session.proUpsell = $0 } })) { ProUpsell(feature: $0) }
    }

    private var editorMusicPresentation: some View {
        editorDialogs
            .sheet(item: musicSheetBinding, onDismiss: {
                finishToolEditing()
                Task { await model.refreshLibrary() }
            }) { route in MusicSheet(draft: route.draft, initialInput: route.input) }
            .fileImporter(isPresented: $choosingMusic, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url):
                    musicSheet = MusicSheetRoute(draft: MusicDraft(session: session),
                        input: ImportInput(localURL: url, origin: .files))
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { session.commandError = error.localizedDescription }
                }
            }
    }

    /// Only dismissing/replacing Music releases its draft. A child Files picker
    /// may cover the sheet without ending its editing or staging lifetime.
    private var musicSheetBinding: Binding<MusicSheetRoute?> {
        Binding(get: { musicSheet }, set: { next in
            if musicSheet?.id != next?.id { musicSheet?.draft.close() }
            musicSheet = next
        })
    }

    private var editorRenamePresentation: some View {
        editorNavigation
        .alert("Rename project", isPresented: $showingRename) {
            TextField("Project title", text: $renamedTitle)
            Button("Save") {
                session.setTitle(renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines))
                Task { await session.flush() }
            }
            .disabled(renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                renamedTitle.count > 256 || !session.isReadyToEdit)
            Button("Cancel", role: .cancel) { }
        } message: { Text("Enter a name up to 256 characters.") }
    }

    private var editorDialogs: some View {
        editorRenamePresentation
        .alert("Move this project to Trash?", isPresented: $showDeleteConfirmation) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    await session.flush()
                    guard !session.hasPendingChanges, !model.transcription.isActive(projectID) else { return }
                    await model.trash(projectID)
                    if model.alertMessage == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Original files are preserved in Trash until you empty it.") }
        .alert("Project", isPresented: Binding(
            get: { canPresentProjectError && model.alertMessage != nil },
            set: { if !$0 && canPresentProjectError { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
    }

    private var editorNavigation: some View {
        editorWorkspace
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle("")
        .themedSurface()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
    }

    private var editorWorkspace: some View {
        editorCanvas
            .safeAreaInset(edge: .bottom, spacing: 0) { editorToolBar }
            .disabled(isOpening || preparingTranscription || session.isChangingClips)
            .accessibilityHidden(isOpening)
            .modifier(EditorPreparationPresentation(isPreparing: isOpening, cancel: cancelOpening))
    }

    private var editorCanvas: some View {
        GeometryReader { geometry in
            if let document = session.document {
                VStack(spacing: 8) {
                    preview(document, height: previewHeight(document, in: geometry.size))
                        .padding(.horizontal, 12)
                    EditorPlaybackControls(session: session, showsTimeline: false, showsHistory: false,
                        showsEditorTransport: true,
                        onInteraction: { focused = nil },
                        onExpand: openFullscreenPreview)
                        .padding(.horizontal, 12)
                    timelineWorkspace(document)
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let error = session.loadError {
                VStack(spacing: 12) {
                    ContentUnavailableView("Cannot open project", systemImage: "exclamationmark.triangle",
                        description: Text(error))
                    Button("Retry", action: retryOpening).buttonStyle(.borderedProminent)
                    Button("Back", action: cancelOpening).frame(minHeight: 44)
                }.padding(16)
            } else {
                // Real editor geometry is filled when the document arrives.
                // Loading indicators are temporarily hidden; native Back remains available.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func timelineWorkspace(_ document: ProjectDocument) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                ProjectTimelineView(session: session,
                    isActive: scenePhase == .active && !hasPresentedSheet && !isOpening && !isLeaving && !session.isChangingClips,
                    onInteraction: finishToolInteraction,
                    onCaption: timelineCaptionTapped,
                    onClip: { session.selectTimelineClip($0) },
                    onMusic: openMusic, onCaptions: { switchTool(.captions) })
                    .frame(height: CGFloat(TimelineGeometry.trackHeight))
                editorErrors
                    .padding(.horizontal, 12)
                if document.recognition?.isIncomplete == true {
                    Button("Review unfinished captions", systemImage: "exclamationmark.bubble") { switchTool(.captions) }
                        .font(.footnote).frame(minHeight: 44)
                        .padding(.horizontal, 12)
                } else if !document.hasCaptionUnits {
                    Button("Add or generate captions", systemImage: "captions.bubble") { switchTool(.captions) }
                        .font(.footnote).frame(minHeight: 44)
                        .padding(.horizontal, 12)
                }
            }.padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("Project timeline")
    }

    private func selectedTimelineClip(in document: ProjectDocument) -> ProjectClip? {
        document.clips.first { $0.id == session.workspace.timelineClipID } ?? session.currentClip
    }

    private func openClips() {
        finishToolInteraction()
        clipsInitialSelection = session.document.flatMap { selectedTimelineClip(in: $0)?.id }
        showClips = true
    }

    private func openMusic() {
        guard session.isReadyToEdit else { return }
        finishToolInteraction()
        if session.document?.music == nil { choosingMusic = true }
        else { musicSheet = MusicSheetRoute(draft: MusicDraft(session: session), input: nil) }
    }

    private func timelineCaptionTapped(_ id: UUID) {
        if session.workspace.timelineCueID == id, session.selectedCueID == id {
            openCaptionEditor(id)
        } else {
            session.selectCue(id)
        }
    }

    private func prepareEditor() async {
        guard !Task.isCancelled, !isLeaving else { return }
        let task = Task { @MainActor in
            isOpening = true
            await session.open(rebuildPreview: session.previewError != nil)
            guard !Task.isCancelled, !isLeaving else { return }
            finishOpeningIfReady()
        }
        openingTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func finishOpeningIfReady() {
        // Another publication/preview refresh may have superseded this read.
        // Keep the opening overlay until the current generation has settled.
        guard isOpening, !isLeaving, !session.isLoading, !session.isPreparingPreview else { return }
        isOpening = false
        if renameOnOpen, !didRequestInitialRename, session.document != nil {
            didRequestInitialRename = true
            beginRenaming()
        }
        finishQueueNavigation()
    }

    private func handleQueueProject(_ route: QueueProjectRoute) {
        guard pendingQueueRoute == nil, !isLeaving, !model.exports.hasUserDelivery else { return }
        pendingQueueRoute = route
        session.pause()
        focused = nil
        // Close the owning Export or Captions presentation before following a
        // job-detail route. Its actual onDismiss performs the next navigation.
        if showExport { queueOwnerIsDismissing = true; showExport = false }
        else if activeToolSheet != nil { queueOwnerIsDismissing = true; activeToolSheet = nil }
        else { finishQueueNavigation() }
    }

    private func queueOwnerDidDismiss() {
        queueOwnerIsDismissing = false
        finishQueueNavigation()
    }

    private func finishQueueNavigation() {
        guard let route = pendingQueueRoute, !isOpening, !isLeaving,
              !queueOwnerIsDismissing, !hasPresentedSheet, session.document != nil else { return }
        pendingQueueRoute = nil
        if route.projectID != projectID || !model.allProjects.contains(where: { $0.id == projectID }) {
            openQueueProject(route)
        } else if route.job.kind == .transcription {
            switchTool(.captions)
        } else {
            finishToolInteraction()
            focusedExportID = route.job.jobID
            showExport = true
        }
    }

    private func retryOpening() {
        isOpening = true
        preparationAttempt = UUID()
    }

    private func cancelOpening() {
        isLeaving = true
        openingTask?.cancel()
        session.cancelPreparation()
        dismiss()
    }

    private var hasPresentedSheet: Bool {
        showProjectInfo || showingRename || showClips || showExport || showStyleSheet || musicSheet != nil || choosingMusic ||
            activeToolSheet != nil || addingCaption != nil ||
            session.proUpsell != nil || session.workspace.expandedPreview
    }

    @ViewBuilder
    private func toolSheet(_ tool: EditorTool) -> some View {
        if tool == .media {
            MediaSheet(session: session)
        } else {
            toolNavigation(tool)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .sheet(item: $addingCaption, onDismiss: finishToolEditing) { draft in
                    ManualCaptionSheet(session: session, draft: draft, previewIsActive: manualPreviewBinding)
                }
                .sheet(item: Binding(get: { session.proUpsell }, set: { session.proUpsell = $0 })) { ProUpsell(feature: $0) }
                .alert("Project", isPresented: Binding(get: { addingCaption == nil && session.proUpsell == nil && model.alertMessage != nil },
                    set: { if !$0 { model.alertMessage = nil } })) {
                        Button("OK", role: .cancel) { model.alertMessage = nil }
                    } message: { Text(model.alertMessage ?? "") }
                .confirmationDialog("Re-transcribe captions?", isPresented: $confirmingReTranscription,
                    titleVisibility: .visible) {
                    Button("Re-transcribe") { reTranscribe() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(reTranscriptionMessage)
                }
        }
    }

    private func toolNavigation(_ tool: EditorTool) -> some View {
        NavigationStack {
            toolPage(tool)
                .navigationDestination(isPresented: $editingCaptionFromTranscript) {
                    toolPage(.captionEditor)
                }
        }
        .onChange(of: editingCaptionFromTranscript) { wasEditing, isEditing in
            guard wasEditing, !isEditing, activeToolSheet == .captions else { return }
            // Native Back/swipe and Done pop to the same transcript, without
            // closing its sheet, seeking or replacing its scroll context.
            finishToolInteraction()
            captionEditorCueID = nil
            Task { await session.flush() }
        }
    }

    private func toolPage(_ tool: EditorTool) -> some View {
        toolPageContent(tool)
            .navigationTitle(tool.title).navigationBarTitleDisplayMode(.inline).themedSurface()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if tool == .captionEditor { closeCaptionEditor() }
                        else { focused = nil; activeToolSheet = nil }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil; session.endTyping(); Task { await session.flush() } }
                }
            }
    }

    @ViewBuilder
    private func toolPageContent(_ tool: EditorTool) -> some View {
        if tool == .captions {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if let document = session.document {
                        captionsPlaybackHeader(document, in: geometry.size)
                    }
                    toolContent(tool)
                }
                .disabled(preparingTranscription)
            }
        } else {
            toolContent(tool)
        }
    }

    private func captionsPlaybackHeader(_ document: ProjectDocument, in size: CGSize) -> some View {
        let width = max(0, size.width - 32)
        let aspect = CGFloat(document.canvas.width) / CGFloat(document.canvas.height)
        let height = max(0, min(width / aspect, min(260, size.height * 0.32)))
        return VStack(spacing: 8) {
            preview(document, height: height, inCaptions: true)
            EditorPlaybackControls(session: session, showsOverview: false, showsTimeline: false,
                onInteraction: { focused = nil })
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    private func toolContent(_ tool: EditorTool) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let document = session.document {
                        editorErrors
                        if tool == .captions, document.recognition?.isIncomplete == true {
                            PartialCaptionStatus(document: document, preparing: preparingTranscription,
                                retry: { retryMissing() }, reset: resetRetryProgress)
                        }
                        activeWorkspace(document, tool: tool)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).padding(.bottom, 20)
            }
            .disabled(preparingTranscription)
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition(id: scrollBinding(for: tool))
            .id(tool)
            .onChange(of: focused) { _, field in
                guard tool != .captions || !editingCaptionFromTranscript else { return }
                if let field { scroll.scrollTo(field, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var editorErrors: some View {
        if hasStatusError { status }
        if let error = session.previewError {
            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            Button("Retry preview") {
                if activeToolSheet != nil { Task { await session.retryPreview() } }
                else { retryOpening() }
            }
        }
        if let error = captionRenderError {
            Label(error, systemImage: "captions.bubble").font(.footnote).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func activeWorkspace(_ document: ProjectDocument, tool: EditorTool) -> some View {
        switch tool {
        case .captions:
            transcriptHeader(document)
            reTranscriptionPanel()
            ManualCaptionConflictReview(session: session)
            if document.hasCaptionUnits {
                if let snapshot = session.snapshot {
                    if snapshot.transcriptItems.isEmpty {
                        Text("No captions are inside the retained range. Adjust trim in Media to restore them.")
                            .foregroundStyle(.secondary)
                        Button("Media tools") { switchTool(.media) }
                    }
                    ForEach(Array(document.orderedClips.enumerated()), id: \.element.id) { index, clip in
                        captionGroup(clip, number: index + 1, snapshot: snapshot, document: document)
                    }
                }
                if document.recognition == nil || document.recognition?.words.isEmpty == true {
                    transcription(document)
                }
            } else { transcription(document) }
        case .style:
            // Style owns its transactional sheet rather than this tool page.
            EmptyView()
        case .captionEditor:
            captionEditorContent
        case .media:
            // Media owns its controls-only transactional Form.
            EmptyView()
        }
    }

    @ViewBuilder
    private var captionEditorContent: some View {
        if let cue = session.selectedCue, cue.id == captionEditorCueID {
            captionTextEditor(cue)
                .id("caption-editor")
            correctionPanel
            Text(editingCaptionFromTranscript ? "Tap Back or Done to return to Captions." :
                "Tap Done to return to the timeline and play back your changes.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ContentUnavailableView("Caption unavailable", systemImage: "captions.bubble",
                description: Text(editingCaptionFromTranscript ?
                    "This caption is no longer visible. Tap Back or Done to return to Captions." :
                    "This caption is no longer visible. Tap Done to return to the timeline."))
        }
    }

    private func captionTextEditor(_ cue: CaptionCue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { captionEditingLabel; Spacer(minLength: 4); captionTimestamp(cue) }
                VStack(alignment: .leading, spacing: 4) { captionEditingLabel; captionTimestamp(cue) }
            }
            .font(.caption)
            TextField("Hidden caption", text: Binding(get: {
                let text = session.snapshot?.text(for: cue) ?? ""
                return session.workspace.captionDraft?.value(for: cue.id, canonical: text) ?? text
            }, set: { value in
                guard session.editCueText(cueID: cue.id, value: value) else { return }
                session.workspace.captionDraft = EditorTextDraft(id: cue.id, text: value,
                    canonical: session.snapshot?.text(for: cue) ?? "")
            }), axis: .vertical)
            .font(.body)
            .focused($focused, equals: .caption(cue.id))
            .id(EditorField.caption(cue.id))
            .accessibilityLabel("Caption text")
            if cue.wordIDs.contains(where: { id in
                guard let word = session.snapshot?.wordsByID[id],
                      !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                return !CaptionMotion.isWordTimed(word)
            }) {
                Label("Phrase timing", systemImage: "text.alignleft")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var captionEditingLabel: some View {
        Label(session.selectedManualCaption == nil ? "Editing caption" : "Manual caption", systemImage: "pencil")
            .foregroundStyle(theme.accentColor)
    }

    private func captionTimestamp(_ cue: CaptionCue) -> some View {
        Text(EditorTime.display(cue.interval.start) + "–" + EditorTime.display(cue.interval.end))
            .monospacedDigit().foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func captionGroup(_ clip: ProjectClip, number: Int, snapshot: CaptionSnapshot, document: ProjectDocument) -> some View {
        if let items = snapshot.transcriptItemsByClip[clip.id], !items.isEmpty {
            if document.clips.count > 1 {
                Button { focused = nil; session.seekToClip(clip.id) } label: {
                    HStack {
                        Label(document.editorClipTitle(clip), systemImage: "film").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(OutputTimeline(document).outputInterval(clip.timelineInterval).map { EditorTime.display($0.start) } ?? "Outside trim")
                            .monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
            ForEach(items) { item in transcriptRow(item).id(item.id) }
        }
    }

    private func scrollBinding(for tool: EditorTool) -> Binding<String?> {
        // Capture the tool identity so a retiring scroll view cannot write its
        // last caption anchor into the newly selected tool's context.
        Binding(get: { session.workspace.anchor(for: tool) },
            set: { session.workspace.setAnchor($0, for: tool) })
    }

    private func switchTool(_ tool: EditorTool) {
        if tool == .style { openStyleSheet(); return }
        finishToolInteraction()
        session.workspace.select(tool)
        activeToolSheet = tool
    }

    private func openCaptionEditor(_ id: UUID) {
        guard session.snapshot?.cues.contains(where: { $0.id == id }) == true else { return }
        finishToolInteraction()
        // A second timeline tap and a selected row's Edit caption action open
        // without seeking again. Row selection itself remains a separate action.
        if session.selectedCueID != id { session.selectCue(id) }
        captionEditorCueID = id
        session.workspace.setAnchor("caption-editor", for: .captionEditor)
        if activeToolSheet == .captions {
            // Push in Captions' existing stack; the list keeps its scroll context.
            editingCaptionFromTranscript = true
        } else {
            session.workspace.select(.captionEditor)
            activeToolSheet = .captionEditor
        }
    }

    private func closeCaptionEditor() {
        focused = nil
        if editingCaptionFromTranscript { editingCaptionFromTranscript = false }
        else { activeToolSheet = nil }
    }

    private func openStyleSheet() {
        finishToolInteraction()
        showStyleSheet = true
    }

    private func openFullscreenPreview() {
        guard !isOpening, session.isReadyToEdit, !session.isPreparingPreview,
              session.player.currentItem != nil else { return }
        focused = nil
        session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
        session.workspace.expandedPreview = true
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(session.undoLabel, systemImage: "arrow.uturn.backward") { finishToolInteraction(); session.undo() }
                .labelStyle(.iconOnly)
                .disabled(isOpening || !session.isReadyToEdit || preparingTranscription || !session.canUndo)
            Button(session.redoLabel, systemImage: "arrow.uturn.forward") { finishToolInteraction(); session.redo() }
                .labelStyle(.iconOnly)
                .disabled(isOpening || !session.isReadyToEdit || preparingTranscription || !session.canRedo)
            editorActions
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { focused = nil; session.endTyping(); Task { await session.flush() } }
                .disabled(preparingTranscription)
        }
    }

    private var editorActions: some View {
        Menu {
            Button("Rename", systemImage: "pencil") { beginRenaming() }
            Button("Duplicate project", systemImage: "plus.square.on.square") {
                duplicateProject(includingCaptions: true)
            }
            Button("Duplicate without Captions", systemImage: "text.bubble") {
                duplicateProject(includingCaptions: false)
            }
            .disabled(session.document?.hasCaptionUnits != true)
            Button("Project info", systemImage: "info.circle") {
                finishToolInteraction()
                showProjectInfo = true
            }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) { showDeleteConfirmation = true }
                .disabled(model.transcription.isActive(projectID))
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Project actions")
        .disabled(isOpening || !session.isReadyToEdit || preparingTranscription)
    }

    private func duplicateProject(includingCaptions: Bool) {
        Task {
            await session.flush()
            guard !session.hasPendingChanges else { return }
            await model.duplicate(projectID, includingCaptions: includingCaptions)
        }
    }

    private func beginRenaming() {
        guard let document = session.document else { return }
        focused = nil
        session.pause()
        session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
        renamedTitle = document.title
        showingRename = true
    }

    private func previewHeight(_ document: ProjectDocument, in size: CGSize) -> CGFloat {
        let width = max(0, size.width - 24)
        let aspect = CGFloat(document.canvas.width) / CGFloat(document.canvas.height)
        // Reserve actual track space before sizing portrait footage.
        // Sheet/keyboard/focus state never enters this geometry calculation.
        let controls: CGFloat = dynamicTypeSize.isAccessibilitySize ? 88 : 44
        let reserved = CGFloat(TimelineGeometry.trackHeight) + 16 + controls + 24
        let available = max(0, size.height - reserved)
        return max(0, min(width / aspect, min(available, min(360, size.height * 0.48))))
    }

    private func preview(_ document: ProjectDocument, height: CGFloat,
                         inCaptions: Bool = false) -> some View {
        EditorPlayerPreview(session: session,
            isActive: previewOwnsPlayer(inCaptions: inCaptions),
            onError: { captionRenderError = $0 })
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func previewOwnsPlayer(inCaptions: Bool) -> Bool {
        guard !isLeaving, !showStyleSheet, musicSheet == nil, !choosingMusic, !showExport, addingCaption == nil,
              !session.workspace.expandedPreview else { return false }
        if inCaptions {
            return activeToolSheet == .captions && !editingCaptionFromTranscript
        }
        return activeToolSheet != .captions && activeToolSheet != .media
    }

    private var editorToolBar: some View {
        HStack(spacing: 0) {
            actionButton("Clips", symbol: "film.stack", selected: showClips, action: openClips)
            ForEach(EditorTool.primaryTools) { tool in
                actionButton(tool.title, symbol: tool.symbol, selected: activeToolSheet == tool || (tool == .style && showStyleSheet)) {
                    switchTool(tool)
                }
            }
            actionButton("Export", symbol: "square.and.arrow.up", selected: showExport) {
                finishToolInteraction()
                focusedExportID = nil
                showExport = true
            }
            .disabled(isOpening || !session.isReadyToEdit || preparingTranscription)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(theme.backgroundColor)
        .overlay(alignment: .top) { Divider() }
        .disabled(!session.isReadyToEdit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor actions")
    }

    private func actionButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 4)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(selected ? theme.accentColor : theme.secondaryForegroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func finishToolInteraction() {
        focused = nil
        session.pause(); session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
    }

    private var canPresentProjectError: Bool {
        !hasPresentedSheet && !isOpening && !showDeleteConfirmation
    }

    private var hasStatusError: Bool {
        session.saveError != nil || session.loadError != nil || session.commandError != nil
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = session.saveError {
                Label("Couldn’t save changes", systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("Try again") { Task { await session.retrySave() } }
                    .disabled(session.isSaving)
            } else if let error = session.loadError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("Try again", action: retryOpening)
            }
            if let error = session.commandError, session.saveError == nil {
                HStack(alignment: .top) {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark.circle") { session.commandError = nil }.labelStyle(.iconOnly)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ item: CaptionTranscriptItem) -> some View {
        switch item {
        case .cue(let cue):
            CaptionTranscriptRow(session: session, cue: cue,
                active: session.presentation?.cueID == cue.id,
                openEditor: { openCaptionEditor(cue.id) })
        case .gap(let gap):
            CaptionGapRow(gap: gap,
                busy: model.transcription.isActive(projectID) || preparingTranscription || model.transcription.isAuthorizing,
                seek: { focused = nil; session.seek(to: gap.interval.start) },
                retry: { retryMissing(windowIndices: [gap.id]) },
                add: { beginAddingCaption(gap: gap) })
        }
    }

    private func resetRetryProgress() {
        focused = nil
        session.pause()
        preparingTranscription = true
        Task {
            defer { preparingTranscription = false }
            do {
                let document = try await session.savedDocument()
                try await model.transcription.discardSavedProgress(projectID: projectID, expectedRevision: document.contentRevision)
            } catch { model.alertMessage = error.localizedDescription }
            await session.refreshSaved()
        }
    }

    private func transcription(_ document: ProjectDocument) -> some View {
        TranscriptionView(document: document, prepareForTranscription: {
            focused = nil
            session.pause()
            session.endTyping()
            session.endMediaEditing()
            return try await session.savedDocument()
        }, onRequestFinished: session.refreshSaved, isPreparingRequest: $preparingTranscription)
    }

    private var correctionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cue = session.selectedCue, let snapshot = session.snapshot {
                if session.selectedManualCaption == nil {
                    nativeWordCorrection(cue, snapshot: snapshot)
                }
                DisclosureGroup("Caption timing") {
                    TimingFields(interval: session.timingCue?.interval ?? cue.interval, identity: cue.id,
                        detail: timingExplanation + (session.selectedManualCaption == nil ? " Applying caption timing scales its word intervals as a manual correction." : " This is a manually timed phrase."),
                        apply: session.retimeCue, workspace: $session.workspace, focused: $focused)
                }
                if session.selectedManualCaption == nil, let word = session.timingWord {
                    DisclosureGroup("Selected word timing") {
                        TimingFields(interval: word.projectInterval, identity: word.id,
                            detail: timingExplanation + " Extending a word expands the caption if needed.",
                            apply: session.retimeWord, workspace: $session.workspace, focused: $focused)
                    }
                }
                if let manual = session.selectedManualCaption {
                    Button("Delete manual caption", role: .destructive) {
                        focused = nil
                        session.deleteManualCaption(manual.id)
                        if session.document?.manualCaptions?.contains(where: { $0.id == manual.id }) != true {
                            closeCaptionEditor()
                        }
                    }
                }
            }
        }
    }

    private func nativeWordCorrection(_ cue: CaptionCue, snapshot: CaptionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Words & phrases").font(.headline)
            Text("Select a word to correct it. Clear its text to hide it; timing stays unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { words in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(cue.wordIDs, id: \.self) { id in
                            if let word = snapshot.wordsByID[id] {
                                Button {
                                    focused = nil
                                    session.selectWord(id)
                                } label: {
                                    Text(wordLabel(word))
                                        .lineLimit(1)
                                        .frame(maxWidth: 160)
                                        .padding(.horizontal, 12)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .background(session.selectedWordID == id ? theme.accentColor.opacity(0.25) : theme.surfaceColor,
                                            in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .id(id)
                                .accessibilityLabel("Select word: " + wordLabel(word))
                                .accessibilityValue(EditorTime.display(word.projectInterval.start))
                                .accessibilityAddTraits(session.selectedWordID == id ? .isSelected : [])
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: session.selectedWordID) { _, id in
                    if let id { words.scrollTo(id, anchor: .center) }
                }
            }
            if let id = session.selectedWordID, cue.wordIDs.contains(id) {
                if let word = session.selectedWord, !CaptionMotion.isWordTimed(word) {
                    Text(word.timingProvenance == "whisper-segment" ?
                        "This phrase uses Whisper's segment timing. Individual word timing was unavailable; correcting the phrase keeps its original interval." :
                        "This text shares one timing interval. Word-by-word effects stay off for this phrase; correcting the text keeps its timing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Hidden word", text: Binding(
                    get: {
                        let canonical = session.snapshot?.wordsByID[id]?.text ?? ""
                        return session.workspace.wordDraft?.value(for: id, canonical: canonical)
                            ?? canonical.trimmingCharacters(in: .whitespacesAndNewlines)
                    },
                    set: { value in
                        guard session.editText(wordID: id, value: value) else { return }
                        session.workspace.wordDraft = EditorTextDraft(id: id, text: value,
                            canonical: session.snapshot?.wordsByID[id]?.text ?? "")
                    }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .word(id))
                    .id(EditorField.word(id))
                    .accessibilityLabel("Selected word or corrected phrase")
            }
            ViewThatFits(in: .horizontal) {
                HStack { splitButton; mergeButton }
                VStack(alignment: .leading) { splitButton; mergeButton }
            }
        }
    }

    private func wordLabel(_ word: CaptionUnit) -> String {
        let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Hidden word" : text
    }

    private var timingExplanation: String {
        session.document?.mediaEdits?.trim == nil ? "Seconds on the project timeline." :
            "Seconds on the original timeline, before trim. Playback and exported captions start at 0 for the retained range."
    }

    private var splitButton: some View {
        Button("Split before word", systemImage: "scissors") {
            focused = nil; session.split()
            captionEditorCueID = session.selectedCueID
        }
            .buttonStyle(.bordered)
            .disabled(session.selectedWordID == nil || session.selectedWordID == session.selectedCue?.wordIDs.first)
    }
    private var mergeButton: some View {
        Button("Merge next", systemImage: "arrow.triangle.merge") { focused = nil; session.mergeNext() }
            .buttonStyle(.bordered)
            .disabled(!session.canMergeNext)
    }

    private func transcriptHeader(_ document: ProjectDocument) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                captionSummary(document).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                headerCaptionActions(document).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                captionSummary(document)
                headerCaptionActions(document)
            }
        }
        .padding(.horizontal, 8)
    }

    private func headerCaptionActions(_ document: ProjectDocument) -> some View {
        HStack(spacing: 4) {
            if canReTranscribe(document) {
                Button("Re-transcribe", systemImage: "arrow.clockwise") { requestReTranscription() }
                    .font(.subheadline).frame(minHeight: 44)
            }
            addCaptionButton
        }
    }

    private var addCaptionButton: some View {
        Button("Add caption", systemImage: "plus") { beginAddingCaption() }
            .font(.subheadline).frame(minHeight: 44)
    }

    private func captionSummary(_ document: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Captions").font(.headline)
                Text("\(session.snapshot?.cues.count ?? 0)").font(.caption).foregroundStyle(.secondary)
            }
            if let count = document.recognition?.progress.map({ $0.unresolvedCount }), count > 0 {
                Text(count == 1 ? "1 gap" : "\(count) gaps")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func canReTranscribe(_ document: ProjectDocument) -> Bool {
        guard let recognition = document.recognition,
              !recognition.words.isEmpty, !recognition.isIncomplete,
              !model.transcription.isActive(projectID) else { return false }
        return true
    }

    private func requestReTranscription() {
        guard !preparingTranscription else { return }
        guard !model.access.hasPro else {
            confirmingReTranscription = true
            return
        }
        // Refresh locally so an exhausted free allowance opens the paywall
        // before the confirmation instead of failing after it.
        preparingTranscription = true
        Task { @MainActor in
            defer { preparingTranscription = false }
            model.transcription.start()
            await model.transcription.waitForAuthorization()
            await model.transcription.refreshAllowance()
            if let error = model.transcription.persistenceError ?? model.transcription.allowanceError {
                model.alertMessage = error
            } else if model.transcription.allowance?.remaining == 0 {
                session.proUpsell = .captioning
            } else {
                confirmingReTranscription = true
            }
        }
    }

    private var reTranscriptionMessage: String {
        var text = "Your current captions stay available while transcription runs. When the new transcription succeeds, it will replace them, including any manual captions. If it fails or is cancelled, your current captions stay unchanged."
        if !model.access.hasPro {
            text += " This uses 1 free video when it succeeds."
        }
        return text
    }

    private func reTranscribe() {
        guard !preparingTranscription else { return }
        preparingTranscription = true
        Task { @MainActor in
            defer { preparingTranscription = false }
            focused = nil
            session.pause()
            session.endTyping()
            session.endMediaEditing()
            do {
                let saved = try await session.savedDocument()
                guard let recognition = saved.recognition,
                      !recognition.words.isEmpty, !recognition.isIncomplete else {
                    throw SpeechError.noSavedCaptions
                }
                try await model.transcription.reTranscribe(projectID: saved.id,
                    language: recognition.requestedLanguageCode ?? "auto")
            } catch ProError.requiresPro(let feature) {
                session.proUpsell = feature
            } catch {
                model.alertMessage = error.localizedDescription
            }
            await session.refreshSaved()
        }
    }

    private func retryReTranscription(_ record: JobRecord) {
        guard !preparingTranscription else { return }
        preparingTranscription = true
        Task { @MainActor in
            defer { preparingTranscription = false }
            focused = nil
            session.pause()
            session.endTyping()
            session.endMediaEditing()
            do {
                _ = try await session.savedDocument()
                let language = try record.decode(SpeechJob.self).payload.languageCode ?? "auto"
                try await model.transcription.retry(record, language: language)
            } catch ProError.requiresPro(let feature) {
                session.proUpsell = feature
            } catch {
                model.alertMessage = error.localizedDescription
            }
            await session.refreshSaved()
        }
    }

    @ViewBuilder
    private func reTranscriptionPanel() -> some View {
        let speech = model.transcription
        if let record = speech.record(for: projectID),
           let payload = try? record.decode(SpeechJob.self).payload,
           payload.replacingRecognitionID != nil {
            if !record.status.isTerminal {
                VStack(alignment: .leading, spacing: 6) {
                    Text(speech.queue?.isPaused == true ? "Re-transcription paused" :
                        record.status == .pending ? "Waiting to re-transcribe…" :
                        record.status == .cancelling ? "Cancelling…" :
                        speech.queue?.liveProgress[record.id]?.message ?? "Re-transcribing…")
                        .font(.subheadline)
                    Text("Current captions stay available until the new run succeeds.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let fraction = speech.queue?.liveProgress[record.id]?.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Button("Cancel", role: .cancel) {
                        do { try speech.cancel(record.id) }
                        catch { model.alertMessage = error.localizedDescription }
                    }
                    .disabled(record.status == .cancelling)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if record.status.isRetryable {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.status == .cancelled
                        ? "Re-transcription cancelled. Current captions were kept."
                        : "Re-transcription couldn't finish. Current captions were kept.")
                        .font(.subheadline)
                    if let error = record.error {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Try again", systemImage: "arrow.clockwise") {
                        retryReTranscription(record)
                    }
                    .disabled(preparingTranscription || speech.isAuthorizing ||
                        speech.persistenceError != nil || !speech.modelAvailable || model.access.isChecking)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if record.status == .unrecoverable {
                Text("Re-transcription could not be restored. Current captions were kept.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func beginAddingCaption(gap: CaptionGap? = nil) {
        guard let document = session.document else { return }
        focused = nil
        session.pause(); session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
        let timeline = OutputTimeline(document)
        let candidates = document.orderedClips.filter { timeline.outputInterval($0.timelineInterval) != nil }
        let preferred = gap?.clipID ?? session.currentClip?.id
        guard let clip = candidates.first(where: { $0.id == preferred }) ?? candidates.first,
              let retained = timeline.outputInterval(clip.timelineInterval) else { return }
        let lower = gap.map { max(retained.start, $0.interval.start) } ?? retained.start
        let upper = gap.map { min(retained.end, $0.interval.end) } ?? retained.end
        let length = CMTime(seconds: 2, preferredTimescale: 60_000)
        let latestStart = (try? MediaTime(validating: CMTimeSubtract(upper.cmTime, length))) ?? lower
        let start = gap != nil ? lower : min(max(lower, session.time), max(lower, latestStart))
        let end = min(upper, (try? MediaTime(validating: CMTimeAdd(start.cmTime, length))) ?? upper)
        guard let interval = try? MediaInterval(start: start, end: end) else { return }
        addingCaption = ManualCaptionDraft(clipID: clip.id, interval: interval)
        session.seek(to: start)
    }

    private func retryMissing(windowIndices: [Int]? = nil) {
        guard !preparingTranscription else { return }
        focused = nil; session.pause(); session.endTyping()
        preparingTranscription = true
        Task {
            defer { preparingTranscription = false }
            do {
                _ = try await session.savedDocument()
                try await model.transcription.retryMissing(projectID: projectID, windowIndices: windowIndices)
            } catch ProError.requiresPro(let feature) { session.proUpsell = feature }
            catch { model.alertMessage = error.localizedDescription }
            await session.refreshSaved()
        }
    }

    private func finishActiveToolEditing() {
        let refreshMedia = session.workspace.tool == .media
        finishToolEditing()
        // Reconcile speech publication whose notification may have arrived while
        // the Media transaction excluded session reloads, as Style already does.
        if refreshMedia { Task { await session.refreshAfterMediaEditing() } }
        queueOwnerDidDismiss()
    }

    private func finishToolEditing() {
        focused = nil
        session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
        if activeToolSheet == nil, let id = captionEditorCueID {
            captionEditorCueID = nil
            editingCaptionFromTranscript = false
            session.prepareCaptionPlayback(id)
        }
        Task { await session.flush() }
    }

    private var styleSheet: some View {
        CaptionStyleInspector(session: session, previewIsActive: $showStyleSheet)
    }

    private var manualPreviewBinding: Binding<Bool> {
        Binding(get: { addingCaption != nil }, set: { if !$0 { addingCaption = nil } })
    }

    private var projectInfoSheet: some View {
        NavigationStack {
            Form {
                if let document = session.document {
                    if hasStatusError {
                        Section("Status") { status }
                            .listRowBackground(theme.surfaceColor)
                    }
                    projectInfo(document)
                    ProjectStorageSection(session: session)
                        .listRowBackground(theme.surfaceColor)
                }
            }
            .scrollContentBackground(.hidden)
            .listRowSeparatorTint(theme.borderColor)
            .navigationTitle("Project info")
            .navigationBarTitleDisplayMode(.inline)
            .themedSurface()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showProjectInfo = false
                        Task { await session.flush() }
                    }
                }
            }
            .fileImporter(isPresented: $isRelinking, allowedContentTypes: [.movie, .audio]) { result in
                switch result {
                case .success(let url):
                    guard let relinkAsset else { return }
                    Task {
                        await session.flush()
                        guard !session.hasPendingChanges else { return }
                        await model.relink(projectID: projectID, assetID: relinkAsset, from: url)
                        await session.refreshSaved()
                    }
                case .failure(let error): model.alertMessage = error.localizedDescription
                }
            }
        }
        .alert("Project info", isPresented: Binding(
            get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
        .onDisappear { Task { await session.flush() } }
    }

    @ViewBuilder private func projectInfo(_ document: ProjectDocument) -> some View {
        Section("Project") {
            LabeledContent("Title") {
                Text(document.title).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            LabeledContent("Clips", value: "\(document.clips.count)")
            LabeledContent("Duration", value: EditorTime.display(document.outputDuration))
            LabeledContent("Canvas", value: "\(document.canvas.width) × \(document.canvas.height)")
            LabeledContent("Created", value: document.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Modified", value: document.updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
        .listRowBackground(theme.surfaceColor)
        Section("Original media") {
            ForEach(document.assets) { asset in
                VStack(alignment: .leading, spacing: 5) {
                    Label(asset.displayName, systemImage: asset.kind == .video ? "film" : "waveform")
                    Text(ByteCountFormatter.string(fromByteCount: asset.byteCount, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                    if asset.kind == .video {
                        Text("\(asset.metadata.displayedWidth) × \(asset.metadata.displayedHeight) · \(EditorTime.display(asset.metadata.duration))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(EditorTime.display(asset.metadata.duration)).font(.caption).foregroundStyle(.secondary)
                    }
                    if session.originalAvailable[asset.id] == false {
                        Text("Original not found. Select the exact original file to restore it.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Find original…", systemImage: "folder") { relinkAsset = asset.id; isRelinking = true }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .listRowBackground(theme.surfaceColor)
    }
}

struct TimingFields: View {
    let interval: MediaInterval
    let identity: UUID
    let detail: String
    let apply: (MediaInterval) -> Void
    @Binding var workspace: EditorWorkspace
    @FocusState.Binding var focused: EditorField?
    @State private var start = ""
    @State private var end = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading) {
                    Text("Start (s)").font(.caption)
                    TextField("Start seconds", text: field(isStart: true)).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .timing(identity, false)).accessibilityLabel("Start seconds")
                        .id(EditorField.timing(identity, false))
                }
                VStack(alignment: .leading) {
                    Text("End (s)").font(.caption)
                    TextField("End seconds", text: field(isStart: false)).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .timing(identity, true)).accessibilityLabel("End seconds")
                        .id(EditorField.timing(identity, true))
                }
            }
            Button("Apply timing") {
                do { let value = try EditorTime.interval(start: start, end: end, preserving: interval); error = nil; focused = nil; apply(value) }
                catch { self.error = "Enter valid start and end seconds, with end after start." }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(.vertical, 8)
        .onAppear { reset() }
        .onChange(of: identity) { _, _ in reset() }
        .onChange(of: interval) { _, _ in reset() }
        .onChange(of: workspace.fieldResetGeneration) { _, _ in reset() }
    }
    private func field(isStart: Bool) -> Binding<String> {
        Binding(get: { isStart ? start : end }, set: { value in
            if isStart { start = value } else { end = value }
            workspace.timingDrafts[identity] = EditorTimingDraft(id: identity, interval: interval, start: start, end: end)
        })
    }
    private func reset() {
        if let draft = workspace.timingDrafts[identity], draft.interval == interval {
            start = draft.start; end = draft.end
        } else { start = EditorTime.field(interval.start); end = EditorTime.field(interval.end) }
        error = nil
    }
}
