import AppFoundation
import SwiftUI

/// Browsing is local state. Only Use style crosses the existing edit/access boundary.
struct CaptionStylesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    @State private var selectedID: String?
    private let presets = CaptionPreset.catalog

    private var index: Int { presets.firstIndex { $0.id == selectedID } ?? 0 }
    private var preset: CaptionPreset { presets[index] }
    private var currentStyle: CaptionStyle { session.editingCaptionStyle }
    private var nextStyle: CaptionStyle { preset.preservingPosition(of: currentStyle) }
    private var applied: Bool {
        preset.matches(currentStyle) && (currentStyle.preset == preset.reference || currentStyle.preset == nil)
    }
    private var locked: Bool { !session.access.canChangeStyle(from: currentStyle, to: nextStyle) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scopePicker
                    CaptionStyleDemo(preset: preset, isActive: session.proUpsell == nil)
                        .id(preset.id)
                        .contentShape(Rectangle())
                        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            move(value.translation.width < 0 ? 1 : -1)
                        })
                    carouselControls
                    Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    scopeExplanation
                    if session.presentation == nil, let cue = previewCue {
                        Button("Preview a caption in your video", systemImage: "play.rectangle") { session.selectCue(cue.id) }
                            .frame(minHeight: 44)
                    }
                    if let error = session.commandError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    if let error = session.saveError {
                        Text("Couldn’t save changes. " + error).font(.footnote).foregroundStyle(.orange)
                        Button("Try again") { Task { await session.retrySave() } }.disabled(session.isSaving)
                    }
                }.padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { applyBar }
            .navigationTitle("Caption styles").navigationBarTitleDisplayMode(.inline).themedSurface()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: Binding(get: { session.proUpsell }, set: { session.proUpsell = $0 })) { ProUpsell(feature: $0) }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .onAppear {
            if selectedID == nil {
                let matching = CaptionPreset.matching(currentStyle)
                selectedID = presets.first { $0.id == currentStyle.preset?.id }?.id ?? matching?.id ?? presets.first?.id
            }
        }
        .onChange(of: session.document?.clips.map(\.id)) { _, ids in
            if let id = session.editingClipID, ids?.contains(id) != true { session.selectSettingsScope(.project) }
        }
    }

    private var scopePicker: some View {
        EditorSettingsScopeMenu(session: session).font(.subheadline)
    }

    private var carouselControls: some View {
        HStack(spacing: 12) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    .background(theme.surfaceColor, in: Circle())
            }.accessibilityLabel("Previous style")
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(preset.name).font(.headline)
                    if locked { Label("Pro", systemImage: "lock.fill").font(.caption).foregroundStyle(theme.accentColor) }
                }
                Text("\(index + 1) of \(presets.count) · \(preset.category.rawValue)").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).accessibilityElement(children: .combine)
            .accessibilityAdjustableAction { direction in
                switch direction { case .increment: move(1); case .decrement: move(-1); @unknown default: break }
            }
            Button { move(1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    .background(theme.surfaceColor, in: Circle())
            }.accessibilityLabel("Next style")
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var scopeExplanation: some View {
        if let id = session.editingClipID, let document = session.document {
            if document.settings(for: id).captions.isEmpty {
                Text("Using project defaults. Apply a style to customize this clip.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Reset captions to project defaults", systemImage: "arrow.counterclockwise") { session.resetClipSettings() }
                    .font(.caption).frame(minHeight: 44)
            }
        } else {
            Text("Clips with customized settings keep their overrides.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var applyTitle: String {
        if session.access.isChecking { return "Checking purchases…" }
        return applied ? "\(preset.name) applied" : "Use \(preset.name)"
    }
    private var applyStatus: String {
        guard applied else { return "Browse samples, then apply to your video" }
        if session.saveError != nil { return "Changes need saving" }
        return session.hasPendingChanges || session.isSaving ? "Saving…" : "Applied in the selected scope"
    }
    private var applyBar: some View {
        VStack(spacing: 6) {
            Button(action: apply) {
                Label(applyTitle, systemImage: applied ? "checkmark" : locked ? "lock.fill" : "sparkles")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.borderedProminent).disabled(applied || session.access.isChecking || !session.isReadyToEdit)
            Text(applyStatus).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8).background(theme.backgroundColor)
    }

    private var previewCue: CaptionCue? {
        session.snapshot?.chronologicalCues.first { cue in
            guard let id = session.editingClipID else { return true }
            return cue.wordIDs.first.flatMap { session.snapshot?.wordsByID[$0]?.clipID } == id
        }
    }
    private func move(_ offset: Int) { selectedID = presets[(index + offset + presets.count) % presets.count].id }
    private func apply() {
        guard !session.access.isChecking, !applied else { return }
        if locked { session.pause() }
        session.endStyleEditing()
        session.setCaptionStyle(nextStyle, applyingPreset: true)
    }
}
