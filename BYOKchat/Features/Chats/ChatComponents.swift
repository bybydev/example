import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI
import UIKit

struct RepairBanner: View {
  let message: String
  let repair: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(message, systemImage: "wrench.and.screwdriver")
        .font(.callout)
      Button("Repair Chat Configuration", action: repair)
        .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    .accessibilityElement(children: .combine)
  }
}

enum ChatAttachmentPresentation {
  case composer
  case message
  /// Tiles rendered inside a merged user-message bubble.
  case bubble

  var imageWidth: CGFloat {
    switch self {
    case .composer: 104
    case .message, .bubble: 112
    }
  }

  var imageHeight: CGFloat {
    switch self {
    case .composer: 86
    case .message, .bubble: 112
    }
  }

  var railHeight: CGFloat {
    switch self {
    case .composer: imageHeight + 8
    case .message, .bubble: imageHeight
    }
  }

  var fileWidth: CGFloat {
    switch self {
    case .composer: 122
    case .message, .bubble: 132
    }
  }

  var cornerRadius: CGFloat {
    switch self {
    case .composer: 16
    case .message: 20
    case .bubble: 14
    }
  }
}

struct ChatAttachmentStrip: View {
  let attachments: [ChatAttachment]
  var presentation: ChatAttachmentPresentation = .message
  var removeAttachment: ((String) -> Void)?
  var pickPhoto: (() -> Void)?
  var pickFile: (() -> Void)?
  var pickFromLibrary: (() -> Void)? = nil
  var projectFiles: [ProjectFile] = []
  var attachProjectFile: ((ProjectFile) -> Void)? = nil
  var maxAttachments: Int = ChatComposerLayoutPolicy.maxAttachmentCount
  var isImportingAttachments: Bool = false
  /// Message-surface hook adding a Library reference to an already-stored
  /// file (+1, no byte copy). Nil hides the tile menu.
  var saveToLibrary: ((ChatAttachment) -> Void)? = nil
  /// Async byte/thumbnail access for already-persisted attachments (the
  /// remote-image model: tiles fetch on demand). Composer tiles hold fresh
  /// in-memory bytes and can render without it.
  var loadThumbnail: ((String, CGFloat) async -> Data?)? = nil

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    if hugsContent {
      tileList
        .frame(height: presentation.railHeight)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      ScrollView(.horizontal) {
        tileList
          .padding(.vertical, presentation == .composer ? 4 : 0)
      }
      .frame(height: presentation.railHeight)
      .fixedSize(horizontal: false, vertical: true)
      .scrollIndicators(.hidden)
      // Keep tiles clipped inside the merged bubble instead of bleeding past
      // its edges while rubber-banding.
      .scrollClipDisabled(presentation != .bubble)
    }
  }

  private var hugsContent: Bool {
    guard presentation == .bubble, !attachments.isEmpty else { return false }
    let gaps = CGFloat(10 * (attachments.count - 1))
    let tiles = attachments.reduce(CGFloat(0)) {
      $0 + ($1.isImage ? presentation.imageWidth : presentation.fileWidth)
    }
    return tiles + gaps <= 240
  }

  private var tileList: some View {
    LazyHStack(spacing: 10) {
      ForEach(attachments) { attachment in
        attachmentView(attachment)
      }

      if presentation == .composer,
        attachments.count < maxAttachments,
        let pickPhoto,
        let pickFile
      {
        addAttachmentTile(pickPhoto: pickPhoto, pickFile: pickFile)
      }
    }
  }

  @ViewBuilder
  private func attachmentView(_ attachment: ChatAttachment) -> some View {
    ZStack(alignment: .topTrailing) {
      if attachment.isImage {
        AsyncAttachmentThumbnail(
          attachment: attachment,
          sideLength: presentation.imageWidth,
          height: presentation.imageHeight,
          cornerRadius: presentation.cornerRadius,
          loadThumbnail: loadThumbnail
        )
        .accessibilityLabel("Image attachment \(attachment.filename)")
      } else {
        fileTile(attachment)
      }

      if let removeAttachment {
        Button {
          removeAttachment(attachment.id)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 27, height: 27)
            .background(.black.opacity(0.62), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.32), lineWidth: 0.5))
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(attachment.filename)")
      }
    }
    .contextMenu { tileContextItems(for: attachment) }
  }

  @ViewBuilder
  private func tileContextItems(for attachment: ChatAttachment) -> some View {
    if presentation == .composer, let removeAttachment {
      Button(role: .destructive) {
        removeAttachment(attachment.id)
      } label: {
        Label("Remove", systemImage: "trash")
      }
    } else if presentation == .message || presentation == .bubble, let saveToLibrary {
      Button {
        saveToLibrary(attachment)
      } label: {
        Label("Save to Library", systemImage: "books.vertical")
      }
    }
  }

  private func fileTile(_ attachment: ChatAttachment) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Image(systemName: fileSymbol(for: attachment))
        .font(.system(size: presentation == .composer ? 22 : 25, weight: .semibold))
        .foregroundStyle(theme.accentColor)

      Spacer(minLength: 0)

      Text(attachment.filename)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.primaryForegroundColor)
        .lineLimit(2)

      Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .padding(11)
    .frame(
      width: presentation.fileWidth,
      height: presentation.imageHeight,
      alignment: .leading
    )
    .background(theme.surfaceColor, in: tileShape)
    .overlay(tileShape.stroke(theme.borderColor, lineWidth: 0.75))
    .accessibilityElement(children: .combine)
  }

  private func addAttachmentTile(
    pickPhoto: @escaping () -> Void,
    pickFile: @escaping () -> Void
  ) -> some View {
    Menu {
      Button("Photo", systemImage: "photo", action: pickPhoto)
      Button("File", systemImage: "doc", action: pickFile)
      if let pickFromLibrary {
        Button("From Library…", systemImage: "books.vertical", action: pickFromLibrary)
      }
      if !projectFiles.isEmpty, let attachProjectFile {
        let attachedIDs = Set(attachments.map(\.id))
        Menu("Project Files", systemImage: "folder.badge.plus") {
          ForEach(projectFiles) { file in
            let isAttached = attachedIDs.contains(file.id)
            Button {
              attachProjectFile(file)
            } label: {
              if isAttached {
                Label(file.filename, systemImage: "checkmark")
              } else {
                Text(file.filename)
              }
            }
            .disabled(isAttached)
          }
        }
      }
    } label: {
      VStack(spacing: 7) {
        if isImportingAttachments {
          ProgressView()
            .controlSize(.small)
            .tint(theme.secondaryForegroundColor)
        } else {
          Image(systemName: "plus")
            .font(.system(size: 20, weight: .semibold))
        }
        Text(isImportingAttachments ? "Adding" : "Add")
          .font(.system(size: 11, weight: .semibold))
      }
      .foregroundStyle(theme.secondaryForegroundColor)
      .frame(width: 76, height: presentation.imageHeight)
      .background(theme.surfaceColor.opacity(0.72), in: tileShape)
      .overlay(
        tileShape
          .stroke(theme.borderColor, style: StrokeStyle(lineWidth: 0.75, dash: [5, 4]))
      )
    }
    .buttonStyle(.plain)
    .disabled(isImportingAttachments)
    .accessibilityLabel(isImportingAttachments ? "Importing attachment" : "Add another attachment")
  }

  private var tileShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
  }

  private func fileSymbol(for attachment: ChatAttachment) -> String {
    let mime = attachment.mimeType.lowercased()
    if mime.contains("pdf") { return "doc.richtext.fill" }
    if mime.contains("json") || mime.contains("javascript") { return "curlybraces.square.fill" }
    if attachment.isTextLike { return "doc.text.fill" }
    return "doc.fill"
  }
}

