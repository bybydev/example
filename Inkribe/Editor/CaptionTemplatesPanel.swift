import AppFoundation
import SwiftUI

struct CaptionTemplatesPanel: View {
    @Environment(\.appFoundationTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    let session: EditorSession
    let isComparing: Bool
    let customize: () -> Void
    let showPreview: () -> Void
    @State private var frame = CaptionPreviewFrame()
    @State private var refreshID = UUID()
    private var style: CaptionStyle { session.document?.effectiveCaptionStyle ?? .standard }
    private var audioOnly: Bool { session.document?.assets.allSatisfy { $0.kind == .audio } == true }
    private var request: CaptionFrameRequest {
        CaptionFrameRequest(generation: session.previewGeneration,
            time: session.isPlaying || !isComparing ? nil : session.time, preparing: session.isPreparingPreview, refreshID: refreshID, isActive: scenePhase == .active && isComparing)
    }
    private var reference: CaptionPreset {
        CaptionPreset.definition(for: style.preset) ?? CaptionPreset.matching(style) ?? .basic
    }
    private var presets: [CaptionPreset] {
        CaptionPreset.catalog.filter { session.workspace.presetCategory == nil || $0.category == session.workspace.presetCategory }
    }
    private var styleName: String {
        let known = CaptionPreset.definition(for: style.preset) ?? CaptionPreset.matching(style)
        guard let preset = known else { return "Customized" }
        if !preset.matches(style) { return preset.name + " · Customized" }
        let customPosition = style.positionX != preset.style.positionX || style.positionY != preset.style.positionY
        return preset.name + (customPosition ? " · Custom position" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a caption look").font(.headline)
            Text("Apply a look to every caption, keeping your chosen position.")
                .font(.subheadline).foregroundStyle(.secondary)
            comparisonStatus
            categoryPicker
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 150), spacing: 12)], spacing: 12) {
                ForEach(presets) { preset in
                    presetCard(preset)
                }
            }
            styleSummary
            Button("Back to video and playback", systemImage: "play.rectangle", action: showPreview)
                .frame(minHeight: 44)
        }
        .task(id: request) { await refreshFrame() }
        .onDisappear { frame.cancel(); session.endStyleEditing() }
    }

    private var styleSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(styleName).font(.headline)
            if let saved = style.preset {
                Text("Saved preset · v\(saved.version)").font(.caption).foregroundStyle(.secondary)
                if CaptionPreset.definition(for: saved) == nil {
                    Text("This saved look is preserved. Its original reset preset is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("\(style.font.name) · \(Int((style.fontSize * 100).rounded()))% · \(style.effect.name)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Position: \(Int((style.positionX * 100).rounded()))% across, \(Int((style.positionY * 100).rounded()))% down")
                .font(.caption).foregroundStyle(.secondary)
            Button("Customize", systemImage: "slider.horizontal.3", action: customize)
                .buttonStyle(.borderedProminent).frame(minHeight: 44)
            Button("Reset look to \(reference.name)", systemImage: "arrow.counterclockwise") {
                session.setCaptionStyle(reference.preservingPosition(of: style))
            }
            .disabled(!session.access.canChangeStyle(from: style, to: reference.preservingPosition(of: style)))
            Button("Use \(reference.name) placement", systemImage: "viewfinder") {
                session.setCaptionStyle(style.resetting(.placement, to: reference.style))
            }
            Button("Reset full style to Basic") { session.setCaptionStyle(CaptionPreset.basic.resolved) }
        }
        .studioCard()
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                categoryButton("All", category: nil)
                ForEach(CaptionPresetCategory.allCases, id: \.self) { category in
                    categoryButton(category.rawValue, category: category)
                }
            }
        }.scrollIndicators(.hidden)
    }
    private func categoryButton(_ title: String, category: CaptionPresetCategory?) -> some View {
        Button(title) { session.workspace.presetCategory = category }
            .buttonStyle(.bordered)
            .tint(session.workspace.presetCategory == category ? theme.accentColor : theme.secondaryForegroundColor)
            .frame(minHeight: 44)
            .accessibilityAddTraits(session.workspace.presetCategory == category ? .isSelected : [])
    }

    @ViewBuilder
    private var comparisonStatus: some View {
        if session.isPlaying {
            Text("Paused comparison frame. Pause playback to refresh the cards.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let error = frame.error {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            Button("Retry comparison frame") { refreshID = UUID() }
        } else if let time = frame.time {
            Text("Your \(audioOnly ? "audio canvas" : "footage") at \(EditorTime.display(time))")
                .font(.caption).foregroundStyle(.secondary)
            if session.snapshot?.evaluate(at: time) == nil {
                Text("No visible caption here. Select a caption or scrub to speech to compare looks.")
                    .font(.caption).foregroundStyle(.secondary)
                if let cue = session.selectedCue {
                    Button("Preview selected caption", systemImage: "captions.bubble") { session.selectCue(cue.id) }
                        .frame(minHeight: 44)
                }
            }
        }
        if session.document?.recognition?.words.contains(where: { $0.timingProvenance == "whisper-segment" }) == true {
            Text(style.formatVersion >= 2 ? "Phrase-timed text is emphasized as a whole phrase; it has no invented word timing." :
                "This legacy look uses phrase progress where word timing is unavailable.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func presetCard(_ preset: CaptionPreset) -> some View {
        let look = preset.preservingPosition(of: style)
        let selected = preset.matches(style) && (style.preset == preset.reference || style.preset == nil)
        let locked = !session.access.canChangeStyle(from: style, to: look)
        return Button {
            session.endStyleEditing()
            session.setCaptionStyle(look)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                CaptionPresetPreview(frame: frame, snapshot: session.snapshot, style: look, audioOnly: audioOnly)
                HStack(alignment: .firstTextBaseline) {
                    Text(preset.name).font(.headline)
                    Spacer(minLength: 4)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accentColor) }
                    if locked { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                }
                Text(preset.category.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
            }
            .studioCard()
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? theme.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.access.isChecking)
        .accessibilityLabel("\(preset.name), \(look.effect.name)\(locked ? ", requires Pro" : "")")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func refreshFrame() async {
        frame.cancel()
        if session.isPreparingPreview { frame.clear(); return }
        guard scenePhase == .active, isComparing, !session.isPlaying else { return }
        // Scrubbing can publish many playhead updates; decode only a settled pause.
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        guard !Task.isCancelled else { return }
        await frame.capture(item: session.player.currentItem, at: session.time, audioOnly: audioOnly)
    }
}
