import AppKit
import SwiftUI

struct MacAnswerSourcesSheet: View {
  let sources: [MacAnswerSource]

  @Environment(\.dismiss) private var dismiss
  @State private var copiedSourceID: String?
  @State private var copiedAll = false
  @State private var copyFeedbackRevision = 0

  init(sources: [MacAnswerSource]) {
    self.sources = sources
  }

  var body: some View {
    VStack(spacing: 0) {
      headerBar

      Divider()

      if sources.isEmpty {
        ContentUnavailableView(
          "No Sources",
          systemImage: "link",
          description: Text("This response doesn't include any web links.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
              MacAnswerSourceRow(
                index: index + 1,
                source: source,
                isCopied: copiedSourceID == source.id,
                open: { openSource(source) },
                copy: { copySource(source) }
              )
            }
          }
          .padding(16)
        }
      }
    }
    .frame(
      minWidth: 500,
      idealWidth: MacDesignTokens.Sheet.standardWidth,
      minHeight: 340,
      idealHeight: MacDesignTokens.Sheet.standardHeight
    )
    .background(MacDesignTokens.Colors.canvas)
    .task(id: copyFeedbackRevision) {
      guard copyFeedbackRevision > 0 else { return }
      try? await Task.sleep(for: .seconds(1.4))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.16)) {
        copiedSourceID = nil
        copiedAll = false
      }
    }
  }

  private var headerBar: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Sources")
          .font(.headline)
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)

        Text(sources.count == 1 ? "1 link" : "\(sources.count) links")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      Spacer(minLength: 8)

      if !sources.isEmpty {
        Button {
          copyAllSources()
        } label: {
          Label(
            copiedAll ? "Copied All" : "Copy All",
            systemImage: copiedAll ? "checkmark" : "doc.on.doc"
          )
          .font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(MacSecondaryButtonStyle())
        .help("Copy all source URLs")
      }

      Button("Done") { dismiss() }
        .buttonStyle(MacActionButtonStyle(.secondary, size: .small))
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func openSource(_ source: MacAnswerSource) {
    guard MacAnswerContentParser.isValidBrowsableURL(source.url) else { return }
    NSWorkspace.shared.open(source.url)
  }

  private func copySource(_ source: MacAnswerSource) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(source.url.absoluteString, forType: .string)
    withAnimation(.easeOut(duration: 0.16)) {
      copiedAll = false
      copiedSourceID = source.id
    }
    copyFeedbackRevision += 1
  }

  private func copyAllSources() {
    let payload = sources.map(\.url.absoluteString).joined(separator: "\n")
    guard !payload.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(payload, forType: .string)
    withAnimation(.easeOut(duration: 0.16)) {
      copiedSourceID = nil
      copiedAll = true
    }
    copyFeedbackRevision += 1
  }
}

private struct MacAnswerSourceRow: View {
  let index: Int
  let source: MacAnswerSource
  let isCopied: Bool
  let open: () -> Void
  let copy: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 11) {
      Button(action: open) {
        HStack(spacing: 11) {
          Text("\(index)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(MacDesignTokens.Colors.accent)
            .frame(width: 24, height: 24)
            .background(MacDesignTokens.Colors.accent.opacity(0.14), in: Circle())

          VStack(alignment: .leading, spacing: 2) {
            Text(source.displayTitle)
              .font(.system(size: 13.5, weight: .semibold))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .lineLimit(1)

            HStack(spacing: 5) {
              Text(source.host)
                .font(.caption.weight(.medium))
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .lineLimit(1)

              if source.url.absoluteString != source.host {
                Text("·")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.6))
                Text(source.url.absoluteString)
                  .font(.caption2)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.8))
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
            }
          }

          Spacer(minLength: 6)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open \(source.url.absoluteString) in browser")

      HStack(spacing: 4) {
        Button(isCopied ? "Copied" : "Copy URL", systemImage: isCopied ? "checkmark" : "doc.on.doc") {
          copy()
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isCopied ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted)
        .buttonStyle(MacIconButtonStyle())
        .help(isCopied ? "Copied URL" : "Copy URL")

        Button("Open in Browser", systemImage: "arrow.up.right") {
          open()
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
        .buttonStyle(MacIconButtonStyle())
        .help("Open in browser")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      isHovered
        ? MacDesignTokens.Colors.selection.opacity(0.45)
        : MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(isHovered ? 0.95 : 0.7), lineWidth: 0.75)
    }
    .onHover { isHovered = $0 }
    .animation(
      .easeOut(duration: MacDesignTokens.Control.interactionDuration),
      value: isHovered
    )
    .contextMenu {
      Button("Open in Browser", systemImage: "arrow.up.right") {
        open()
      }
      Button("Copy URL", systemImage: "doc.on.doc") {
        copy()
      }
    }
  }
}
