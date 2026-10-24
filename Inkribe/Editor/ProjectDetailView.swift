import CoreMedia
import SwiftUI
import AppFoundation
import UniformTypeIdentifiers

enum EditorField: Hashable { case title, caption(UUID), word(UUID), timing(UUID, Bool), trimStart, trimEnd }

struct ProjectDetailView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appFoundationTheme) private var theme
    let projectID: UUID
    private let sessions: EditorSessions
    private let renameOnOpen: Bool
    @State private var session: EditorSession
    @State private var presentationID = UUID()
    @State private var relinkAsset: UUID?
    @State private var isRelinking = false
    @State private var showDeleteConfirmation = false
    @State private var showStyleSheet = false
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
        .onAppear { sessions.attach(session, owner: presentationID) }
        .onChange(of: model.transcription.resultGeneration) { _, _ in Task { await session.refreshSaved() } }
        .onChange(of: focused) { _, value in
            if value != nil { session.workspace.expandedPreview = false }
            if case .word(let id)? = value { session.selectWord(id); session.beginTyping() }
            else { session.endTyping(); if value != nil { session.beginTyping() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.pause(); Task { await session.flush() } }
        }
        .onDisappear {
            guard !showProjectInfo, !showExport, !showQueue, !showStyleSheet, session.proUpsell == nil else { return }
            sessions.detach(session, owner: presentationID)
            Task { await session.flush(); await model.refreshLibrary() }
        }
    }

    private var editorPresentation: some View {
        editorDialogs
        .task {
            await session.open()
            if !Task.isCancelled, renameOnOpen, !didRequestInitialRename, session.document != nil {
                didRequestInitialRename = true
                beginRenaming()
            }
        }
        .sheet(isPresented: $showExport) { ExportView(session: session) }
        .sheet(isPresented: $showQueue, onDismiss: { Task { await session.refreshSaved() } }) { ProcessingQueueSheet() }
        .sheet(isPresented: $showProjectInfo) { projectInfoSheet }
        .sheet(isPresented: $showStyleSheet, onDismiss: finishToolEditing) { styleSheet }
        .sheet(item: Binding(get: { showStyleSheet ? nil : session.proUpsell }, set: { if !showStyleSheet { session.proUpsell = $0 } })) { ProUpsell(feature: $0) }
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
        .disabled(preparingTranscription || (session.document != nil && !session.isReadyToEdit))
        .navigationTitle(session.document?.title ?? "Project")
        .themedSurface()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
    }

    private var editorWorkspace: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    if let document = session.document {
                        scrollingWorkspace(document, size: geometry.size)
                    } else if let error = session.loadError {
                        ContentUnavailableView("Cannot open project", systemImage: "exclamationmark.triangle",
                            description: Text(error))
                        Button("Retry") { Task { await session.open() } }
                    } else {
                        ProgressView("Opening project…").padding(40)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollPosition(id: scrollBinding(for: session.workspace.tool))
                .id(session.workspace.tool)
                .onChange(of: focused) { _, field in
                    if let field, !showProjectInfo { scroll.scrollTo(field, anchor: .center) }
                }
                .onChange(of: geometry.size.height) { _, _ in
                    if let focused, !showProjectInfo { scroll.scrollTo(focused, anchor: .center) }
                }
                .onChange(of: session.workspace.tool) { _, _ in
                    scroll.scrollTo(session.workspace.scrollAnchor ?? "tools", anchor: .top)
                }
                .onChange(of: session.presentation?.cueID) { _, id in
                    // Following is explicit. Playback never changes editing selection or focus.
                    guard session.workspace.followsPlayback, session.workspace.tool == .captions,
                          session.isPlaying, focused == nil, let id else { return }
                    scroll.scrollTo("cue-" + id.uuidString, anchor: .center)
                }
            }
        }
    }

    private func scrollingWorkspace(_ document: ProjectDocument, size: CGSize) -> some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            preview(document, height: previewHeight(document, in: size))
                .id("preview")
            transport(showsOverview: true).id("transport")
            editorToolBar.id("tools")
            editorErrors
            if document.recognition?.isIncomplete == true {
                PartialCaptionStatus(document: document, preparing: preparingTranscription,
                    retry: { retryMissing() }, reset: resetRetryProgress)
            }
            activeWorkspace(document)
        }
        .scrollTargetLayout()
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 32)
    }

    @ViewBuilder
    private var editorErrors: some View {
        if hasStatusError { status }
        if let error = session.previewError {
            Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            Button("Retry preview") { Task { await session.retryPreview() } }
        }
        if let error = captionRenderError {
            Label(error, systemImage: "captions.bubble").font(.footnote).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func activeWorkspace(_ document: ProjectDocument) -> some View {
        switch session.workspace.tool {
        case .captions:
            if document.recognition?.words.isEmpty == false {
                transcriptHeader(document)
                Toggle("Follow captions during playback", isOn: $session.workspace.followsPlayback)
                    .font(.subheadline)
                if let snapshot = session.snapshot {
                    if snapshot.transcriptItems.isEmpty {
                        Text("No captions are inside the retained range. Adjust trim in Media to restore them.")
                            .foregroundStyle(.secondary)
                        Button("Media tools") { switchTool(.media) }
                    }
                    ForEach(snapshot.transcriptItems) { item in
                        transcriptRow(item).id(item.id)
                    }
                }
            } else { transcription(document) }
        case .style:
            CaptionTemplatesPanel(session: session, isComparing: !showStyleSheet, customize: { showStyleSheet = true },
                showPreview: { session.workspace.scrollAnchor = "preview" })
        case .timing:
            if session.selectedCue != nil {
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

    private func scrollBinding(for tool: EditorTool) -> Binding<String?> {
        // Capture the tool identity so a retiring scroll view cannot write its
        // last caption anchor into the newly selected tool's context.
        Binding(get: { session.workspace.anchor(for: tool) },
            set: { session.workspace.setAnchor($0, for: tool) })
    }

    private func switchTool(_ tool: EditorTool) {
        focused = nil
        session.pause()
        session.endTyping(); session.endStyleEditing(); session.endMediaEditing()
        session.workspace.select(tool)
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
            if session.workspace.expandedPreview {
                Button("Close expanded preview", systemImage: "arrow.down.right.and.arrow.up.left") { session.workspace.expandedPreview = false }
                    .labelStyle(.iconOnly)
            }
            Button("Export") {
                focused = nil
                session.pause()
                session.endTyping()
                session.endStyleEditing()
                session.endMediaEditing()
                showExport = true
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(!session.isReadyToEdit || preparingTranscription)
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
            Button("Media tools", systemImage: "crop.rotate") {
                switchTool(.media)
            }
            Button("Project details", systemImage: "info.circle") {
                focused = nil
                session.pause()
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
        } label: { Image(systemName: hasEditorError ? "exclamationmark.circle" : "ellipsis.circle") }
        .accessibilityLabel("Editor actions, " + saveStatus)
        .disabled(!session.isReadyToEdit || preparingTranscription)
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
        let width = max(0, size.width - 32)
        let aspect = CGFloat(document.canvas.width) / CGFloat(document.canvas.height)
        // The footage remains in the page even when expanded or the keyboard opens.
        return min(width / aspect, session.workspace.expandedPreview ? 560 : 360)
    }

    private func preview(_ document: ProjectDocument, height: CGFloat, showsExpand: Bool = true) -> some View {
        ZStack {
            Color.black
            // Export/Queue can push another editor for this same app-owned
            // session. Remove the covered layer before a modal takes the player.
            if !showStyleSheet && !showExport && !showQueue { PlayerSurface(player: session.player) }
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
        .overlay(alignment: .topTrailing) {
            if showsExpand {
                Button {
                    focused = nil
                    session.workspace.expandedPreview.toggle()
                } label: {
                    Image(systemName: session.workspace.expandedPreview ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .accessibilityLabel(session.workspace.expandedPreview ? "Reduce preview" : "Expand preview")
                .padding(8)
            }
        }
    }

    private func transport(showsOverview: Bool) -> some View {
        EditorPlaybackControls(session: session, showsOverview: showsOverview, onInteraction: { focused = nil })
    }

    private var editorToolBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(EditorTool.allCases) { tool in
                    Button { switchTool(tool) } label: {
                        Label(tool.title, systemImage: tool.symbol)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(session.workspace.tool == tool ? theme.accentColor.opacity(0.14) : theme.surfaceColor,
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(session.workspace.tool == tool ? theme.accentColor : theme.primaryForegroundColor)
                    .accessibilityAddTraits(session.workspace.tool == tool ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var canPresentProjectError: Bool {
        !showProjectInfo && !showExport && !showQueue && !showStyleSheet && session.proUpsell == nil
    }

    private var hasEditorError: Bool {
        hasStatusError || session.previewError != nil || captionRenderError != nil
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
                Button("Try again") { Task { await session.open() } }
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
                retry: { retryMissing(windowIndices: [gap.id]) })
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
                Text("Words & phrases").font(.headline)
                Text(snapshot.text(for: cue).isEmpty ? "Hidden caption" : snapshot.text(for: cue))
                    .font(.body).textSelection(.enabled)
                Text(EditorTime.display(cue.interval.start) + "–" + EditorTime.display(cue.interval.end))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                ViewThatFits(in: .horizontal) {
                    HStack { splitButton; mergeButton }
                    VStack(alignment: .leading) { splitButton; mergeButton }
                }
                DisclosureGroup("Caption timing") {
                    TimingFields(interval: session.timingCue?.interval ?? cue.interval, identity: cue.id,
                        detail: timingExplanation + " Applying caption timing scales its word intervals as a manual correction.",
                        apply: session.retimeCue, workspace: $session.workspace, focused: $focused)
                }
                if let word = session.timingWord {
                    DisclosureGroup("Selected word timing") {
                        TimingFields(interval: word.projectInterval, identity: word.id,
                            detail: timingExplanation + " Extending a word expands the caption if needed.",
                            apply: session.retimeWord, workspace: $session.workspace, focused: $focused)
                    }
                }
            }
        }
    }

    private func wordLabel(_ word: CaptionWord) -> String {
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
        HStack(spacing: 8) {
            Text("Captions").font(.headline)
            Text("\(session.snapshot?.cues.count ?? 0)").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let count = document.recognition?.progress.map({ $0.totalWindows - $0.resolved.count }), count > 0 {
                Text(count == 1 ? "1 gap" : "\(count) gaps")
                    .font(.caption2).foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.orange.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
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
                    }
                    .padding(16)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Project details")
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
        .alert("Project details", isPresented: Binding(
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
            Text("\(document.clips.count) clips · \(document.canvas.width) × \(document.canvas.height)")
                .font(.caption).foregroundStyle(.secondary)
            Text("Original media").font(.headline).padding(.top, 8)
            ForEach(document.assets) { asset in
                VStack(alignment: .leading, spacing: 5) {
                    Label(asset.displayName, systemImage: asset.kind == .video ? "film" : "waveform")
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

