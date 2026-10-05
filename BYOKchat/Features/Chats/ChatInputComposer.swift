import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

enum ChatComposerActivity: Equatable {
  case idle
  case generating
  case creating

  var isBusy: Bool {
    self != .idle
  }
}

enum ChatComposerLayoutPolicy {
  static let textOnlyVisibleLineCap = 6
  static let attachmentVisibleLineCap = 3

  static func visibleTextLineCap(hasAttachments: Bool) -> Int {
    hasAttachments ? attachmentVisibleLineCap : textOnlyVisibleLineCap
  }

  static func shouldUseCompact(
    isFocused: Bool,
    draftIsEmpty: Bool,
    hasAttachments: Bool,
    activity: ChatComposerActivity
  ) -> Bool {
    !isFocused && draftIsEmpty && !hasAttachments && activity == .idle
  }
}

struct ChatComposer: View {
  @Binding var draft: String
  let attachments: [ChatAttachment]
  let activity: ChatComposerActivity
  let canSend: Bool
  let targetSummary: String
  let targetDetails: String
  let openTarget: () -> Void
  let pickPhoto: () -> Void
  let pickFile: () -> Void
  /// Presents the attach-from-library picker. Hidden from the menu when nil.
  var pickFromLibrary: (() -> Void)?
  let projectFiles: [ProjectFile]
  let attachProjectFile: (ProjectFile) -> Void
  let removeAttachment: (String) -> Void
  let send: () -> Void
  let stop: (() -> Void)?

  private let targetPickerConversation: ChatConversation?
  private let targetPickerChats: ChatManagementModel?
  private let targetPickerProviders: ProviderManagementModel?

  @Environment(\.appFoundationTheme) private var theme
  @FocusState private var isEditorFocused: Bool
  @State private var measuredContentHeight: CGFloat = 0
  @State private var showTargetPicker = false

  private static let messageLineHeight: CGFloat = 22
  private static let compactContentHeight: CGFloat = 50
  private static let minimumExpandedContentHeight: CGFloat = 54
  private static let textAnchor = "chat-composer-text"

  init(
    draft: Binding<String>,
    attachments: [ChatAttachment],
    activity: ChatComposerActivity,
    canSend: Bool,
    targetSummary: String,
    targetDetails: String,
    openTarget: @escaping () -> Void,
    pickPhoto: @escaping () -> Void,
    pickFile: @escaping () -> Void,
    pickFromLibrary: (() -> Void)? = nil,
    projectFiles: [ProjectFile] = [],
    attachProjectFile: @escaping (ProjectFile) -> Void = { _ in },
    removeAttachment: @escaping (String) -> Void,
    send: @escaping () -> Void,
    stop: (() -> Void)? = nil
  ) {
    _draft = draft
    self.attachments = attachments
    self.activity = activity
    self.canSend = canSend
    self.targetSummary = targetSummary
    self.targetDetails = targetDetails
    self.openTarget = openTarget
    self.pickPhoto = pickPhoto
    self.pickFile = pickFile
    self.pickFromLibrary = pickFromLibrary
    self.projectFiles = projectFiles
    self.attachProjectFile = attachProjectFile
    self.removeAttachment = removeAttachment
    self.send = send
    self.stop = stop
    targetPickerConversation = nil
    targetPickerChats = nil
    targetPickerProviders = nil
  }

  init(
    draft: Binding<String>,
    attachments: [ChatAttachment],
    isGenerating: Bool,
    canSend: Bool,
    conversation: ChatConversation,
    chats: ChatManagementModel,
    providers: ProviderManagementModel,
    openChatSettings: @escaping () -> Void,
    pickPhoto: @escaping () -> Void,
    pickFile: @escaping () -> Void,
    pickFromLibrary: (() -> Void)? = nil,
    projectFiles: [ProjectFile] = [],
    attachProjectFile: @escaping (ProjectFile) -> Void = { _ in },
    removeAttachment: @escaping (String) -> Void,
    send: @escaping () -> Void,
    stop: @escaping () -> Void
  ) {
    _draft = draft
    self.attachments = attachments
    activity = isGenerating ? .generating : .idle
    self.canSend = canSend

    let account = providers.accounts.first { $0.id == conversation.accountID }
    let model = providers.models(for: conversation.accountID, includeHidden: true)
      .first { $0.model.id == conversation.modelID }?.model
    let providerName = providers.provider(for: conversation.providerID)?.displayName
      ?? account?.label
      ?? conversation.providerID.rawValue

    targetSummary = ComposerTargetLabelFormatter.make(
      providerID: conversation.providerID,
      providerName: providerName,
      modelName: model?.displayName ?? conversation.modelID.rawValue,
      modelID: conversation.modelID.rawValue,
      supportedParameters: model?.supportedParameters ?? [],
      reasoning: conversation.options.reasoning,
      capabilities: providers.capabilities(accountID: conversation.accountID, modelID: conversation.modelID)
    )
    targetDetails = "\(account?.label ?? providerName) · \(model?.displayName ?? conversation.modelID.rawValue)"
    openTarget = openChatSettings
    self.pickPhoto = pickPhoto
    self.pickFile = pickFile
    self.pickFromLibrary = pickFromLibrary
    self.projectFiles = projectFiles
    self.attachProjectFile = attachProjectFile
    self.removeAttachment = removeAttachment
    self.send = send
    self.stop = stop
    targetPickerConversation = conversation
    targetPickerChats = chats
    targetPickerProviders = providers
  }

