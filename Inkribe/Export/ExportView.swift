import AppFoundation
import SwiftUI

/// One create action captures the saved document and enqueues a durable export.
/// Project activity resolves saved job IDs again when this sheet is reopened.
struct ExportView: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: EditorSession?
    var focusedJobID: UUID? = nil
    @State private var profile = ExportProfile()
    @State private var launching = false
    @State private var launchTask: Task<Void, Never>?
    @State private var error: String?
    @State private var message: String?
    @State private var acceptanceToast: ConfirmationToast?
    @State private var upsell: ProFeature?
    @State private var acceptedJobID: UUID?
    @State private var exportDetails: ProcessingJobKey?
    @State private var didFocusExport = false
    @State private var hasLoadedExports = false
    private var exports: ExportController { model.exports }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                Form {
                    Group {
                        configuration
                        if let session {
                            ProjectExportsSection(session: session, focusedJobID: selectedExportID,
                                showsUnavailableExport: hasLoadedExports && !exports.isRefreshingArtifacts &&
                                    selectedExportID != nil && exportFocusAnchor == nil,
                                requestError: error,
                                onDetails: { exportDetails = .init(kind: .export, jobID: $0) }) { previous in
                                didFocusExport = true
                                profile = previous
                                if previous.format == .mp4 && previous.resolution == .fullHD && !model.access.hasPro {
                                    profile.resolution = .hd
                                    upsell = .fullHD
                                }
                                scroll.scrollTo("export-configuration", anchor: .top)
                            }
                        }
                    }
                    .listRowBackground(theme.surfaceColor)
                    .listRowSeparatorTint(theme.borderColor)
                }
                .task(id: exportFocusTarget) {
                    guard let id = exportFocusTarget, !didFocusExport else { return }
                    await Task.yield()
                    guard !Task.isCancelled, !didFocusExport, exportFocusTarget == id else { return }
                    scroll.scrollTo(id, anchor: .top)
                    didFocusExport = true
                }
            }
            .navigationTitle("Export")
            .onChange(of: profile) { _, _ in didFocusExport = true }
            .themedSurface()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.disabled(launching || exports.hasUserDelivery)
                }
            }
            .task {
                await exports.start()
                await exports.refreshArtifacts()
                hasLoadedExports = true
            }
            .refreshable { await exports.refreshArtifacts() }
            .alert("Export", isPresented: Binding(
                get: { upsell == nil && exportDetails == nil && !exports.hasUserDelivery && model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } })) {
                Button("OK", role: .cancel) { model.alertMessage = nil }
            } message: { Text(model.alertMessage ?? "") }
            .sheet(item: $upsell) { ProUpsell(feature: $0) }
            .queueJobDetails($exportDetails)
        }
        .interactiveDismissDisabled(launching || exports.hasUserDelivery)
        .confirmationToast($acceptanceToast)
    }

    @ViewBuilder private var configuration: some View {
        if let session {
            Section("Export this project") {
                Text(session.document?.title ?? "Project").font(.headline)
                if session.document?.recognition?.isIncomplete == true {
                    Label("Some ranges have unfinished transcription. Export available and manual captions now, or retry those ranges in the editor.",
                          systemImage: "exclamationmark.bubble")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if session.snapshot?.manualConflicts.isEmpty == false {
                    Label("Manual captions replace overlapping recognized captions in this export. Review them in Captions before continuing.", systemImage: "exclamationmark.bubble")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Picker("Format", selection: $profile.format) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if profile.format == .mp4 {
                    Picker("Resolution", selection: Binding(get: { profile.resolution }, set: { value in
                        if value == .fullHD && !model.access.hasPro { upsell = .fullHD }
                        else { profile.resolution = value }
                    })) {
                        Text("720p").tag(ExportResolution.hd)
                        Text(model.access.hasPro ? "1080p" : "1080p · Pro").tag(ExportResolution.fullHD)
                    }
                    .disabled(model.access.isChecking)
                    Picker("Frame rate", selection: $profile.frameRate) {
                        ForEach(ExportFrameRate.allCases, id: \.self) { rate in
                            Text(rate.title).tag(rate)
                        }
                    }
                    if let canvas = session.document?.canvas, let output = try? profile.resolution.canvas(for: canvas) {
                        LabeledContent("Output", value: "\(output.width) × \(output.height) · \(profile.frameRate.title)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("H.264 MP4 with burned-in captions and original audio. Higher frame rates create larger files and take longer to export. Audio-only projects use a black canvas.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("UTF-8 subtitles with your edited text and project timing. Fonts and animations are part of video exports.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(action: launch) {
                    if launching || exports.isPreparing { ProgressView("Preparing export…") }
                    else { Label("Create Export", systemImage: "square.and.arrow.up") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(launching || exports.isPreparing || exports.persistenceError != nil
                    || model.processing.lifecycle.error != nil || session.document == nil
                    || model.access.isChecking || (profile.format == .srt && !hasCaptions))
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if profile.format == .srt && !hasCaptions {
                    Text("Add or transcribe at least one visible caption to export SRT.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Each export keeps its own saved version and file. Progress and completed videos or subtitles appear below while you continue editing.")
                    .font(.footnote).foregroundStyle(.secondary)
                if launching {
                    Button("Cancel preparation", role: .cancel) { launchTask?.cancel() }
                }
            }
            .id("export-configuration")
        }
    }

    private var hasCaptions: Bool {
        guard let snapshot = session?.snapshot else { return false }
        return snapshot.cues.contains { !snapshot.text(for: $0).isEmpty }
    }
    private var selectedExportID: UUID? { acceptedJobID ?? focusedJobID }

    /// Every queue record and retained artifact has one row, regardless of
    /// status or file availability. Never substitute a different export.
    private var exportFocusAnchor: UUID? {
        guard let id = selectedExportID, let session else { return nil }
        if let entry = model.processing.entry(.init(kind: .export, jobID: id)),
           entry.projectID == session.projectID { return id }
        if let artifact = exports.artifacts[id], artifact.projectID == session.projectID { return id }
        return nil
    }
    private var exportFocusTarget: UUID? {
        guard hasLoadedExports, !exports.isRefreshingArtifacts else { return nil }
        return exportFocusAnchor
    }
    private func launch() {
        guard let session, !launching else { return }
        didFocusExport = true
        launching = true; error = nil; message = nil; acceptanceToast = nil
        session.pause(); session.endTyping(); session.endStyleEditing()
        let selected = profile
        launchTask = Task {
            do {
                let document = try await session.savedDocument()
                try Task.checkCancellation()
                let id = try await exports.enqueue(document: document, profile: selected)
                acceptedJobID = id
                acceptanceToast = ConfirmationToast(text: "Export added")
                // Each accepted request gets one focus using the same durable
                // activity/file anchors as a queue deep link.
                didFocusExport = false
            } catch is CancellationError { message = "Export preparation cancelled." }
            catch ProError.requiresPro(let feature) { upsell = feature }
            catch { self.error = error.localizedDescription }
            launching = false
            launchTask = nil
            await model.refreshStorage()
        }
    }
}
