import SwiftUI

struct ProjectSyncSettingsBar: View {
  @Bindable var model: ProjectSyncModel

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 12) {
        Image(systemName: "icloud")
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 28)

        VStack(alignment: .leading, spacing: 2) {
          Text("iCloud Projects")
            .font(.subheadline.weight(.semibold))
          Text(statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        if model.isEnabled {
          Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
            Task { @MainActor in await model.syncNow() }
          }
          .labelStyle(.iconOnly)
          .font(.system(size: 16, weight: .semibold))
          .disabled(model.isSyncing)
          .accessibilityLabel("Sync projects now")
        }

        Toggle(
          "Sync Projects with iCloud",
          isOn: Binding(
            get: { model.isEnabled },
            set: { enabled in
              Task { @MainActor in await model.setEnabled(enabled) }
            }
          )
        )
        .labelsHidden()
        .disabled(model.isSyncing)
      }
      .padding(.horizontal, 18)
      .frame(minHeight: 60)

      Text("Syncs project instructions, files, presets, and tool defaults. Chat history and credentials remain local to this device.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }
    .background(.bar)
  }

  private var statusText: String {
    if model.isSyncing { return "Syncing…" }
    if !model.isEnabled { return "Off" }
    if let date = model.lastSyncedAt {
      return "Last synced \(date.formatted(.relative(presentation: .named)))"
    }
    return "On"
  }
}