  init(
    draft: Binding<String>,
    attachments: [ChatAttachment],
    isCreating: Bool,
    canSend: Bool,
    targetSummary: String,
    targetDetails: String,
    openTarget: @escaping () -> Void,
    pickPhoto: @escaping () -> Void,
    pickFile: @escaping () -> Void,
    pickFromLibrary: (() -> Void)? = nil,
    projectFiles: [ProjectFile] = [],
    attachProjectFile: @escaping (ProjectFile) -> Void = { _ in },
    removeAttachment: @escaping (String) -> Void,
    send: @escaping () -> Void
  ) {
    self.init(
      draft: draft,
      attachments: attachments,
      activity: isCreating ? .creating : .idle,
      canSend: canSend,
      targetSummary: targetSummary,
      targetDetails: targetDetails,
      openTarget: openTarget,
      pickPhoto: pickPhoto,
      pickFile: pickFile,
      pickFromLibrary: pickFromLibrary,
      projectFiles: projectFiles,
      attachProjectFile: attachProjectFile,
      removeAttachment: removeAttachment,
      send: send
    )
  }

  private var normalizedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSubmit: Bool {
    activity == .idle && canSend && (!normalizedDraft.isEmpty || !attachments.isEmpty)
  }

  private var isCompact: Bool {
    ChatComposerLayoutPolicy.shouldUseCompact(
      isFocused: isEditorFocused,
      draftIsEmpty: draft.isEmpty,
      hasAttachments: !attachments.isEmpty,
      activity: activity
    )
  }

  private var contentHeightCap: CGFloat {
    let lineCount = ChatComposerLayoutPolicy.visibleTextLineCap(
      hasAttachments: !attachments.isEmpty
    )
    let textHeight = CGFloat(lineCount) * Self.messageLineHeight

    if attachments.isEmpty {
      return 10 + textHeight + 4
    }

    return 9 + ChatAttachmentPresentation.composer.railHeight + 4 + textHeight + 4
  }

  private var contentViewportHeight: CGFloat {
    if isCompact {
      return Self.compactContentHeight
    }

    return min(
      max(measuredContentHeight, Self.minimumExpandedContentHeight),
      contentHeightCap
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      contentViewport

      if !isCompact {
        bottomControls
      }
    }
    .foregroundStyle(theme.primaryForegroundColor)
    .background(theme.elevatedSurfaceColor, in: composerShape)
    .clipShape(composerShape)
    .overlay(composerShape.stroke(theme.borderColor, lineWidth: 0.65))
    .shadow(color: theme.appearance.shadow.color, radius: 14, y: 6)
    .padding(.horizontal, 14)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .animation(.snappy(duration: 0.2), value: isCompact)
    .sheet(isPresented: $showTargetPicker) {
      if let conversation = targetPickerConversation,
        let chats = targetPickerChats,
        let providers = targetPickerProviders
      {
        TargetPickerView(
          providers: providers,
          initialAccountID: conversation.accountID,
          initialModelID: conversation.modelID,
          initialReasoning: conversation.options.reasoning,
          mode: .existingChat(
            conversation: chats.conversation(conversation.id) ?? conversation,
            chats: chats
          )
        )
      }
    }
    .onDisappear {
      isEditorFocused = false
    }
  }

