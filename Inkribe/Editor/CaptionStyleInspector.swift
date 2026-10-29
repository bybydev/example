import AppFoundation
import SwiftUI

/// Project-wide appearance in a native form. The sample, all pushed pickers,
/// and template selection participate in the same Cancel/Done transaction.
struct CaptionStyleInspector: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appFoundationTheme) private var theme
    let session: EditorSession
    @Binding var previewIsActive: Bool
    @State private var draft: CaptionStyleDraft?
    @State private var path: [CaptionStyleDestination] = []
    @State private var saveError: String?
    @State private var saving = false

    var body: some View {
        navigation
            .sheet(item: Binding(get: { session.proUpsell }, set: { session.proUpsell = $0 })) { ProUpsell(feature: $0) }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(saving)
            .onAppear {
                session.pause()
                if draft == nil, let document = session.document { draft = CaptionStyleDraft(document: document) }
            }
            .onChange(of: draft?.generation) { _, _ in saveError = nil }
    }
    private var navigation: some View {
        NavigationStack(path: $path) {
            form
                .navigationTitle("Style").navigationBarTitleDisplayMode(.inline).themedSurface()
                .toolbar { sheetToolbar }
                .navigationDestination(for: CaptionStyleDestination.self) { destination in
                    if let draft {
                        if destination == .templates {
                            CaptionTemplatesGrid(session: session, draft: draft) { preset in
                                let controls = CaptionStyleFormControls(session: session, draft: draft)
                                if controls.set(preset.preservingPosition(of: draft.style)) { path.removeAll() }
                            }
                        } else { CaptionStyleDetailPicker(session: session, draft: draft, destination: destination) }
                    }
                }
        }
    }
    private var form: some View {
        Form {
            if let draft {
                Section {
                    CaptionStyleSamplePreview(style: draft.style,
                        isActive: previewIsActive && path.isEmpty && session.proUpsell == nil && !saving)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                Section("Template") { templateRow(draft) }.listRowBackground(theme.surfaceColor)
                CaptionStylePanel(session: session, draft: draft).listRowBackground(theme.surfaceColor)
                resetSection(draft)
                if let error = saveError ?? draft.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listRowSeparatorTint(theme.borderColor)
        .disabled(saving)
    }
    private func templateRow(_ draft: CaptionStyleDraft) -> some View {
        NavigationLink(value: CaptionStyleDestination.templates) {
            HStack(spacing: 12) {
                if let preset = draft.resetPreset {
                    CaptionTemplateThumbnail(preset: preset).frame(width: 44, height: 44)
                } else {
                    Text("Aa").font(.title2.bold()).foregroundStyle(theme.accentColor)
                        .frame(width: 44, height: 44).background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.styleName).font(.body)
                    if draft.isModified { Text("Modified").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityLabel("Template, " + draft.styleName + (draft.isModified ? ", modified" : ""))
    }
    @ViewBuilder private func resetSection(_ draft: CaptionStyleDraft) -> some View {
        if let preset = draft.resetPreset {
            Section {
                Button("Reset to \(preset.name)", systemImage: "arrow.counterclockwise") {
                    CaptionStyleFormControls(session: session, draft: draft).set(preset.preservingPosition(of: draft.style))
                }
                .frame(maxWidth: .infinity).disabled(session.access.isChecking || !draft.isModified)
            }.listRowBackground(theme.surfaceColor)
        } else if draft.style.preset != nil {
            Section { Text("The original template is unavailable. Your saved appearance is preserved.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    @ToolbarContentBuilder private var sheetToolbar: some ToolbarContent {
        if path.isEmpty {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }.disabled(saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if saving { ProgressView().accessibilityLabel("Saving style") }
                    else { Text("Done").fontWeight(.semibold) }
                }
                .disabled(saving || draft == nil || !session.isReadyToEdit || session.isLoading || session.isPreparingPreview ||
                    (draft?.hasChanges == true && session.access.isChecking))
            }
        }
    }
    private func save() {
        guard !saving, let draft else { return }
        saving = true; saveError = nil
        Task {
            defer { saving = false }
            do { try await session.saveCaptionStyleDraft(draft); dismiss() }
            catch ProError.requiresPro(let feature) { session.proUpsell = feature }
            catch { saveError = error.localizedDescription }
        }
    }
}
