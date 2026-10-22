import AVKit
import AppFoundation
import CoreMedia
import UIKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// P1's normal app root. The empty-library invitation appears only when no
/// projects exist; it is not a repeated onboarding interstitial.
struct IOSProjectsView: View {
    @Environment(IOSProjectsModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appFoundationTheme) private var theme
    @State private var showingImport = false
    @State private var showingStorage = false
    @State private var showingModels = false
    @State private var showingAppearance = false
    @State private var showingPlan = false
    @State private var showingPaywall = false
    @State private var showingExport = false
    @State private var attemptedThumbnails: Set<UUID> = []

    var body: some View {
        @Bindable var binding = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Your projects")
                            .font(.title3.bold())
                        Spacer()
                        Menu {
                            Button("Recently updated", systemImage: "clock") { changeSort(.recent) }
                            Button("Oldest updated", systemImage: "calendar") { changeSort(.oldest) }
                            Button("Title", systemImage: "textformat.abc") { changeSort(.title) }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    filterBar

                    if model.projects.isEmpty {
                        if model.isLoading {
                            ProgressView("Loading projects…")
                                .frame(maxWidth: .infinity, minHeight: 180)
                        } else if model.search.isEmpty && model.filter == .all && model.libraryIssues.isEmpty {
                            ContentUnavailableView {
                                Label("Your next video starts here", systemImage: "film.stack")
                            } description: {
                                Text("Import a video or audio file to create your first project.")
                            } actions: {
                                Button("Add media", systemImage: "plus") { showingImport = true }
                                    .buttonStyle(.borderedProminent)
                            }
                            .padding(.vertical, 24)
                        } else {
                            ContentUnavailableView.search(text: model.search)
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)],
                                  spacing: 14) {
                            ForEach(model.projects) { project in
                                NavigationLink(value: project.id) {
                                    projectCard(project)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !model.libraryIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Projects needing attention", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            ForEach(model.libraryIssues) { issue in
                                Text(issue.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("Inkribe")
            .iosThemedSurface()
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $binding.search,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search project titles")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Inkribe Pro", systemImage: "crown.fill") { showingPlan = true }
                        Button("Appearance", systemImage: "paintpalette") { showingAppearance = true }
                        Button("Speech Models", systemImage: "cpu") { showingModels = true }
                        Button("Storage", systemImage: "internaldrive") { showingStorage = true }
                    } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.exports.record != nil || model.exports.persistenceError != nil {
                        Button("Current export", systemImage: "tray.and.arrow.up") { showingExport = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Inkribe Pro", systemImage: "crown.fill") { showingPaywall = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add", systemImage: "plus") { showingImport = true }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                IOSProjectDetailView(projectID: id, access: model.access)
            }
            .sheet(isPresented: $showingImport) {
                IOSImportView()
                    .environment(model)
            }
            .sheet(isPresented: $showingStorage) {
                IOSStorageView()
                    .environment(model)
            }
            .sheet(isPresented: $showingModels) { IOSSpeechModelsView() }
            .sheet(isPresented: $showingAppearance) { IOSAppearanceView() }
            .sheet(isPresented: $showingPlan) { IOSPlanView() }
            .sheet(isPresented: $showingPaywall) { IOSProPaywall() }
            .alert("Inkribe", isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.alertMessage = nil }
            } message: {
                Text(model.alertMessage ?? "")
            }
            .onChange(of: model.cacheGeneration) { _, _ in attemptedThumbnails.removeAll() }
            .onChange(of: model.search) { _, _ in Task { await model.refresh() } }
            .onChange(of: model.filter) { _, _ in Task { await model.refresh() } }
            .task {
                model.transcription.setForeground(scenePhase == .active)
                model.transcription.start()
                model.exports.setForeground(scenePhase == .active)
                await model.exports.start()
                await model.refresh()
            }
            .sheet(isPresented: $showingExport) { IOSExportView(session: nil) }
            .onChange(of: scenePhase) { _, value in
                model.transcription.setForeground(value == .active)
                model.exports.setForeground(value == .active)
                if value == .active { Task { await model.refresh() } }
                if value == .active { Task { await model.transcription.refreshAllowance() } }
            }
            .refreshable { await model.refresh() }

        }
    }

    private var filterBar: some View {
        @Bindable var binding = model
        return Picker("Filter", selection: $binding.filter) {
            Text("All").tag(IOSLibraryFilter.all)
            Text("Video").tag(IOSLibraryFilter.video)
            Text("Audio").tag(IOSLibraryFilter.audio)
            Text("Missing media").tag(IOSLibraryFilter.missingMedia)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Project filter")
    }

    private func projectCard(_ project: IOSProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.accentColor.opacity(0.25))
                if let url = project.thumbnailURL,
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 130)
                        .clipped()
                } else {
                    Image(systemName: project.mediaKind == .audio ? "waveform" : "film")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                }
                if !project.available {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: "\(project.id.uuidString)-\(model.cacheGeneration)") {
                guard project.thumbnailURL == nil, project.mediaKind == .video,
                      project.available, attemptedThumbnails.insert(project.id).inserted else { return }
                await model.regenerateThumbnail(project.id)
            }
            Text(project.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)
            HStack(spacing: 4) {
                Text(formattedDuration(project.duration))
                Text("·")
                Text(project.updatedAt, style: .date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func formattedDuration(_ time: MediaTime) -> String {
        let seconds = CMTimeGetSeconds(time.cmTime)
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func changeSort(_ value: IOSLibrarySort) {
        model.sort = value
        Task { await model.refresh() }
    }
}
