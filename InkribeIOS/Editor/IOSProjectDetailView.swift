import CoreMedia
import SwiftUI
import UniformTypeIdentifiers

private enum IOSEditorField: Hashable { case title, word(UUID), timing(UUID, Bool) }
private enum IOSEditorPanel: String, CaseIterable { case captions = "Captions", style = "Style", templates = "Templates" }

struct IOSProjectDetailView: View {
    @Environment(IOSProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let projectID: UUID
    @State private var session: IOSEditorSession
    @State private var relinkAsset: UUID?
    @State private var isRelinking = false
    @State private var showDeleteConfirmation = false
    @State private var showReloadConfirmation = false
    @State private var isLeaving = false
    @State private var panel = IOSEditorPanel.captions
    @State private var captionRenderError: String?
    @State private var showExport = false
    @FocusState private var focused: IOSEditorField?

    init(projectID: UUID) {
        self.projectID = projectID
        _session = State(initialValue: IOSEditorSession(projectID: projectID))
    }

    var body: some View {
        VStack(spacing: 8) {
            if let document = session.document {
                preview(document)
                transport
                if focused == nil {
                    IOSCaptionTimeline(snapshot: session.snapshot, selectedCueID: session.selectedCueID,
                        duration: IOSEditorTime.seconds(session.duration), seconds: IOSEditorTime.seconds(session.time),
                        seek: session.scrub)
                        .padding(.horizontal, 16)
                }
                status
                if document.recognition != nil {
                    Picker("Caption tools", selection: $panel) {
                        ForEach(IOSEditorPanel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                }
                editorContent(document)
            } else if let error = session.loadError {
                ContentUnavailableView("Cannot open project", systemImage: "exclamationmark.triangle",
                    description: Text(error))
                Button("Retry") { Task { await session.open() } }
            } else {
                ProgressView("Opening project…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session.document?.title ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", systemImage: "chevron.left") { leave() }
                    .disabled(isLeaving)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(session.undoLabel, systemImage: "arrow.uturn.backward") { focused = nil; session.undo() }
                    .disabled(!session.canUndo)
                Button(session.redoLabel, systemImage: "arrow.uturn.forward") { focused = nil; session.redo() }
                    .disabled(!session.canRedo)
                Button("Export", systemImage: "square.and.arrow.up") {
                    focused = nil
                    session.pause()
                    session.endTyping()
                    session.endStyleEditing()
                    showExport = true
                }
                .disabled(session.document == nil)
                Menu {
                    Button("Duplicate project", systemImage: "plus.square.on.square") {
                        Task {
                            await session.flush()
                            guard !session.hasPendingChanges else { return }
                            await model.duplicate(projectID)
                        }
                    }
                    Button("Move to Trash", systemImage: "trash", role: .destructive) { showDeleteConfirmation = true }
                        .disabled(model.transcription.isActive(projectID))
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Project actions")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil; session.endTyping(); Task { await session.flush() } }
            }
        }
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
        .confirmationDialog("Discard unsaved changes and reload?", isPresented: $showReloadConfirmation) {
            Button("Discard and reload", role: .destructive) {
                focused = nil
                Task { await session.reloadDiscardingDraft() }
            }
        } message: { Text("Only the last saved project will be kept. This also clears this session's undo history.") }
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
        .task { await session.open() }
        .sheet(isPresented: $showExport) { IOSExportView(session: session) }
        .onChange(of: model.transcription.resultGeneration) { _, _ in Task { await session.refreshSaved() } }
        .onChange(of: focused) { _, value in
            if case .word(let id)? = value { session.selectWord(id); session.beginTyping() }
            else { session.endTyping(); if value != nil { session.beginTyping() } }
        }
        .onChange(of: panel) { _, _ in focused = nil; session.endTyping(); session.endStyleEditing() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.pause(); Task { await session.flush() } }
        }
        .onDisappear {
            session.stop()
            Task { await session.flush(); await model.refresh() }
        }
    }

    private func preview(_ document: IOSProjectDocument) -> some View {
        GeometryReader { _ in
            ZStack {
                Color.black
                IOSPlayerSurface(player: session.player)
                if document.assets.allSatisfy({ $0.kind == .audio }) {
                    Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.white.opacity(0.45))
                }
                if let snapshot = session.snapshot {
                    IOSStyledCaptionOverlay(snapshot: snapshot, time: session.time) { captionRenderError = $0 }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(session.presentation?.text ?? "No caption at playhead")
                }
                if session.isPreparingPreview { ProgressView("Preparing preview…").tint(.white).foregroundStyle(.white) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(height: focused == nil ? 180 : 100)
        .padding(.horizontal, 16)
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Text(IOSEditorTime.display(session.time)).monospacedDigit()
            Spacer(minLength: 0)
            Button(session.isPlaying ? "Pause" : "Play", systemImage: session.isPlaying ? "pause.fill" : "play.fill") {
                focused = nil
                session.togglePlayback()
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(session.isPreparingPreview || session.previewError != nil)
            Spacer(minLength: 0)
            Text(IOSEditorTime.display(session.duration)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if session.isSaving { ProgressView().controlSize(.mini) }
                Text(session.saveError != nil ? "Changes not saved" : session.hasPendingChanges ? "Unsaved changes" : "Saved on this device")
                    .font(.caption).foregroundStyle(session.saveError != nil ? .red : .secondary)
                Spacer()
                if session.saveError != nil {
                    Button("Retry save") { Task { await session.flush() } }
                    Button("Reload") { showReloadConfirmation = true }
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
        .padding(.horizontal, 16)
    }

    private func editorContent(_ document: IOSProjectDocument) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = session.previewError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        Button("Retry preview") { Task { await session.retryPreview() } }
                    }
                    if let error = captionRenderError {
                        Label(error, systemImage: "captions.bubble").font(.footnote).foregroundStyle(.orange)
                    }
                    if let result = document.recognition {
                        if panel == .style {
                            IOSCaptionStylePanel(session: session)
                        } else if panel == .templates {
                            IOSCaptionTemplatesPanel(session: session)
                        } else if result.words.isEmpty {
                            Text("No speech was detected in this media.").foregroundStyle(.secondary)
                        } else {
                            correctionPanel.id("correction")
                            Text("Captions").font(.headline)
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(session.snapshot?.cues ?? []) { cue in
                                    captionRow(cue) {
                                        focused = nil
                                        session.selectCue(cue.id)
                                        if reduceMotion { scroll.scrollTo("correction", anchor: .top) }
                                        else { withAnimation { scroll.scrollTo("correction", anchor: .top) } }
                                    }
                                }
                            }
                        }
                    } else {
                        IOSTranscriptionView(document: document)
                    }
                    projectInfo(document)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.presentation?.cueID) { _, id in
                // Playback follows footage without mutating selection or taking editing focus.
                guard panel == .captions, session.isPlaying, focused == nil, let id else { return }
                if reduceMotion { scroll.scrollTo(id, anchor: .center) }
                else { withAnimation { scroll.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var correctionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cue = session.selectedCue, let snapshot = session.snapshot {
                Text("Correct caption").font(.headline)
                Text("Text keeps its timing. Clear a field to hide it, or enter a corrected phrase.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(cue.wordIDs, id: \.self) { id in
                    if let word = snapshot.wordsByID[id] {
                        HStack(alignment: .top) {
                            Button {
                                focused = nil
                                session.selectWord(id)
                            } label: {
                                Image(systemName: session.selectedWordID == id ? "checkmark.circle.fill" : "circle")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Select timed word: \(word.text)")
                            .accessibilityAddTraits(session.selectedWordID == id ? .isSelected : [])
                            TextField("Hidden word", text: Binding(
                                get: { (session.snapshot?.wordsByID[id]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) },
                                set: { session.editText(wordID: id, value: $0) }), axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .focused($focused, equals: .word(id))
                                .accessibilityLabel("Caption text at \(IOSEditorTime.display(word.projectInterval.start))")
                                .padding(.vertical, 4)
                        }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { splitButton; mergeButton }
                    VStack(alignment: .leading) { splitButton; mergeButton }
                }
                DisclosureGroup("Caption timing") {
                    IOSTimingFields(interval: cue.interval, identity: cue.id,
                        detail: "Seconds on the project timeline. Applying caption timing scales its word intervals as a manual correction.",
                        apply: session.retimeCue, focused: $focused)
                }
                if let word = session.selectedWord {
                    DisclosureGroup("Selected word timing") {
                        IOSTimingFields(interval: word.projectInterval, identity: word.id,
                            detail: "Seconds on the project timeline. Extending a word expands the caption if needed.",
                            apply: session.retimeWord, focused: $focused)
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var splitButton: some View {
        Button("Split before word", systemImage: "scissors") { focused = nil; session.split() }
            .buttonStyle(.bordered)
            .disabled(session.selectedWordID == nil || session.selectedWordID == session.selectedCue?.wordIDs.first)
    }
    private var mergeButton: some View {
        Button("Merge next", systemImage: "arrow.triangle.merge") { focused = nil; session.mergeNext() }
            .buttonStyle(.bordered)
    }

    private func captionRow(_ cue: IOSCaptionCue, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(IOSEditorTime.display(cue.interval.start)) – \(IOSEditorTime.display(cue.interval.end))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                let text = session.snapshot?.text(for: cue) ?? ""
                Text(text.isEmpty ? "Hidden caption" : text)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(cue.id == session.presentation?.cueID ? Color.indigo.opacity(0.25) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(cue.id == session.selectedCueID ? Color.purple : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .id(cue.id)
        .accessibilityAddTraits(cue.id == session.selectedCueID ? .isSelected : [])
    }

    private func projectInfo(_ document: IOSProjectDocument) -> some View {
        DisclosureGroup("Project and original media") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Project title", text: Binding(get: { session.document?.title ?? "" }, set: session.setTitle))
                    .textFieldStyle(.roundedBorder).focused($focused, equals: .title)
                    .accessibilityLabel("Project title, saved automatically")
                Text("\(document.clips.count) clips · \(document.canvas.width) × \(document.canvas.height)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(document.assets) { asset in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(asset.displayName, systemImage: asset.kind == .video ? "film" : "waveform")
                        if asset.kind == .video {
                            Text("\(asset.metadata.displayedWidth) × \(asset.metadata.displayedHeight) · \(IOSEditorTime.display(asset.metadata.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(IOSEditorTime.display(asset.metadata.duration)).font(.caption).foregroundStyle(.secondary)
                        }
                        if session.originalAvailable[asset.id] == false {
                            Text("Original not found. Select the exact original file to restore it.")
                                .font(.caption).foregroundStyle(.orange)
                            Button("Find original…", systemImage: "folder") { relinkAsset = asset.id; isRelinking = true }
                        }
                    }
                }
            }
            .padding(.top, 10)
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

private struct IOSTimingFields: View {
    let interval: MediaInterval
    let identity: UUID
    let detail: String
    let apply: (MediaInterval) -> Void
    @FocusState.Binding var focused: IOSEditorField?
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
                }
                VStack(alignment: .leading) {
                    Text("End (s)").font(.caption)
                    TextField("End seconds", text: $end).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .timing(identity, true)).accessibilityLabel("End seconds")
                }
            }
            Button("Apply timing") {
                do { let value = try IOSEditorTime.interval(start: start, end: end); error = nil; focused = nil; apply(value) }
                catch { self.error = "Enter valid start and end seconds, with end after start." }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(.vertical, 8)
        .onAppear { reset() }
        .onChange(of: identity) { _, _ in reset() }
        .onChange(of: interval) { _, _ in reset() }
    }
    private func reset() { start = IOSEditorTime.field(interval.start); end = IOSEditorTime.field(interval.end); error = nil }
}
