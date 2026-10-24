import AppFoundation
import SwiftUI

private struct ProjectEditorIntent: Hashable {
    var clipID: UUID?
    var tool: EditorTool?
}

/// Project overview and the editor share a single app-owned document/writer.
struct ProjectDetailView: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let session: EditorSession
    let sessions: EditorSessions
    var renameOnOpen = false
    @State private var owner = UUID()
    @State private var editorIntent: ProjectEditorIntent?
    @State private var renaming = false
    @State private var renamingClip: ProjectClip?
    @State private var exporting = false
    @State private var trashConfirmation = false
    @State private var didRename = false
    @State private var renderError: String?
    private var covered: Bool { editorIntent != nil || renaming || renamingClip != nil || exporting }

    private var navigation: some View {
        overview
            .navigationTitle(session.document?.title ?? "Project").navigationBarTitleDisplayMode(.inline).themedSurface()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { projectActions } }
            .navigationDestination(item: $editorIntent) { intent in
                ProjectEditorView(session: session, sessions: sessions, initialClipID: intent.clipID, initialTool: intent.tool)
            }
    }

    private var presentation: some View {
        navigation
            .sheet(isPresented: $renaming) { ProjectNameView(session: session) }
            .sheet(item: $renamingClip) { clip in ClipRenameView(session: session, clipID: clip.id) }
            .sheet(isPresented: $exporting) { ExportView(session: session) }
            .confirmationDialog("Move this project to Trash?", isPresented: $trashConfirmation) {
                Button("Move to Trash", role: .destructive) {
                    Task {
                        await session.flush()
                        guard !session.hasPendingChanges else { return }
                        await model.trash(session.projectID)
                        if model.alertMessage == nil { dismiss() }
                    }
                }
            } message: { Text("You can restore it from Storage. Completed exports are kept.") }
            .alert("Project", isPresented: Binding(get: { !covered && model.alertMessage != nil },
                set: { if !$0 && !covered { model.alertMessage = nil } })) {
                Button("OK", role: .cancel) { model.alertMessage = nil }
            } message: { Text(model.alertMessage ?? "") }
    }

    var body: some View {
        presentation
            .task {
                await session.open()
                await model.exports.start(); await model.exports.refreshArtifacts()
                if renameOnOpen, !didRename, session.document != nil { didRename = true; renaming = true }
            }
            .onAppear { sessions.attach(session, owner: owner) }
            .onDisappear {
                session.pause()
                Task { await session.flush() }
                if !covered { sessions.detach(session, owner: owner) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { session.pause(); Task { await session.flush() } }
            }
            .onChange(of: model.transcription.resultGeneration) { _, _ in Task { await session.refreshSaved() } }
    }

    private var overview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let document = session.document {
                    summary(document)
                    saveState
                    clips(document)
                    defaults(document)
                    ProjectExportsSection(session: session, onExport: { session.pause(); exporting = true })
                } else if let error = session.loadError {
                    ContentUnavailableView("Cannot open project", systemImage: "exclamationmark.triangle", description: Text(error))
                    Button("Try again") { Task { await session.open() } }
                } else { ProgressView("Opening project…").frame(maxWidth: .infinity).padding(30) }
            }.padding(16).padding(.bottom, 20)
        }.refreshable { await session.refreshSaved(); await model.exports.refreshArtifacts() }
    }

    private func summary(_ document: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Color.black
                if !covered { PlayerSurface(player: session.player) }
                if let snapshot = session.snapshot {
                    StyledCaptionOverlay(snapshot: snapshot, time: session.time,
                        mediaSize: PreviewComposition.previewSize(for: document.canvas)) { renderError = $0 }
                }
                Button { editorIntent = ProjectEditorIntent() } label: {
                    Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 56, height: 56).background(.black.opacity(0.5), in: Circle())
                }.accessibilityLabel("Open video editor")
            }.frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 15))
            Text("\(document.clips.count) \(document.clips.count == 1 ? "clip" : "clips") · \(EditorTime.display(document.outputDuration)) · \(document.canvas.width) × \(document.canvas.height)")
                .font(.caption).foregroundStyle(.secondary)
            Button("Edit captions", systemImage: "captions.bubble") { editorIntent = ProjectEditorIntent() }
                .buttonStyle(.borderedProminent).frame(minHeight: 44)
            if let error = renderError ?? session.previewError {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                Button("Retry preview") { Task { await session.retryPreview() } }
            }
        }
    }

    @ViewBuilder private var saveState: some View {
        if let error = session.saveError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn’t save changes", systemImage: "exclamationmark.circle").font(.headline)
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("Try again") { Task { await session.retrySave() } }.disabled(session.isSaving)
            }.studioCard()
        } else if let error = session.loadError {
            Text(error).font(.footnote).foregroundStyle(.orange)
            Button("Refresh project") { Task { await session.refreshSaved() } }
        } else {
            Label(session.hasPendingChanges || session.isSaving ? "Saving…" : "Saved", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func clips(_ document: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clips").font(.title3.weight(.semibold))
            ForEach(Array(document.orderedClips.enumerated()), id: \.element.id) { index, clip in
                clipRow(clip, index: index, document: document)
            }
            Text("Your clips play together as one video.").font(.caption).foregroundStyle(.secondary)
        }.studioCard()
    }

    private func clipRow(_ clip: ProjectClip, index: Int, document: ProjectDocument) -> some View {
        HStack(spacing: 8) {
            Button { editorIntent = ProjectEditorIntent(clipID: clip.id) } label: {
                HStack(spacing: 12) {
                    ClipThumbnail(projectID: document.id, clip: clip, source: document.assets.first { $0.id == clip.sourceAssetID })
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(index + 1). \(document.clipName(clip))").font(.subheadline).foregroundStyle(.primary)
                        Text("\(EditorTime.display(clip.timelineInterval.durationTime)) · " + (OutputTimeline(document).outputInterval(clip.timelineInterval).map { "In video " + EditorTime.display($0.start) } ?? "Outside trim"))
                            .font(.caption).foregroundStyle(.secondary)
                        if session.originalAvailable[clip.sourceAssetID] == false { Text("Original unavailable").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Menu {
                Button("Rename clip", systemImage: "pencil") { session.pause(); renamingClip = clip }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Actions for clip \(index + 1), \(document.clipName(clip))")
        }
    }

    private func defaults(_ document: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project defaults").font(.title3.weight(.semibold))
            Button { editorIntent = ProjectEditorIntent(tool: .style) } label: {
                LabeledContent("Captions", value: CaptionPreset.definition(for: document.effectiveCaptionStyle.preset)?.name ?? "Customized")
            }.frame(minHeight: 44)
            Button("Framing & original audio", systemImage: "crop.rotate") { editorIntent = ProjectEditorIntent(tool: .media) }.frame(minHeight: 44)
            Text("Clips follow these settings unless customized in the editor.").font(.caption).foregroundStyle(.secondary)
        }.studioCard()
    }

    private var projectActions: some View {
        Menu {
            Button("Rename", systemImage: "pencil") { session.pause(); renaming = true }
            Button("Duplicate project", systemImage: "plus.square.on.square") {
                Task { await session.flush(); guard !session.hasPendingChanges else { return }; await model.duplicate(session.projectID) }
            }
            Button("Export", systemImage: "square.and.arrow.up") { session.pause(); exporting = true }
            Button("Move to Trash", systemImage: "trash", role: .destructive) { trashConfirmation = true }
                .disabled(model.transcription.isActive(session.projectID))
        } label: { Image(systemName: "ellipsis.circle") }.disabled(session.document == nil)
    }
}

private struct ProjectNameView: View {
    @Environment(\.dismiss) private var dismiss
    let session: EditorSession
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                TextField("Project name", text: Binding(get: { session.document?.title ?? "" }, set: { session.setTitle($0) }))
                    .focused($focused)
                if let error = session.saveError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { Task { await session.retrySave() } }
                }
            }.navigationTitle("Rename project").navigationBarTitleDisplayMode(.inline).themedSurface()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { focused = false; dismiss() } } }
                .task { focused = true }
                .onDisappear { Task { await session.flush() } }
        }
    }
}