/// Async image tile for an attachment — the remote-image pattern: the row
/// holds ID + metadata only, the view fetches a downsampled thumbnail and
/// shows a placeholder while loading and an explicit unavailable state when
/// the blob is gone. Bytes in hand (composer tiles, fresh imports) render
/// directly without a fetch.
struct AsyncAttachmentThumbnail: View {
  let attachment: ChatAttachment
  var sideLength: CGFloat
  var height: CGFloat
  var cornerRadius: CGFloat
  /// Async fetcher for persisted blobs (id, maxPixelSize) → downsampled
  /// bytes. Nil means only in-memory bytes can be shown.
  var loadThumbnail: ((String, CGFloat) async -> Data?)? = nil

  @Environment(\.appFoundationTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?
  /// Distinguishes "still loading" from "confirmed missing" once a fetch has
  /// completed without bytes.
  @State private var isUnavailable = false

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: sideLength, height: height)
          .clipShape(shape)
          .overlay(shape.stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75))
      } else if isUnavailable {
        unavailableTile
      } else if attachment.data.isEmpty {
        loadingTile
      } else {
        // Bytes are in memory but not decodable as an image; show the file tile.
        nonImageTile
      }
    }
    .frame(width: sideLength, height: height)
    .task(id: attachment.id) {
      await load()
    }
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
  }

  private var loadingTile: some View {
    ZStack {
      theme.surfaceColor
      ProgressView()
        .tint(theme.secondaryForegroundColor)
    }
    .clipShape(shape)
    .overlay(shape.stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75))
  }

  private var unavailableTile: some View {
    ZStack {
      theme.surfaceColor
      VStack(spacing: 5) {
        Image(systemName: "photo.badge.exclamationmark")
          .font(.system(size: sideLength * 0.24, weight: .medium))
        Text("Unavailable")
          .font(.system(size: 9, weight: .medium))
      }
      .foregroundStyle(theme.secondaryForegroundColor)
    }
    .clipShape(shape)
    .overlay(shape.stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75))
    .accessibilityLabel("Image attachment \(attachment.filename) is unavailable")
  }

  private var nonImageTile: some View {
    ZStack {
      theme.surfaceColor
      Image(systemName: "photo")
        .font(.system(size: sideLength * 0.3, weight: .medium))
        .foregroundStyle(theme.secondaryForegroundColor)
    }
    .clipShape(shape)
    .overlay(shape.stroke(theme.borderColor.opacity(0.8), lineWidth: 0.75))
  }

  private func load() async {
    let targetPixelSize = max(sideLength, height) * displayScale
    let attachmentID = attachment.id
    let inlineData = attachment.data

    // Fresh in-memory bytes (composer, just-imported) decode directly.
    if !inlineData.isEmpty {
      isUnavailable = false
      let inlineKey = "inline::\(attachmentID)"
      if let cached = AttachmentThumbnailLoader.cachedImage(
        cacheKey: inlineKey,
        maxPixelSize: targetPixelSize
      ) {
        image = cached
        return
      }
      let decoded = await Task.detached(priority: .userInitiated) {
        AttachmentThumbnailLoader.downsampledImage(
          from: inlineData,
          cacheKey: inlineKey,
          maxPixelSize: targetPixelSize
        )
      }.value
      guard !Task.isCancelled else { return }
      image = decoded
      if decoded != nil { return }
    }
    guard let loadThumbnail else {
      // No fetcher wired (fresh mode): in-memory bytes were the only source.
      isUnavailable = inlineData.isEmpty
      return
    }
    let blobKey = "blob::\(attachmentID)"
    if let cached = AttachmentThumbnailLoader.cachedImage(
      cacheKey: blobKey,
      maxPixelSize: targetPixelSize
    ) {
      isUnavailable = false
      image = cached
      return
    }
    let bytes = await loadThumbnail(attachmentID, targetPixelSize)
    guard !Task.isCancelled else { return }
    guard let bytes, !bytes.isEmpty else {
      isUnavailable = true
      return
    }
    let decoded = await Task.detached(priority: .userInitiated) {
      AttachmentThumbnailLoader.downsampledImage(
        from: bytes,
        cacheKey: blobKey,
        maxPixelSize: targetPixelSize
      )
    }.value
    guard !Task.isCancelled else { return }
    image = decoded
    isUnavailable = decoded == nil
  }
}