  private var contentViewport: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          if !attachments.isEmpty {
            ChatAttachmentStrip(
              attachments: attachments,
              presentation: .composer,
              removeAttachment: removeAttachment,
              pickPhoto: pickPhoto,
              pickFile: pickFile
            )
            .padding(.horizontal, 10)
            .padding(.top, 9)
          }

          messageField
            .padding(.leading, isCompact ? 54 : 14)
            .padding(.trailing, isCompact ? 54 : 14)
            .padding(.top, attachments.isEmpty ? (isCompact ? 5 : 10) : 4)
            .padding(.bottom, isCompact ? 5 : 4)
            .id(Self.textAnchor)
        }
        .background(
          GeometryReader { geometry in
            Color.clear.preference(
              key: ChatComposerContentHeightKey.self,
              value: geometry.size.height
            )
          }
        )
      }
      .scrollIndicators(.hidden)
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: contentViewportHeight)
      .overlay(alignment: .top) {
        if isCompact {
          compactControls
        }
      }
      .onPreferenceChange(ChatComposerContentHeightKey.self) { height in
        measuredContentHeight = height
      }
      .onChange(of: draft) { _, _ in
        scrollToTextIfNeeded(proxy)
      }
      .onChange(of: attachments.count) { _, _ in
        scrollToTextIfNeeded(proxy)
      }
    }
  }

  private var messageField: some View {
    TextField("Message...", text: $draft, axis: .vertical)
      .font(.system(size: 17))
      .foregroundStyle(theme.primaryForegroundColor)
      .tint(theme.accentColor)
      .lineLimit(1...)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
      .contentShape(Rectangle())
      .focused($isEditorFocused)
      .accessibilityLabel("Message")
  }

  private var compactControls: some View {
    HStack(spacing: 6) {
      optionsButton
      Spacer(minLength: 8)
      sendButton
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
  }

  private var bottomControls: some View {
    HStack(spacing: 6) {
      optionsButton
      targetButton
      Spacer(minLength: 8)
      sendButton
    }
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
  }

  private var composerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 28, style: .continuous)
  }

  private var optionsButton: some View {
    Menu {
      Button("Photo", systemImage: "photo", action: pickPhoto)
      Button("File", systemImage: "doc", action: pickFile)
      if let pickFromLibrary {
        Button("From Library…", systemImage: "books.vertical", action: pickFromLibrary)
      }
      if !projectFiles.isEmpty {
        Menu("Project Files", systemImage: "folder.badge.plus") {
          ForEach(projectFiles) { file in
            Button(file.filename) { attachProjectFile(file) }
          }
        }
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 21, weight: .regular))
        .foregroundStyle(theme.primaryForegroundColor)
        .frame(width: 38, height: 38)
        .contentShape(Circle())
    }
    .accessibilityLabel("Add attachment")
  }

  private var targetButton: some View {
    Button {
      isEditorFocused = false
      if targetPickerConversation != nil {
        showTargetPicker = true
      } else {
        openTarget()
      }
    } label: {
      HStack(spacing: 3) {
        Text(targetSummary)
          .lineLimit(1)
          .minimumScaleFactor(0.82)
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .semibold))
      }
      .font(.system(size: 12.5, weight: .medium))
      .foregroundStyle(theme.secondaryForegroundColor)
      .padding(.horizontal, 4)
      .frame(height: 32)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: 176, alignment: .leading)
    .disabled(activity.isBusy)
    .accessibilityLabel("Change provider, model, and reasoning. Currently \(targetDetails)")
    .accessibilityValue(targetSummary)
  }

  private var sendButton: some View {
    Button {
      switch activity {
      case .idle:
        send()
        isEditorFocused = false
      case .generating:
        stop?()
        isEditorFocused = false
      case .creating:
        break
      }
    } label: {
      Group {
        switch activity {
        case .idle:
          Image(systemName: "arrow.up")
            .font(.system(size: 15, weight: .bold))
        case .generating:
          Image(systemName: "stop.fill")
            .font(.system(size: 15, weight: .bold))
        case .creating:
          ProgressView()
            .controlSize(.small)
        }
      }
      .frame(width: 40, height: 40)
      .background(sendButtonBackground, in: Circle())
      .foregroundStyle(sendButtonForeground)
    }
    .buttonStyle(.plain)
    .disabled(activity == .creating || (activity == .idle && !canSubmit))
    .accessibilityLabel(sendButtonAccessibilityLabel)
  }

  private var sendButtonBackground: Color {
    if activity == .generating || canSubmit {
      return theme.accentColor
    }
    return theme.surfaceColor
  }

  private var sendButtonForeground: Color {
    if activity == .generating || canSubmit {
      return theme.backgroundColor
    }
    return theme.secondaryForegroundColor
  }

  private var sendButtonAccessibilityLabel: String {
    switch activity {
    case .idle: "Send message"
    case .generating: "Stop generation"
    case .creating: "Creating chat"
    }
  }

  private func scrollToTextIfNeeded(_ proxy: ScrollViewProxy) {
    guard isEditorFocused else { return }
    Task { @MainActor in
      await Task.yield()
      proxy.scrollTo(Self.textAnchor, anchor: .bottom)
    }
  }
}

