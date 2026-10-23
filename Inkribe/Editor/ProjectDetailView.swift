import CoreMedia
import SwiftUI
import AppFoundation
import UniformTypeIdentifiers

enum EditorField: Hashable { case title, word(UUID), timing(UUID, Bool), trimStart, trimEnd }
private enum EditorPanel: String, CaseIterable { case captions = "Captions", style = "Style", templates = "Templates", media = "Media" }

struct ProjectDetailView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let projectID: UUID
    @State private var session: EditorSession
    @State private var relinkAsset: UUID?
    @State private var isRelinking = false
    @State private var showDeleteConfirmation = false
    @State private var showReloadConfirmation = false
    @State private var isLeaving = false
    @State private var panel = EditorPanel.captions
    @State private var captionRenderError: String?
    @State private var showExport = false
    @State private var preparingTranscription = false
    @State private var expandedPreview = false
    @State private var showProjectInfo = false
    @FocusState private var focused: EditorField?

    init(projectID: UUID, access: ProAccess) {
        self.projectID = projectID
        _session = State(initialValue: EditorSession(projectID: projectID, access: access))
    }

    // Keep layout, toolbar and presentation as separate opaque expressions.
    // A single modifier chain exceeded Swift's type-checking budget in CI.
    var body: some View {
        editorPresentation
        .onChange(of: model.transcription.resultGeneration) { _, _ in Task { await session.refreshSaved() } }
        .onChange(of: focused) { _, value in
            if value != nil { expandedPreview = false }
            if case .word(let id)? = value { session.selectWord(id); session.beginTyping() }
            else { session.endTyping(); if value != nil { session.beginTyping() } }
        }
        .onChange(of: panel) { _, _ in focused = nil; session.endTyping(); session.endStyleEditing(); session.endMediaEditing() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.pause(); Task { await session.flush() } }
        }
        .onDisappear {
            guard !showProjectInfo, !showExport, session.proUpsell == nil else { return }
            session.stop()
            Task { await session.flush(); await model.refresh() }
        }
    }

    private var editorPresentation: some View {
        editorDialogs
        .task { await session.open() }
        .sheet(isPresented: $showExport) { ExportView(session: session) }
        .sheet(isPresented: $showProjectInfo) { projectInfoSheet }
        .sheet(item: Binding(get: { session.proUpsell }, set: { session.proUpsell = $0 })) { ProUpsell(feature: $0) }
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
        .confirmationDialog("Discard unsaved changes and reload?", isPresented: Binding(
            get: { showReloadConfirmation && !showProjectInfo }, set: { showReloadConfirmation = $0 })) {
            Button("Discard and reload", role: .destructive) {
                focused = nil
                Task { await session.reloadDiscardingDraft() }
            }
        } message: { Text("Only the last saved project will be kept. This also clears this session's undo history.") }
        .alert("Project", isPresented: Binding(
            get: { canPresentProjectError && model.alertMessage != nil },
            set: { if !$0 && canPresentProjectError { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
    }

    private var editorNavigation: some View {
        editorWorkspace
        .disabled(preparingTranscription || isLeaving)
        .navigationTitle(session.document?.title ?? "Project")
        .themedSurface()
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar { editorToolbar }
    }

    private var editorWorkspace: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                if let document = session.document {
                    if !expandedPreview && ((focused != nil && !showProjectInfo) || geometry.size.height < 420) {
                        HStack(spacing: 12) {
                            preview(document, height: 64, showsExpand: false)
                                .frame(width: 64)
                            transport(showsOverview: false)
                        }
                        .padding(.horizontal, 16)
                    } else {
                        preview(document, height: previewHeight(document, in: geometry.size))
                            .padding(.horizontal, 16)
                        transport(showsOverview: !expandedPreview)
                            .padding(.horizontal, 16)
                    }
                    if expandedPreview {
                        if hasEditorError {
                            Button("Review editor errors", systemImage: "exclamationmark.triangle") {
                                expandedPreview = false
                            }
                        }
                    } else {
                        if focused == nil { editorTools(document) }
                        editorContent(document, viewportHeight: geometry.size.height)
                            .layoutPriority(1)
                    }
                } else if let error = session.loadError {
                    ContentUnavailableView("Cannot open project", systemImage: "exclamationmark.triangle",
                        description: Text(error))
                    Button("Retry") { Task { await session.open() } }
                } else {
                    ProgressView("Opening project…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(expandedPreview ? "Done" : "Back", systemImage: expandedPreview ? "chevron.down" : "chevron.left") {
                if expandedPreview { expandedPreview = false } else { leave() }
            }
            .disabled(isLeaving || preparingTranscription)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Export") {
                focused = nil
                session.pause()
                session.endTyping()
                session.endStyleEditing()
                session.endMediaEditing()
                showExport = true
            }
            .font(.subheadline.weight(.semibold))
            .disabled(session.document == nil || preparingTranscription || isLeaving)
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
            Button(session.undoLabel, systemImage: "arrow.uturn.backward") { focused = nil; session.undo() }
                .disabled(!session.canUndo)
            Button(session.redoLabel, systemImage: "arrow.uturn.forward") { focused = nil; session.redo() }
                .disabled(!session.canRedo)
            Divider()
            Button(expandedPreview ? "Back to editor" : "Expand preview", systemImage: "arrow.up.left.and.arrow.down.right") {
                focused = nil
                expandedPreview.toggle()
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
        .disabled(session.document == nil || preparingTranscription || isLeaving)
    }

    private func previewHeight(_ document: ProjectDocument, in size: CGSize) -> CGFloat {
        if expandedPreview {
            let controls: CGFloat = typeSize.isAccessibilitySize ? 160 : 100
            return max(0, size.height - controls - (hasEditorError ? 80 : 0))
        }
        let width = max(0, size.width - 32)
        let aspect = CGFloat(document.canvas.width) / CGFloat(document.canvas.height)
        let fraction: CGFloat = typeSize.isAccessibilitySize ? 0.30 : 0.46
        return min(width / aspect, min(360, max(0, size.height * fraction)))
    }

    private func preview(_ document: ProjectDocument, height: CGFloat, showsExpand: Bool = true) -> some View {
        ZStack {
            Color.black
            PlayerSurface(player: session.player)
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
                    expandedPreview.toggle()
                } label: {
                    Image(systemName: expandedPreview ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .accessibilityLabel(expandedPreview ? "Back to editor" : "Expand preview")
                .padding(8)
            }
        }
    }

    private func transport(showsOverview: Bool) -> some View {
        HStack(spacing: 12) {
            Button(session.isPlaying ? "Pause" : "Play", systemImage: session.isPlaying ? "pause.fill" : "play.fill") {
                focused = nil
                session.togglePlayback()
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(session.isPreparingPreview || session.previewError != nil)
            VStack(spacing: 0) {
                CaptionTimeline(snapshot: session.snapshot, selectedCueID: session.selectedCueID,
                    duration: EditorTime.seconds(session.duration), seconds: EditorTime.seconds(session.time),
                    showsOverview: showsOverview, seek: session.scrub)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(EditorTime.display(session.time)).fixedSize()
                        Spacer()
                        Text(EditorTime.display(session.duration)).foregroundStyle(.secondary).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(EditorTime.display(session.time))
                        Text(EditorTime.display(session.duration)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
            }
        }
    }

    private func editorTools(_ document: ProjectDocument) -> some View {
        let panels = EditorPanel.allCases.filter { document.recognition != nil || $0 == .captions || $0 == .media }
        return Group {
            if typeSize.isAccessibilitySize {
                Picker("Editor tools", selection: $panel) {
                    ForEach(panels, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Editor tools", selection: $panel) {
                    ForEach(panels, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, 16)
    }

    private var canPresentProjectError: Bool {
        !showProjectInfo && !showExport && session.proUpsell == nil
    }

    private var hasEditorError: Bool {
        hasStatusError || session.previewError != nil || captionRenderError != nil
    }
    private var hasStatusError: Bool {
        session.saveError != nil || session.loadError != nil || session.commandError != nil
    }
    private var saveStatus: String {
        session.saveError != nil ? "Changes not saved" : session.hasPendingChanges ? "Saving changes…" : "Saved on this device"
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if session.isSaving { ProgressView().controlSize(.mini) }
                Text(saveStatus)
                    .font(.caption).foregroundStyle(session.saveError != nil ? .red : .secondary)
                Spacer()
            }
            if session.saveError != nil {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("Retry save") { Task { await session.flush() } }
                        Button("Reload") { showReloadConfirmation = true }
                    }
                    VStack(alignment: .leading) {
                        Button("Retry save") { Task { await session.flush() } }
                        Button("Reload") { showReloadConfirmation = true }
                    }
                }
            }
            if let error = session.saveError { Text(error).font(.footnote).foregroundStyle(.red) }
            if let error = session.loadError { Text(error).font(.footnote).foregroundStyle(.red) }
            if let error = session.commandError {
                HStack(alignment: .top) {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark.circle") { session.commandError = nil }.labelStyle(.iconOnly)
                }
            }
        }
    }

    private func editorContent(_ document: ProjectDocument, viewportHeight: CGFloat) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if hasStatusError { status }
                    if let error = session.previewError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        Button("Retry preview") { Task { await session.retryPreview() } }
                    }
                    if let error = captionRenderError {
                        Label(error, systemImage: "captions.bubble").font(.footnote).foregroundStyle(.orange)
                    }
                    if panel == .media {
                        MediaPanel(session: session, focused: $focused)
                    } else if let result = document.recognition {
                        if panel == .style {
                            CaptionStylePanel(session: session)
                        } else if panel == .templates {
                            CaptionTemplatesPanel(session: session)
                        } else if result.words.isEmpty {
                            transcription(document)
                        } else if session.snapshot?.cues.isEmpty != false {
                            Text("No captions are inside the retained range. Adjust or reset trim in Media to restore them.")
                                .foregroundStyle(.secondary)
                        } else {
                            let activeCueID = session.presentation?.cueID
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(session.snapshot?.cues ?? []) { cue in
                                    captionRow(cue, activeCueID: activeCueID)
                                }
                            }
                        }
                    } else {
                        transcription(document)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focused) { _, value in
                if let value, !showProjectInfo { scroll.scrollTo(value, anchor: .bottom) }
            }
            .onChange(of: viewportHeight) { _, _ in
                if let focused, !showProjectInfo { scroll.scrollTo(focused, anchor: .bottom) }
            }
            .onChange(of: session.selectedCueID) { _, id in
                guard panel == .captions, !session.isPlaying, focused == nil, let id else { return }
                scroll.scrollTo(id, anchor: .top)
            }
            .onChange(of: session.presentation?.cueID) { _, id in
                // Playback follows footage without mutating selection or taking editing focus.
                guard panel == .captions, session.isPlaying, focused == nil, let id else { return }
                if reduceMotion { scroll.scrollTo(id, anchor: .center) }
                else { withAnimation { scroll.scrollTo(id, anchor: .center) } }
            }
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
                Text("Edit words").font(.subheadline.weight(.semibold))
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
                    TextField("Hidden word", text: Binding(
                        get: { (session.snapshot?.wordsByID[id]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) },
                        set: { session.editText(wordID: id, value: $0) }), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
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
                        apply: session.retimeCue, focused: $focused)
                }
                if let word = session.timingWord {
                    DisclosureGroup("Selected word timing") {
                        TimingFields(interval: word.projectInterval, identity: word.id,
                            detail: timingExplanation + " Extending a word expands the caption if needed.",
                            apply: session.retimeWord, focused: $focused)
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

    private func captionRow(_ cue: CaptionCue, activeCueID: UUID?) -> some View {
        let selected = cue.id == session.selectedCueID
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                focused = nil
                session.selectCue(cue.id)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(EditorTime.display(cue.interval.start)) – \(EditorTime.display(cue.interval.end))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Image(systemName: selected ? "pencil.circle.fill" : "pencil.circle")
                            .foregroundStyle(theme.accentColor)
                    }
                    let text = session.snapshot?.text(for: cue) ?? ""
                    Text(text.isEmpty ? "Hidden caption" : text)
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit caption at " + EditorTime.display(cue.interval.start))
            .accessibilityValue(session.snapshot?.text(for: cue) ?? "Hidden caption")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if selected {
                Divider()
                correctionPanel
            }
        }
        .padding(14)
        .background(cue.id == activeCueID ? theme.accentColor.opacity(0.15) : theme.surfaceColor,
            in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? theme.accentColor : .clear, lineWidth: 1.5))
        .id(cue.id)
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        focused = nil
                        session.endTyping()
                        Task {
                            await session.flush()
                            if !session.hasPendingChanges { showProjectInfo = false }
                        }
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
        .confirmationDialog("Discard unsaved changes and reload?", isPresented: Binding(
            get: { showReloadConfirmation && showProjectInfo }, set: { showReloadConfirmation = $0 })) {
            Button("Discard and reload", role: .destructive) {
                focused = nil
                Task { await session.reloadDiscardingDraft() }
            }
        } message: { Text("Only the last saved project will be kept. This also clears this session's undo history.") }
        .alert("Project details", isPresented: Binding(
            get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
        .interactiveDismissDisabled(session.hasPendingChanges)
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

    private func leave() {
        focused = nil
        session.pause()
        isLeaving = true
        Task {
            await session.flush()
            isLeaving = false
            if !session.hasPendingChanges { dismiss() }
        }
    }
}

private struct TimingFields: View {
    let interval: MediaInterval
    let identity: UUID
    let detail: String
    let apply: (MediaInterval) -> Void
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
                    TextField("Start seconds", text: $start).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .timing(identity, false)).accessibilityLabel("Start seconds")
                        .id(EditorField.timing(identity, false))
                }
                VStack(alignment: .leading) {
                    Text("End (s)").font(.caption)
                    TextField("End seconds", text: $end).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
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
    }
    private func reset() { start = EditorTime.field(interval.start); end = EditorTime.field(interval.end); error = nil }
}