struct ChatMessageView: View {
  let message: ChatMessage
  let accountLabel: String?
  /// Identity line for remote failures, e.g. "Work · OpenAI · gpt-4o".
  /// Local failures pass nil so the error stands alone above its Retry pill.
  var failureContext: String? = nil
  let canEdit: Bool
  let canRegenerate: Bool
  /// Library saving ("Save to Library" / "Save Images…") is only offered when
  /// both are provided.
  var conversationID: ConversationID? = nil
  var library: LibraryManagementModel? = nil
  var onLibraryError: ((Error) -> Void)? = nil
  /// Async thumbnail fetch for persisted attachment blobs (nil hides the
  /// loading/unavailable pipeline; only in-memory bytes render).
  var loadThumbnail: ((String, CGFloat) async -> Data?)? = nil
  let edit: () -> Void
  let regenerate: () -> Void
  let copy: () -> Void

  @Environment(\.appFoundationTheme) private var theme
  @Environment(BYOKToastCenter.self) private var toastCenter
  @State private var showReasoningSheet = false
  @State private var showMessageInfo = false
  @State private var showSourcesSheet = false
  @State private var showImageSaveSheet = false
  @State private var pendingSavedImageCount = 0

  private var imageCandidates: [ResponseImageCandidate] {
    guard library != nil, conversationID != nil, !message.content.isEmpty else { return [] }
    return ResponseImageScanner.imageCandidates(in: message.content)
  }

