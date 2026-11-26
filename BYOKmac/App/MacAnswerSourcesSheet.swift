import AppKit
import SwiftUI

struct MacAnswerSourcesPopover: View {
  let sources: [MacAnswerSource]
  let onDismiss: () -> Void

  @Environment(\.macAppTheme) private var theme
  @State private var copiedSourceID: String?
  @State private var copiedAll = false
  @State private var copyFeedbackRevision = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      headerBar

      Rectangle()
        .fill(theme.separator.opacity(0.75))
        .frame(height: 1)

      if sources.count > 6 {
        ScrollView {
          sourceRows
        }
        .frame(maxHeight: 340)
      } else {
        sourceRows
      }
    }
    .frame(width: 356, alignment: .leading)
    .background(theme.surface)
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
    HStack(spacing: 6) {
      Text("Sources")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.textPrimary)

      Text("·")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(theme.textMuted.opacity(0.6))

      Text("\(sources.count)")
        .font(.system(size: 11.5, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(theme.textMuted)

      Spacer(minLength: 8)

      if !sources.isEmpty {
        MacSourcesCopyAllButton(isCopied: copiedAll) {
          copyAllSources()
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
  }

  private var sourceRows: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
        MacAnswerSourcePopoverRow(
          index: index + 1,
          source: source,
          isCopied: copiedSourceID == source.id,
          open: { openSource(source) },
          copy: { copySource(source) }
        )
      }
    }
    .padding(6)
  }

  private func openSource(_ source: MacAnswerSource) {
    guard MacAnswerContentParser.isValidBrowsableURL(source.url) else { return }
    NSWorkspace.shared.open(source.url)
    onDismiss()
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

private struct MacSourcesCopyAllButton: View {
  let isCopied: Bool
  let action: () -> Void

  @Environment(\.macAppTheme) private var theme
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 10.5, weight: .semibold))
        Text(isCopied ? "Copied" : "Copy All")
          .font(.system(size: 11, weight: .medium))
      }
      .foregroundStyle(isCopied ? theme.accent : (isHovered ? theme.textPrimary : theme.textMuted))
      .padding(.horizontal, 7)
      .padding(.vertical, 3.5)
      .background(
        isHovered ? theme.selection.opacity(0.6) : Color.clear,
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
      .contentShape(
        RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .help("Copy all source URLs")
  }
}

private struct MacAnswerSourcePopoverRow: View {
  let index: Int
  let source: MacAnswerSource
  let isCopied: Bool
  let open: () -> Void
  let copy: () -> Void

  @Environment(\.macAppTheme) private var theme
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 9) {
      Button(action: open) {
        HStack(spacing: 9) {
          Text("\(index)")
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(theme.accent)
            .frame(width: 20, height: 20)
            .background(theme.accent.opacity(0.13), in: Circle())

          VStack(alignment: .leading, spacing: 1.5) {
            Text(source.displayTitle)
              .font(.system(size: 12.5, weight: .medium))
              .foregroundStyle(theme.textPrimary)
              .lineLimit(1)
              .truncationMode(.tail)

            subtitleView

            if let snippet = source.snippet, !snippet.isEmpty {
              Text(snippet)
                .font(.system(size: 11))
                .foregroundStyle(theme.textMuted.opacity(0.85))
                .lineLimit(2)
                .padding(.top, 1)
            }
          }

          Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open \(source.url.absoluteString)")

      if isHovered || isCopied {
        Button(isCopied ? "Copied" : "Copy URL", systemImage: isCopied ? "checkmark" : "doc.on.doc") {
          copy()
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(isCopied ? theme.accent : theme.textMuted)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .help(isCopied ? "Copied URL" : "Copy URL")
      } else {
        Image(systemName: "arrow.up.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(theme.textMuted.opacity(0.55))
          .frame(width: 24, height: 24)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6.5)
    .background(
      isHovered ? theme.selection.opacity(0.55) : Color.clear,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
    )
    .contentShape(
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
    )
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

  @ViewBuilder
  private var subtitleView: some View {
    if source.hasDistinctTitle {
      HStack(spacing: 4) {
        Text(source.host)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(theme.textMuted)
          .lineLimit(1)
          .layoutPriority(1)

        if let path = source.displayPath {
          Text("·")
            .font(.system(size: 11))
            .foregroundStyle(theme.textMuted.opacity(0.55))
          Text(path)
            .font(.system(size: 11))
            .foregroundStyle(theme.textMuted.opacity(0.8))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    } else if let path = source.displayPath {
      Text(path)
        .font(.system(size: 11))
        .foregroundStyle(theme.textMuted)
        .lineLimit(1)
        .truncationMode(.middle)
    } else {
      Text(source.url.absoluteString)
        .font(.system(size: 11))
        .foregroundStyle(theme.textMuted.opacity(0.85))
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

struct MacInlineCitationChipsRow: View {
  let sources: [MacAnswerSource]

  @Environment(\.macAppTheme) private var theme
  @State private var showingAllPopover = false

  private static let maxVisibleChips = 4

  var body: some View {
    let visible = Array(sources.prefix(Self.maxVisibleChips))
    let overflowCount = max(0, sources.count - visible.count)

    HStack(spacing: 6) {
      ForEach(Array(visible.enumerated()), id: \.element.id) { index, source in
        MacInlineCitationChip(index: index + 1, source: source)
      }

      if overflowCount > 0 {
        Button {
          showingAllPopover.toggle()
        } label: {
          Text("+\(overflowCount) more")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(showingAllPopover ? theme.textPrimary : theme.textMuted)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
              showingAllPopover ? theme.selection.opacity(0.65) : theme.surface,
              in: Capsule()
            )
            .overlay {
              Capsule()
                .stroke(theme.separator.opacity(0.75), lineWidth: 0.65)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingAllPopover, arrowEdge: .bottom) {
          MacAnswerSourcesPopover(sources: sources) {
            showingAllPopover = false
          }
          .presentationBackground(theme.surface)
        }
      }
    }
  }
}

private struct MacInlineCitationChip: View {
  let index: Int
  let source: MacAnswerSource

  @Environment(\.macAppTheme) private var theme
  @State private var isHovered = false

  var body: some View {
    Button {
      guard MacAnswerContentParser.isValidBrowsableURL(source.url) else { return }
      NSWorkspace.shared.open(source.url)
    } label: {
      HStack(spacing: 5) {
        Text("\(index)")
          .font(.system(size: 9.5, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(theme.accent)
          .frame(width: 15, height: 15)
          .background(theme.accent.opacity(0.14), in: Circle())

        Text(source.host)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(isHovered ? theme.textPrimary : theme.textMuted)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.leading, 4)
      .padding(.trailing, 8)
      .frame(height: 24)
      .frame(maxWidth: 168)
      .background(
        isHovered ? theme.selection.opacity(0.65) : theme.surface,
        in: Capsule()
      )
      .overlay {
        Capsule()
          .stroke(
            isHovered ? theme.accent.opacity(0.45) : theme.separator.opacity(0.75),
            lineWidth: 0.65
          )
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: MacDesignTokens.Control.interactionDuration), value: isHovered)
    .help(tooltipText)
  }

  private var tooltipText: String {
    if let snippet = source.snippet, !snippet.isEmpty {
      return "\(source.displayTitle) — \(snippet)"
    }
    return "\(source.displayTitle) (\(source.url.absoluteString))"
  }
}
