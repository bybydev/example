import CoreMedia
import SwiftUI
import AppFoundation
import UniformTypeIdentifiers

enum EditorField: Hashable { case title, caption(UUID), word(UUID), timing(UUID, Bool), trimStart, trimEnd }

struct ProjectEditorView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appFoundationTheme) private var theme
    let projectID: UUID
    private let sessions: EditorSessions
    private let renameOnOpen: Bool
    @State private var session: EditorSession
    @State private var presentationID = UUID()
    @State private var showClips = false
    @State private var clipsInitialSelection: UUID?
    @State private var addingCaption: ManualCaptionDraft?
    @State private var relinkAsset: UUID?
    @State private var isRelinking = false
    @State private var showDeleteConfirmation = false
    @State private var activeToolSheet: EditorTool?
    @State private var preparationAttempt = UUID()
    @State private var openingTask: Task<Void, Never>?
    @State private var isOpening = true
    @State private var isLeaving = false
    @State private var showStyleSheet = false
    @State private var showStyleBrowser = false
    @State private var captionRenderError: String?
    @State private var showExport = false
    @State private var showQueue = false
    @State private var preparingTranscription = false
    @State private var showProjectInfo = false
    @State private var didRequestInitialRename = false
    @State private var focusTitleOnPresentation = false
    @FocusState private var focused: EditorField?

    init(session: EditorSession, sessions: EditorSessions, renameOnOpen: Bool = false) {
        self.projectID = session.projectID
        self.sessions = sessions
        self.renameOnOpen = renameOnOpen
        _session = State(initialValue: session)
    }

    // Keep layout, toolbar and presentation as separate opaque expressions.
    // A single modifier chain exceeded Swift's type-checking budget in CI.
    var body: some View {
        editorPresentation
        .onAppear { isLeaving = false; sessions.attach(session, owner: presentationID) }
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
    }

    private var editorPresentation: some View {
        editorDocumentPresentation
            .task(id: preparationAttempt) { await prepareEditor() }
            .sheet(item: $activeToolSheet, onDismiss: finishToolEditing) { tool in toolSheet(tool) }
            .fullScreenCover(isPresented: $session.workspace.expandedPreview,
                onDismiss: { session.pause() }) { fullscreenPlayer }
    }

    private var editorDocumentPresentation: some View {
        editorStylePresentation
            .sheet(isPresented: $showExport, onDismiss: finishToolEditing) {
                ExportView(session: session)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showQueue, onDismiss: { Task { await session.refreshSaved() } }) { ProcessingQueueSheet() }
            .sheet(isPresented: $showProjectInfo) { projectInfoSheet }
            .sheet(item: Binding(get: { activeToolSheet == nil ? addingCaption : nil },
                set: { if activeToolSheet == nil { addingCaption = $0 } }), onDismiss: finishToolEditing) { draft in
                    ManualCaptionSheet(session: session, draft: draft)
            }
            .sheet(isPresented: $showClips, onDismiss: finishToolEditing) {
                ProjectClipsSheet(session: session, initialClipID: clipsInitialSelection) { id in
                    session.seekToClip(id)
                    showClips = false
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
    }

    private var editorStylePresentation: some View {
        editorDialogs
            .sheet(isPresented: $showStyleSheet, onDismiss: finishToolEditing) { styleSheet }
            .sheet(isPresented: $showStyleBrowser, onDismiss: finishToolEditing) { CaptionStylesSheet(session: session) }
            .sheet(item: Binding(get: { showStyleSheet || showStyleBrowser || activeToolSheet != nil ? nil : session.proUpsell },
                set: { if !showStyleSheet && !showStyleBrowser && activeToolSheet == nil { session.proUpsell = $0 } })) { ProUpsell(feature: $0) }
    }

    private var editorDialogs: some View {
        editorNavigation
        .confirmationDialog("Move this project to Trash?", isPresented: $showDeleteConfirmation) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    await session.flush()
                    guard !session.hasPendingChanges, !model.transcription.isActive(projectID) else { return }
                    await model.trash(projectID)
                    if model.alertMessage == nil { dismiss() }
                }
            }
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
        .navigationTitle(session.document?.title ?? "Project")
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
                    EditorPlaybackControls(session: session, showsTimeline: false,
                        onInteraction: { focused = nil },
                        onExpand: { session.workspace.expandedPreview = true })
                    timelineWorkspace(document)
                }
                .padding(.horizontal, 12).padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let error = session.loadError {
                VStack(spacing: 12) {
                    ContentUnavailableView("Cannot open project", systemImage: "exclamationmark.triangle",
                        description: Text(error))
                    Button("Retry", action: retryOpening).buttonStyle(.borderedProminent)
                    Button("Back", action: cancelOpening).frame(minHeight: 44)
                }.padding(16)
            } else {
                // Real editor geometry is filled when the document arrives. The
                // delayed preparation overlay supplies the indicator and Cancel.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func timelineWorkspace(_ document: ProjectDocument) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                timelineHeader(document)
                ProjectTimelineView(session: session,
                    isActive: scenePhase == .active && !hasPresentedSheet && !isOpening && !isLeaving && !session.isChangingClips,
                    onInteraction: finishToolInteraction,
                    onCaption: timelineCaptionTapped,
                    onClip: { session.seekToClip($0) })
                    .frame(height: CGFloat(TimelineGeometry.trackHeight))
                editorErrors
                if document.recognition?.isIncomplete == true {
                    Button("Review unfinished captions", systemImage: "exclamationmark.bubble") { switchTool(.captions) }
                        .font(.footnote).frame(minHeight: 44)
                } else if !document.hasCaptionUnits {
                    Button("Add or generate captions", systemImage: "captions.bubble") { switchTool(.captions) }
                        .font(.footnote).frame(minHeight: 44)
                }
            }.padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("Project timeline")
    }

    private func timelineHeader(_ document: ProjectDocument) -> some View {
        HStack(spacing: 12) {
            Text("Timeline").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            let clip = selectedTimelineClip(in: document)
            let index = clip.flatMap { selected in document.orderedClips.firstIndex { $0.id == selected.id } }
            Button { openClips() } label: {
                HStack(spacing: 6) {
                    Text(index.map { "Clip \($0 + 1) of \(document.clips.count)" } ?? "Clips")
                        .font(.caption.weight(.medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Manage clips")
            .accessibilityValue(index.map { "Clip \($0 + 1) of \(document.clips.count)" } ?? "")
            .accessibilityHint("Opens the clip list at the selected clip")
        }
    }

    private func selectedTimelineClip(in document: ProjectDocument) -> ProjectClip? {
        document.clips.first { $0.id == session.workspace.timelineClipID } ?? session.currentClip
    }

    private func openClips() {
        finishToolInteraction()
        clipsInitialSelection = session.document.flatMap { selectedTimelineClip(in: $0)?.id }
        showClips = true
    }

    private func timelineCaptionTapped(_ id: UUID) {
        if session.workspace.timelineCueID == id, session.selectedCueID == id {
            session.workspace.setAnchor("timeline-caption-editor", for: .timing)
            switchTool(.timing)
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
        showProjectInfo || showClips || showExport || showQueue || showStyleSheet || showStyleBrowser ||
            activeToolSheet != nil || addingCaption != nil ||
            session.proUpsell != nil || session.workspace.expandedPreview
    }

    private func toolSheet(_ tool: EditorTool) -> some View {
        toolNavigation(tool)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .sheet(item: $addingCaption, onDismiss: finishToolEditing) { draft in
                ManualCaptionSheet(session: session, draft: draft)
            }
            .sheet(item: Binding(get: { session.proUpsell }, set: { session.proUpsell = $0 })) { ProUpsell(feature: $0) }
            .alert("Project", isPresented: Binding(get: { addingCaption == nil && session.proUpsell == nil && model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } })) {
                    Button("OK", role: .cancel) { model.alertMessage = nil }
                } message: { Text(model.alertMessage ?? "") }
    }

    private func toolNavigation(_ tool: EditorTool) -> some View {
        NavigationStack {
            toolContent(tool)
                .navigationTitle(tool.title).navigationBarTitleDisplayMode(.inline).themedSurface()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { activeToolSheet = nil } }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focused = nil; session.endTyping(); Task { await session.flush() } }
                    }
                }
        }
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
                        if tool == .captions || tool == .timing {
                            EditorPlaybackControls(session: session, onInteraction: { focused = nil })
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
                if let field { scroll.scrollTo(field, anchor: .center) }
            }
            .onChange(of: session.presentation?.cueID) { _, id in
                guard tool == .captions, session.workspace.followsPlayback, session.isPlaying,
                      focused == nil, let id else { return }
                scroll.scrollTo(id, anchor: .center)
            }
        }
    }

    private var fullscreenPlayer: some View {
        NavigationStack {
            GeometryReader { geometry in
                if let document = session.document {
                    VStack(spacing: 12) {
                        preview(document, height: max(0, geometry.size.height - 100), fullscreen: true)
                        EditorPlaybackControls(session: session, onInteraction: { focused = nil })
                    }.padding(12)
                }
            }
            .themedSurface()
            .navigationTitle("Preview").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { session.workspace.expandedPreview = false }
            } }
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
            ManualCaptionConflictReview(session: session)
            if document.hasCaptionUnits {
                Toggle("Follow captions during playback", isOn: $session.workspace.followsPlayback)
                    .font(.subheadline)
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
                if document.recognition == nil { transcription(document) }
            } else { transcription(document) }
        case .style:
            // Styles owns its existing animated browser rather than this sheet.
            EmptyView()
        case .timing:
            if let cue = session.selectedCue {
                CaptionTranscriptRow(session: session, cue: cue,
                    active: session.presentation?.cueID == cue.id,
                    openWords: { focused = nil }, focused: $focused)
                    .id("timeline-caption-editor")
                correctionPanel
                Button("Return to caption correction", systemImage: "captions.bubble") { switchTool(.captions) }
            } else {
                ContentUnavailableView("Select a caption", systemImage: "timer",
                    description: Text("Choose a caption in Captions to correct words, split, merge or adjust timing."))
                Button("Choose a caption") { switchTool(.captions) }
            }
        case .media:
            MediaPanel(session: session, focused: $focused)
        }
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
        if tool == .style { openStyleBrowser(); return }
        finishToolInteraction()
        session.workspace.select(tool)
        activeToolSheet = tool
    }

    private func openStyleBrowser() {
        finishToolInteraction()
        showStyleBrowser = true
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text(session.document?.title ?? "Project").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(saveStatus).font(.caption2).foregroundStyle(.secondary)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Export") {
                finishToolInteraction()
                showExport = true
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain).frame(minHeight: 44).tint(theme.accentColor)
            .disabled(isOpening || !session.isReadyToEdit || preparingTranscription || showStyleBrowser)
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
            Label(saveStatus, systemImage: hasStatusError ? "exclamationmark.triangle" : "checkmark.circle")
            Divider()
            Button("Rename", systemImage: "pencil") { beginRenaming() }
            Divider()
            Button(session.undoLabel, systemImage: "arrow.uturn.backward") { focused = nil; session.undo() }
                .disabled(!session.canUndo)
            Button(session.redoLabel, systemImage: "arrow.uturn.forward") { focused = nil; session.redo() }
                .disabled(!session.canRedo)
            Divider()
            Button(session.workspace.expandedPreview ? "Reduce preview" : "Expand preview", systemImage: "arrow.up.left.and.arrow.down.right") {
                focused = nil
                session.workspace.expandedPreview.toggle()
            }
            Button("Queue", systemImage: "list.bullet.rectangle") { openQueue() }
            Button("Style settings & resets", systemImage: "slider.horizontal.3") {
                focused = nil
                session.pause(); session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
                showStyleSheet = true
            }
            Button("Media tools", systemImage: "crop.rotate") {
                switchTool(.media)
            }
            Button("Project info", systemImage: "info.circle") {
                finishToolInteraction()
                showProjectInfo = true
            }
            Button("Duplicate project", systemImage: "plus.square.on.square") {
                Task {
                    await session.flush()
                    guard !session.hasPendingChanges else { return }
                    await model.duplicate(projectID)
                }
            }
            Button("Move to Trash", systemImage: "trash", role: .destructive) { showDeleteConfirmation = true }
                .disabled(model.transcription.isActive(projectID))
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Editor actions, " + saveStatus)
        .disabled(isOpening || !session.isReadyToEdit || preparingTranscription || showStyleBrowser)
    }

    private func openQueue() {
        guard !preparingTranscription else { return }
        focused = nil
        session.pause(); session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
        preparingTranscription = true
        Task {
            defer { preparingTranscription = false }
            do { _ = try await session.savedDocument(); showQueue = true }
            catch { model.alertMessage = error.localizedDescription }
        }
    }

    private func beginRenaming() {
        focused = nil
        session.pause()
        session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
        focusTitleOnPresentation = true
        showProjectInfo = true
    }

    private func previewHeight(_ document: ProjectDocument, in size: CGSize) -> CGFloat {
        let width = max(0, size.width - 24)
        let aspect = CGFloat(document.canvas.width) / CGFloat(document.canvas.height)
        // Reserve actual track/header space before sizing portrait footage.
        // Sheet/keyboard/focus state never enters this geometry calculation.
        let controls: CGFloat = dynamicTypeSize.isAccessibilitySize ? 88 : 44
        let reserved = CGFloat(TimelineGeometry.trackHeight) + 44 + 12 + 16 + controls + 24
        let available = max(0, size.height - reserved)
        return max(0, min(width / aspect, min(available, min(360, size.height * 0.48))))
    }

    private func preview(_ document: ProjectDocument, height: CGFloat, fullscreen: Bool = false) -> some View {
        ZStack {
            Color.black
            // Export/Queue can push another editor for this same app-owned
            // session. Remove the covered layer before a modal takes the player.
            if !showStyleSheet && !showExport && !showQueue && addingCaption == nil &&
                (!session.workspace.expandedPreview || fullscreen) { PlayerSurface(player: session.player) }
            if document.assets.allSatisfy({ $0.kind == .audio }) {
                Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.white.opacity(0.45))
            }
            if let snapshot = session.snapshot {
                StyledCaptionOverlay(snapshot: snapshot, time: session.time,
                    mediaSize: PreviewComposition.previewSize(for: document.canvas)) { captionRenderError = $0 }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(session.presentation?.text ?? "No caption at playhead")
            }
            if session.isPreparingPreview { ProgressView().tint(.white).accessibilityLabel("Preparing preview") }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var editorToolBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                actionButton("Clips", symbol: "film.stack", selected: showClips, action: openClips)
                ForEach(EditorTool.allCases) { tool in
                    actionButton(tool.title, symbol: tool.symbol, selected: activeToolSheet == tool || (tool == .style && showStyleBrowser)) {
                        switchTool(tool)
                    }
                }
                actionButton("Customize", symbol: "slider.horizontal.3", selected: showStyleSheet) {
                    finishToolInteraction(); showStyleSheet = true
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
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
            .fixedSize(horizontal: true, vertical: true)
            .frame(minWidth: 68, minHeight: 54)
            .padding(.horizontal, 6)
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
        !hasPresentedSheet && !isOpening
    }

    private var hasStatusError: Bool {
        session.saveError != nil || session.loadError != nil || session.commandError != nil
    }
    private var saveStatus: String {
        if session.document == nil { return session.isLoading ? "Opening…" : "Couldn’t open project" }
        if session.saveError != nil { return "Couldn’t save changes" }
        return session.hasPendingChanges || session.isSaving ? "Saving…" : "Saved"
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
                openWords: { switchTool(.timing) }, focused: $focused)
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
                Text(session.selectedManualCaption == nil ? "Words & phrases" : "Manual caption").font(.headline)
                Text(snapshot.text(for: cue).isEmpty ? "Hidden caption" : snapshot.text(for: cue))
                    .font(.body).textSelection(.enabled)
                Text(EditorTime.display(cue.interval.start) + "–" + EditorTime.display(cue.interval.end))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(session.selectedManualCaption == nil ? "Select a word to correct it. Clear its text to hide it; timing stays unchanged." : "This phrase uses timing you chose. Clear its text to hide it; no word timings are generated.")
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
                    if session.selectedWord?.timingProvenance == "whisper-segment" {
                        Text("This phrase uses Whisper's segment timing. Individual word timing was unavailable; correcting the phrase keeps its original interval.")
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
                if session.selectedManualCaption == nil {
                    ViewThatFits(in: .horizontal) {
                        HStack { splitButton; mergeButton }
                        VStack(alignment: .leading) { splitButton; mergeButton }
                    }
                } else if let manual = session.selectedManualCaption {
                    Button("Delete manual caption", role: .destructive) { focused = nil; session.deleteManualCaption(manual.id) }
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
        Button("Split before word", systemImage: "scissors") { focused = nil; session.split() }
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
                addCaptionButton.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                captionSummary(document)
                addCaptionButton
            }
        }
        .padding(.horizontal, 8)
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

    private func finishToolEditing() {
        focused = nil
        session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
        Task { await session.flush() }
    }

    private var styleSheet: some View {
        CaptionStyleInspector(session: session)
    }

    private var projectInfoSheet: some View {
        NavigationStack {
            ScrollView {
                if let document = session.document {
                    VStack(alignment: .leading, spacing: 20) {
                        if hasStatusError { status }
                        projectInfo(document)
                        ProjectStorageSection(session: session)
                    }
                    .padding(16)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Project info")
            .navigationBarTitleDisplayMode(.inline)
            .themedSurface()
            .task {
                if focusTitleOnPresentation {
                    focusTitleOnPresentation = false
                    focused = .title
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        focused = nil
                        session.endTyping()
                        showProjectInfo = false
                        Task { await session.flush() }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil; session.endTyping(); Task { await session.flush() } }
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
        .onDisappear { focused = nil; session.endTyping(); Task { await session.flush() } }
    }

    private func projectInfo(_ document: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project title").font(.caption).foregroundStyle(.secondary)
            TextField("Project title", text: Binding(get: { session.document?.title ?? "" }, set: { session.setTitle($0) }))
                .textFieldStyle(.roundedBorder).focused($focused, equals: .title)
                .accessibilityLabel("Project title, saved automatically")
            LabeledContent("Clips", value: "\(document.clips.count)")
            LabeledContent("Duration", value: EditorTime.display(document.outputDuration))
            LabeledContent("Canvas", value: "\(document.canvas.width) × \(document.canvas.height)")
            LabeledContent("Created", value: document.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Modified", value: document.updatedAt.formatted(date: .abbreviated, time: .shortened))
            Text("Original media").font(.headline).padding(.top, 8)
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
                    }
                }
            }
        }
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

