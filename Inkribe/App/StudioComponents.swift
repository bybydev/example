import AppFoundation
import SwiftUI

/// Shared chrome only. Caption artwork and video colors are never themed here.
private struct StudioCard: ViewModifier {
    @Environment(\.appFoundationTheme) private var theme
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(theme.borderColor, lineWidth: 1) }
    }
}

extension View {
    func studioCard(radius: CGFloat = 20) -> some View { modifier(StudioCard(radius: radius)) }
}

struct ProjectCreationHero: View {
    let isBusy: Bool
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New Project", systemImage: "captions.bubble")
                .font(.headline)
            Text("Add video or audio, then turn your words into captions.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: create) {
                Label(isBusy ? "Preparing project…" : "New Project", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(isBusy)
            .accessibilityHint("Choose video or audio from Photos, Files or a direct media URL")
            .accessibilityIdentifier("home.newProject")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct StudioActivityLabel: View {
    @Environment(\.appFoundationTheme) private var theme
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(theme.accentColor)
                .frame(minWidth: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .studioCard()
        .accessibilityElement(children: .combine)
    }
}

/// Matches Spokio iOS's scope capsules: clear fill, icon, label, count and outline.
struct LibraryScopePill: View {
    @Environment(\.appFoundationTheme) private var theme
    let title: String
    let systemImage: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? theme.accentColor : Color.secondary)
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.accentColor : .primary)
                .lineLimit(1)
            Text("\(count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? theme.accentColor.opacity(0.8) : Color.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.clear, in: Capsule())
        .overlay {
            Capsule().strokeBorder(isSelected ? theme.accentColor.opacity(0.55) : theme.borderColor, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct LibraryFolderEditor: View {
    @Environment(ProjectsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: LibraryFolder?
    let onSaved: () -> Void
    @State private var name: String
    @State private var saving = false

    init(folder: LibraryFolder?, onSaved: @escaping () -> Void) {
        self.folder = folder
        self.onSaved = onSaved
        _name = State(initialValue: folder?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name", text: $name)
                        .disabled(saving)
                } footer: {
                    Text("Keep related projects together. Deleting a folder keeps its projects.")
                }
                if saving { ProgressView("Saving folder…") }
            }
            .themedSurface()
            .navigationTitle(folder == nil ? "New Folder" : "Rename Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(folder == nil ? "Create" : "Save", action: save)
                        .disabled(saving || !model.organizationReady || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 256)
                }
            }
            .alert("Folder could not be saved", isPresented: Binding(
                get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.alertMessage = nil }
            } message: { Text(model.alertMessage ?? "") }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            let saved = if let folder { await model.renameFolder(folder.id, to: name) }
                else { await model.createFolder(name: name) }
            saving = false
            if saved { onSaved(); dismiss() }
        }
    }
}


