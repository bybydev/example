import AppFoundation
import SwiftUI

/// Focused controls include their own real, scrollable preview and transport.
/// The presenting editor removes its player layer while this sheet owns it.
struct CaptionStyleInspector: View {
    @Environment(\.dismiss) private var dismiss
    let session: EditorSession
    @State private var section = CaptionStyleSection.typography
    @State private var renderError: String?

    var body: some View {
        NavigationStack {
            inspectorContent
                .navigationTitle("Customize captions").navigationBarTitleDisplayMode(.inline).themedSurface()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(item: Binding(get: { session.proUpsell }, set: { session.proUpsell = $0 })) { ProUpsell(feature: $0) }
        }
        .presentationDetents([.large])
        .onDisappear { session.pause(); session.endStyleEditing(); Task { await session.flush() } }
    }

    private var inspectorContent: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let document = session.document {
                        preview(document).id("preview")
                        EditorPlaybackControls(session: session)
                        Text("Changes appear immediately in this preview. Scroll back to play or scrub at any time.")
                            .font(.caption).foregroundStyle(.secondary)
                        sectionPicker
                        CaptionStylePanel(session: session, section: section)
                        Button("Back to preview", systemImage: "play.rectangle") { scroll.scrollTo("preview", anchor: .top) }
                            .frame(minHeight: 44)
                        if let error = session.commandError { Text(error).font(.footnote).foregroundStyle(.red) }
                        if let error = session.saveError { Text(error).font(.footnote).foregroundStyle(.red) }
                    }
                }.padding(16).padding(.bottom, 24)
            }
        }
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(CaptionStyleSection.allCases) { item in
                    Button(item.rawValue) {
                        session.endStyleEditing()
                        section = item
                    }
                    .buttonStyle(.bordered)
                    .tint(section == item ? Color.accentColor : Color.secondary)
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func preview(_ document: ProjectDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                PlayerSurface(player: session.player)
                if document.assets.allSatisfy({ $0.kind == .audio }) {
                    Image(systemName: "waveform").font(.title).foregroundStyle(.white.opacity(0.45))
                }
                if let snapshot = session.snapshot {
                    StyledCaptionOverlay(snapshot: snapshot, time: session.time,
                        mediaSize: PreviewComposition.previewSize(for: document.canvas)) { renderError = $0 }
                        .accessibilityLabel(session.presentation?.text ?? "No caption at playhead")
                }
                if session.isPreparingPreview { ProgressView().tint(.white) }
            }
            .aspectRatio(CGFloat(document.canvas.width) / CGFloat(document.canvas.height), contentMode: .fit)
            .frame(maxHeight: 340)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if session.presentation == nil {
                Text("No visible caption at this time. Scrub to a caption to see changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = renderError ?? session.previewError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