  var body: some View {
    Group {
      if message.role == .user {
        userMessage
      } else {
        assistantMessage
      }
    }
    .foregroundStyle(theme.primaryForegroundColor)
    .accessibilityElement(children: .contain)
  }

  private var userMessage: some View {
    HStack(alignment: .top) {
      Spacer(minLength: 54)
      userBubble
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .contextMenu {
      if !message.content.isEmpty {
        Button("Copy", systemImage: "doc.on.doc", action: copy)
        ShareLink(item: message.content) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
      }
      if canEdit {
        Button("Edit and Resend", systemImage: "pencil", action: edit)
      }
    }
  }

  /// Media and text share one continuous capsule so attachments hug the same
  /// edge as the message instead of stretching edge-to-edge on their own.
  @ViewBuilder
  private var userBubble: some View {
    let attachments = message.attachments ?? []
    let hasMedia = !attachments.isEmpty
    let hasText = !message.content.isEmpty

    VStack(alignment: .leading, spacing: hasMedia && hasText ? 9 : 0) {
      if hasMedia {
        ChatAttachmentStrip(
          attachments: attachments,
          presentation: .bubble,
          saveToLibrary: attachmentSaveClosure,
          loadThumbnail: loadThumbnail
        )
      }

      if hasText {
        MarkdownMessageContent(text: message.content, fillsWidth: false)
      }
    }
    .padding(.horizontal, 15)
    .padding(.vertical, hasMedia ? 8 : 11)
    .background(theme.elevatedSurfaceColor, in: userBubbleShape)
    .overlay(userBubbleShape.stroke(theme.borderColor, lineWidth: 0.5))
  }

  private var userBubbleShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 22, style: .continuous)
  }

  /// Save-to-Library is offered on sent attachments only when library context
  /// exists; the closure adds a Library reference without copying bytes.
  private var attachmentSaveClosure: ((ChatAttachment) -> Void)? {
    guard conversationID != nil, library != nil else { return nil }
    return { attachment in
      guard let conversationID, let library else { return }
      Task {
        let saved = await library.ensureListed(
          fileID: attachment.id,
          filename: attachment.filename,
          mimeType: attachment.mimeType,
          byteCount: attachment.byteCount,
          source: .chat(conversationID: conversationID, messageID: message.id),
          onError: onLibraryError
        )
        if saved != nil { toastCenter.success("Saved to Library") }
      }
    }
  }

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: 10) {
      messageBody

      if message.status == .failed {
        // The failure footer owns the retry action, so failed turns never
        // render the icon row with its dead copy/share buttons.
        failureFooter
      } else {
        footer

        if message.status != .pending && message.status != .streaming {
          assistantActions
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .sheet(isPresented: $showMessageInfo) {
      MessageInfoView(message: message, accountLabel: accountLabel)
    }
    .sheet(isPresented: $showReasoningSheet) {
      ReasoningSheet(reasoning: message.reasoning)
    }
    .sheet(isPresented: $showSourcesSheet) {
      AnswerSourcesSheet(sources: messageSources)
    }
    .sheet(isPresented: $showImageSaveSheet, onDismiss: {
      guard pendingSavedImageCount > 0 else { return }
      let count = pendingSavedImageCount
      pendingSavedImageCount = 0
      toastCenter.success(count == 1 ? "Image saved to Library" : "\(count) images saved to Library")
    }) {
      if let conversationID, let library {
        ResponseImageSaveSheet(
          candidates: imageCandidates,
          conversationID: conversationID,
          messageID: message.id,
          library: library,
          onSaved: { pendingSavedImageCount = $0 }
        )
      }
    }
  }


  /// Links extracted from the answer body. They stay tappable inline in the
  /// markdown; this list is the consolidated index behind the More menu.
  private var messageSources: [AnswerSource] {
    guard message.role == .assistant, !message.content.isEmpty else { return [] }
    return AnswerContentParser.sources(in: AnswerContentParser.parse(message.content))
  }

  private var assistantActions: some View {
    HStack(spacing: 2) {
      CopyButton(text: message.content, size: .messageAction, alignment: .leading)

      actionButton("Retry", systemImage: "arrow.clockwise", action: regenerate)
        .disabled(!canRegenerate)

      ShareLink(item: message.content) {
        Image(systemName: "square.and.arrow.up")
          .frame(
            width: CopyButton.Size.messageAction.width,
            height: CopyButton.Size.messageAction.height,
            alignment: .leading
          )
          .contentShape(Rectangle())
      }
      .disabled(message.content.isEmpty)
      .accessibilityLabel("Share")

      Menu {
        Button("Message Info", systemImage: "info.circle") {
          showMessageInfo = true
        }
        if !messageSources.isEmpty {
          Button("Sources", systemImage: "link") {
            showSourcesSheet = true
          }
        }
        if !message.reasoning.isEmpty {
          Button("Copy Reasoning", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = message.reasoning
          }
        }
        libraryActions
      } label: {
        Image(systemName: "ellipsis")
          .frame(
            width: CopyButton.Size.messageAction.width,
            height: CopyButton.Size.messageAction.height,
            alignment: .leading
          )
          .contentShape(Rectangle())
      }
      .accessibilityLabel("More")
    }
    .font(.system(size: 17))
    .foregroundStyle(theme.secondaryForegroundColor)
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Save-into-library actions. Rendered inside the More menu only when the
  /// caller provided library context.
  @ViewBuilder
  private var libraryActions: some View {
    if let conversationID, let library {
      Button("Save to Library", systemImage: "books.vertical") {
        Task { @MainActor in
          // Locale-independent stamp keeps generated filenames predictable.
          let parts = Calendar.current.dateComponents([.year, .month, .day], from: message.createdAt)
          let name =
            "Response-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0).md"
          let saved = await library.addAttachment(
            ChatAttachment(
              kind: .file,
              filename: name,
              mimeType: "text/markdown",
              data: Data(message.content.utf8)
            ),
            source: .chat(conversationID: conversationID, messageID: message.id),
            onError: onLibraryError
          )
          if saved != nil { toastCenter.success("Saved to Library") }
        }
      }
      .disabled(message.content.isEmpty)

      if !imageCandidates.isEmpty {
        Button("Save Images…", systemImage: "photo.on.rectangle") {
          showImageSaveSheet = true
        }
      }
    }
  }

  @ViewBuilder
  private var messageBody: some View {
    if shouldShowReasoningDisclosure {
      reasoningDisclosure
    }

    if let attachments = message.attachments, !attachments.isEmpty {
      ChatAttachmentStrip(
        attachments: attachments,
        presentation: .message,
        saveToLibrary: attachmentSaveClosure,
        loadThumbnail: loadThumbnail
      )
    }

    if !message.content.isEmpty {
      MarkdownMessageContent(text: message.content)
    }
  }

  private var shouldShowReasoningDisclosure: Bool {
    !message.reasoning.isEmpty || isReasoningActive
  }

  private var isReasoningActive: Bool {
    (message.status == .pending || message.status == .streaming) && message.content.isEmpty
  }

  private var reasoningDisclosure: some View {
    Button {
      guard !message.reasoning.isEmpty else { return }
      showReasoningSheet = true
    } label: {
      HStack(spacing: 8) {
        if isReasoningActive {
          Text("Thinking…")
            .phaseAnimator([false, true]) { content, phase in
              content.opacity(phase ? 0.45 : 1)
            } animation: { _ in
              .easeInOut(duration: 0.8)
            }
        } else {
          Text("Reasoning")
        }

        Spacer(minLength: 8)

        if !message.reasoning.isEmpty {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
        }
      }
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(theme.secondaryForegroundColor)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(message.reasoning.isEmpty)
    .accessibilityLabel(isReasoningActive ? "Thinking" : "Reasoning")
    .accessibilityHint(message.reasoning.isEmpty ? "" : "Opens reasoning in a sheet")
  }

  private func actionButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .frame(
          width: CopyButton.Size.messageAction.width,
          height: CopyButton.Size.messageAction.height,
          alignment: .leading
        )
        .contentShape(Rectangle())
    }
    .accessibilityLabel(title)
  }

  @ViewBuilder
  private var footer: some View {
    switch message.status {
    case .failed:
      failureFooter
    case .cancelled:
      Label("Stopped", systemImage: "stop.circle")
        .font(.system(size: 11))
        .foregroundStyle(theme.secondaryForegroundColor)
    case .interrupted:
      Label("Interrupted", systemImage: "bolt.slash")
        .font(.system(size: 11))
        .foregroundStyle(.orange)
    case .complete, .pending, .streaming:
      EmptyView()
    }
  }

  @ViewBuilder
  private var failureFooter: some View {
    let description = message.errorDescription ?? "Something went wrong. Try again."

    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.circle.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.orange)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 8) {
        if let failureContext, !failureContext.isEmpty {
          Text(failureContext)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.secondaryForegroundColor.opacity(0.82))
        }

        Text(description)
          .font(.system(size: 13))
          .foregroundStyle(theme.secondaryForegroundColor)
          .fixedSize(horizontal: false, vertical: true)

        Button(action: regenerate) {
          Label("Retry", systemImage: "arrow.clockwise")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(canRegenerate ? theme.accentColor : theme.secondaryForegroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(theme.surfaceColor, in: Capsule())
            .overlay(Capsule().stroke(theme.borderColor, lineWidth: 0.75))
            .opacity(canRegenerate ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!canRegenerate)
        .accessibilityLabel("Retry")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 2)
  }
}

struct MessageEditorSheet: View {
  let original: String
  @Binding var text: String
  let save: () -> Void
  let cancel: () -> Void

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextEditor(text: $text)
            .font(.system(size: 17))
            .frame(minHeight: 220)
        } footer: {
          Text("Saving removes every later message and generates a new response in linear history.")
            .foregroundStyle(theme.secondaryForegroundColor)
        }
        .listRowBackground(theme.surfaceColor)
      }
      .scrollContentBackground(.hidden)
      .foregroundStyle(theme.primaryForegroundColor)
      .background(AppThemeBackground(theme: theme))
      .navigationTitle("Edit Message")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: cancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save & Resend", action: save)
            .disabled(
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == original
            )
        }
      }
    }
  }
}