typealias ChatInputComposer = ChatComposer
typealias NewChatInputComposer = ChatComposer

private struct ChatComposerContentHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

enum ComposerTargetLabelFormatter {
  private static let recognizableFamilies = [
    "gpt", "claude", "sonnet", "opus", "haiku", "gemini", "deepseek", "qwen",
    "llama", "mistral", "grok", "kimi", "nemotron", "phi", "command r", "minimax",
  ]

  static func make(
    providerID: ProviderID,
    providerName: String,
    modelName: String,
    modelID: String,
    supportedParameters: Set<String>,
    reasoning: ReasoningOptions?,
    capabilities: ResolvedModelCapabilities? = nil
  ) -> String {
    let source = modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? modelID
      : modelName
    let compactModel = compactModelName(source, providerName: providerName)
    let recognitionSource = (source + " " + modelID).lowercased()
    let isRecognizable = recognizableFamilies.contains { recognitionSource.contains($0) }

    var parts: [String] = []
    if !isRecognizable {
      parts.append(shortProviderName(providerID: providerID, displayName: providerName))
    }
    parts.append(compactModel)

    let control = capabilities?.reasoning ?? ModelCapabilityResolver.resolve(
      kind: ProviderKind.allCases.first { $0.defaultProviderID == providerID } ?? .openAICompatible,
      modelID: ModelID(rawValue: modelID)
    ).reasoning
    let label = control.label(for: reasoning)
    if !label.isEmpty { parts.append(label) }

    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private static func compactModelName(_ rawValue: String, providerName: String) -> String {
    var value = rawValue
      .replacingOccurrences(of: "_", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    value = collapseWhitespace(value)

    let providerIsModelFamily = recognizableFamilies.contains {
      providerName.lowercased().contains($0)
    }
    if !providerIsModelFamily,
      value.lowercased().hasPrefix(providerName.lowercased() + " ")
    {
      value = String(value.dropFirst(providerName.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let removableVendorPrefixes = [
      "OpenAI",
      "Anthropic",
      "Google DeepMind",
      "Google",
      "Meta AI",
      "Meta",
      "Alibaba",
      "NVIDIA",
    ]

    for prefix in removableVendorPrefixes {
      if value.lowercased().hasPrefix(prefix.lowercased() + " ") {
        value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        break
      }
    }

    let lower = value.lowercased()
    if lower.hasPrefix("claude ") {
      value = String(value.dropFirst("Claude ".count))
    } else if lower.hasPrefix("deepseek ") {
      let remainder = String(value.dropFirst("DeepSeek ".count))
      let remainderLower = remainder.lowercased()
      if remainderLower.hasPrefix("v")
        || remainderLower.hasPrefix("r")
        || remainderLower.hasPrefix("coder")
        || remainderLower.hasPrefix("reasoner")
      {
        value = remainder
      }
    }

    value = collapseWhitespace(value)
    if value.isEmpty {
      return rawValue.split(separator: "/").last.map(String.init) ?? rawValue
    }
    return value
  }

  private static func shortProviderName(providerID: ProviderID, displayName: String) -> String {
    switch providerID {
    case BuiltInProviders.openRouterID: return "OR"
    case BuiltInProviders.nvidiaID: return "NV"
    case BuiltInProviders.deepSeekID: return "DS"
    case BuiltInProviders.anthropicID: return "Anthropic"
    case BuiltInProviders.geminiID: return "Gemini"
    default:
      let words = displayName
        .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        .map(String.init)
      if words.count > 1 {
        let initials = words.prefix(3).compactMap(\.first).map(String.init).joined().uppercased()
        if !initials.isEmpty { return initials }
      }
      if displayName.count <= 7 { return displayName }
      return String(displayName.prefix(4))
    }
  }

  private static func collapseWhitespace(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

