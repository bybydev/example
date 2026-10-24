import AppFoundation
import SwiftUI

/// Captures the editor's saved document, then follows the exact queued job ID.
struct ExportView: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: EditorSession?
    @State private var profile = ExportProfile()
    @State private var launching = false
    @State private var launchTask: Task<Void, Never>?
    @State private var error: String?
    @State private var message: String?
    @State private var upsell: ProFeature?
    @State private var path: [ProcessingJobKey] = []
    private var exports: ExportController { model.exports }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Group {
                    if let session {
                        Section("Export this project") {
                            Text(session.document?.title ?? "Project").font(.headline)
                            if session.document?.recognition?.isIncomplete == true {
                                Label("Some ranges have no captions yet. Export the available captions now or retry the gaps in the editor.",
                                      systemImage: "exclamationmark.bubble")
                                    .font(.footnote).foregroundStyle(.secondary)
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
                                if let canvas = session.document?.canvas, let output = try? profile.resolution.canvas(for: canvas) {
                                    LabeledContent("Output", value: "\(output.width) × \(output.height) · 30 fps")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("H.264 MP4 with burned-in captions and original audio. Audio-only projects use a black canvas.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Text("UTF-8 subtitles with your edited text and project timing. Fonts and animations are part of video exports.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button(action: launch) {
                                if launching || exports.isPreparing { ProgressView("Preparing export…") }
                                else { Label("Queue export", systemImage: "square.and.arrow.up") }
                            }
                            .disabled(launching || exports.isPreparing || exports.persistenceError != nil
                                || model.processing.lifecycle.error != nil || session.document == nil
                                || model.access.isChecking || (profile.format == .srt && !hasCaptions))
                            if profile.format == .srt && !hasCaptions {
                                Text("Transcribe the media and keep at least one visible caption to export SRT.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Text("Each export keeps its own saved revision and file. Other exports continue in Queue, and you can keep editing.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if launching {
                                Button("Cancel preparation", role: .cancel) { launchTask?.cancel() }
                            }
                        }
                    }
                    Section {
                        NavigationLink { ProcessingQueueView() } label: {
                            Label("Open Queue", systemImage: "list.bullet.rectangle")
                        }
                        Text("Keep Inkribe open while processing. Completed files stay in Queue until you explicitly delete them.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let storageError = exports.persistenceError {
                        Section {
                            Text(storageError).foregroundStyle(.red)
                            Button("Retry export storage") { Task { await exports.retryStorage() } }
                        }
                    }
                    if let issue = model.processing.lifecycle.error {
                        Section {
                            Text(issue).foregroundStyle(.red)
                            Button("Retry processing control storage") { model.processing.retryControlStorage() }
                        }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                    if let message { Section { Text(message).foregroundStyle(.secondary) } }
                }
                .listRowBackground(theme.surfaceColor)
                .listRowSeparatorTint(theme.borderColor)
            }
            .navigationTitle("Export")
            .themedSurface()
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ProcessingJobKey.self) { ProcessingJobDetail(key: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.disabled(launching || exports.isDelivering)
                }
            }
            .task { await exports.start(); await exports.refreshArtifacts() }
            .sheet(item: $upsell) { ProUpsell(feature: $0) }
        }
        .interactiveDismissDisabled(launching || exports.isDelivering)
    }

    private var hasCaptions: Bool {
        guard let snapshot = session?.snapshot else { return false }
        return snapshot.cues.contains { !snapshot.text(for: $0).isEmpty }
    }
    private func launch() {
        guard let session, !launching else { return }
        launching = true; error = nil; message = nil
        session.pause(); session.endTyping(); session.endStyleEditing()
        let selected = profile
        launchTask = Task {
            defer { launching = false; launchTask = nil }
            do {
                let document = try await session.savedDocument()
                try Task.checkCancellation()
                let id = try await exports.enqueue(document: document, profile: selected)
                path.append(.init(kind: .export, jobID: id))
                await model.refreshStorage()
            } catch is CancellationError { message = "Export preparation cancelled." }
            catch ProError.requiresPro(let feature) { upsell = feature }
            catch { self.error = error.localizedDescription }
        }
    }
}
