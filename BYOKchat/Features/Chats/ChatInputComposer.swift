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

  @Environment(\.appFoundationTheme) private var theme
  @FocusState private var isEditorFocused: Bool
  @State private var measuredContentHeight: CGFloat = 0

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
  }

  init(
    draft: Binding<String>,
    attachments: [ChatAttachment],
    isGenerating: Bool,
    canSend: Bool,
    conversation: ChatConversation,
    chats _: ChatManagementModel,
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

    let capabilities = providers.capabilities(
      accountID: conversation.accountID, modelID: conversation.modelID
    )
    targetSummary = ComposerTargetLabelFormatter.make(
      providerID: conversation.providerID,
      providerName: providerName,
      modelName: model?.displayName ?? conversation.modelID.rawValue,
      modelID: conversation.modelID.rawValue,
      supportedParameters: model?.supportedParameters ?? [],
      reasoning: conversation.options.reasoning,
      capabilities: capabilities
    )
    let reasoningDetail = capabilities.reasoning.label(for: conversation.options.reasoning)
    targetDetails = [
      account?.label ?? providerName,
      model?.displayName ?? conversation.modelID.rawValue,
      reasoningDetail,
    ].filter { !$0.isEmpty }.joined(separator: " · ")
    openTarget = openChatSettings
    self.pickPhoto = pickPhoto
    self.pickFile = pickFile
    self.pickFromLibrary = pickFromLibrary
    self.projectFiles = projectFiles
    self.attachProjectFile = attachProjectFile
    self.removeAttachment = removeAttachment
    self.send = send
    self.stop = stop
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
      openTarget()
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
  /// Families worth showing in the chip without an extra provider abbreviation.
  /// Only match the beginning of the model name, not an arbitrary substring.
  private static let recognizableFamilies = [
    "gpt", "o1", "o3", "o4", "claude", "sonnet", "opus", "haiku",
    "gemini", "deepseek", "glm", "qwen", "llama", "mistral", "codestral",
    "devstral", "magistral", "ministral", "grok", "kimi",
    "nemotron", "phi", "command r", "minimax",
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
    let model = compactModelName(source, providerID: providerID, providerName: providerName)
    let modelLabel: String
    if providerID == BuiltInProviders.deepSeekID,
       model != "DeepSeek" && !model.lowercased().hasPrefix("deepseek ") {
      // The stripped "V4.1 Flash" alone isn't identifiable: "DS" is compact
      // and preserves who made the model, even when the API returns hyphenated IDs.
      modelLabel = "DS \(model)"
    } else if isRecognizable(model) {
      // GPT, Claude, Gemini, Llama, etc. already identify the model family.
      modelLabel = model
    } else {
      let provider = shortProviderName(providerID: providerID, displayName: providerName)
      modelLabel = provider.isEmpty ? model : "\(provider) · \(model)"
    }

    let control = capabilities?.reasoning ?? ModelCapabilityResolver.resolve(
      kind: ProviderKind.allCases.first { $0.defaultProviderID == providerID } ?? .openAICompatible,
      modelID: ModelID(rawValue: modelID)
    ).reasoning
    let effort = reasoningLabel(reasoning, control: control)
    return effort.isEmpty ? modelLabel : "\(modelLabel) · \(effort)"
  }

  /// Server-safe analytics version of the composer target label.
  static func analyticsDimension(
    providerID: ProviderID,
    providerName: String,
    modelName: String,
    modelID: String,
    supportedParameters: Set<String>,
    reasoning: ReasoningOptions?,
    capabilities: ResolvedModelCapabilities? = nil
  ) -> String? {
    let label = make(
      providerID: providerID,
      providerName: providerName,
      modelName: modelName,
      modelID: modelID,
      supportedParameters: supportedParameters,
      reasoning: reasoning,
      capabilities: capabilities
    )
    let sanitized = label
      .replacingOccurrences(of: " · ", with: "-")
      .filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/+".contains($0)) }
    guard let first = sanitized.first, first.isLetter || first.isNumber else { return nil }
    return String(sanitized.prefix(64))
  }

  private static func compactModelName(
    _ value: String, providerID: ProviderID, providerName: String
  ) -> String {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)

    // Some catalogs expose "vendor/model-id" as the display name itself.
    // The vendor is still represented by the actual model family below.
    if !text.contains(where: \.isWhitespace), text.contains("/") {
      text = String(text.split(separator: "/").last ?? Substring(text))
    }

    // Normalize model-ID separators but preserve the familiar "GPT-5.x" and "GLM-5.x" spellings.
    text = text.replacingOccurrences(of: "_", with: " ")
    if text.lowercased().hasPrefix("gpt-") {
      text = "GPT-" + String(text.dropFirst(4)).replacingOccurrences(of: "-", with: " ")
    } else if text.lowercased().hasPrefix("glm-") {
      text = "GLM-" + String(text.dropFirst(4)).replacingOccurrences(of: "-", with: " ")
    } else {
      text = text.replacingOccurrences(of: "-", with: " ")
    }
    text = collapseWhitespace(text)

    // Strip vendor metadata, not the distinctive model family. On OpenRouter,
    // for example, "Claude" or "DeepSeek" must remain in the visible name.
    for prefix in [
      "Google DeepMind", "Meta AI", "Mistral AI", "Moonshot AI", "Zhipu AI", "OpenAI",
      "Anthropic", "Google", "Meta", "Alibaba", "NVIDIA", "Moonshot", "Zhipu", "Z.ai",
    ] {
      if let stripped = removingPrefix(text, prefix) {
        text = stripped
        break
      }
    }
    if providerID == BuiltInProviders.deepSeekID,
       let stripped = removingPrefix(text, "DeepSeek") {
      text = stripped
    } else if providerID == BuiltInProviders.anthropicID,
              let stripped = removingPrefix(text, "Claude") {
      text = stripped
    }

    // Custom endpoints may repeat the configured provider label in the model.
    if !isRecognizable(providerName),
       let stripped = removingPrefix(text, providerName) {
      text = stripped
    }

    text = canonicalizeFamilyWords(text)
    return collapseWhitespace(text).isEmpty ? value : collapseWhitespace(text)
  }

  private static func canonicalizeFamilyWords(_ value: String) -> String {
    // Discovered IDs are often lowercased and hyphenated; apply canonical case
    // only to known family tokens, leaving version numbers and suffixes intact.
    let familyNames: [String: String] = [
      "claude": "Claude", "sonnet": "Sonnet", "opus": "Opus", "haiku": "Haiku",
      "gemini": "Gemini", "deepseek": "DeepSeek", "glm": "GLM", "gpt": "GPT", "qwen": "Qwen",
      "llama": "Llama", "mistral": "Mistral", "codestral": "Codestral",
      "devstral": "Devstral", "magistral": "Magistral", "ministral": "Ministral", "grok": "Grok",
      "kimi": "Kimi", "nemotron": "Nemotron", "phi": "Phi", "minimax": "MiniMax",
      "flash": "Flash", "flashx": "FlashX", "air": "Air", "airx": "AirX",
      "pro": "Pro", "highspeed": "Highspeed", "mini": "Mini", "nano": "Nano",
      "turbo": "Turbo", "lite": "Lite", "preview": "Preview",
      "instruct": "Instruct", "reasoner": "Reasoner", "coder": "Coder",
      "chat": "Chat", "thinking": "Thinking", "sol": "Sol",
    ]
    return value.split(separator: " ").map { piece in
      let token = String(piece)
      if let styled = familyNames[token.lowercased()] { return styled }
      if token.hasPrefix("GLM-"), token.hasSuffix("v"),
        let beforeV = token.dropLast().last, beforeV.isNumber
      {
        return String(token.dropLast()) + "V"
      }
      if token.first?.lowercased() == "v", token.dropFirst().first?.isNumber == true {
        return "V" + String(token.dropFirst())
      }
      if token.first?.lowercased() == "k", token.dropFirst().first?.isNumber == true {
        return "K" + String(token.dropFirst())
      }
      if token.first?.lowercased() == "m", token.dropFirst().first?.isNumber == true {
        return "M" + String(token.dropFirst())
      }
      return token
    }.joined(separator: " ")
  }

  private static func removingPrefix(_ value: String, _ prefix: String) -> String? {
    guard !prefix.isEmpty, value.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
    let suffix = String(value.dropFirst(prefix.count))
    guard let first = suffix.first, first.isWhitespace || first == ":" else { return nil }
    let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func isRecognizable(_ model: String) -> Bool {
    let lower = model.lowercased()
    return recognizableFamilies.contains { family in
      guard lower.hasPrefix(family) else { return false }
      let remainder = lower.dropFirst(family.count)
      return remainder.isEmpty || remainder.first?.isWhitespace == true
        || remainder.first == "-" || remainder.first?.isNumber == true
    }
  }

  /// Defaults are deliberately absent: they do not need precious composer
  /// width. Explicit Off/effort/budget still distinguish actual user choices.
  private static func reasoningLabel(
    _ reasoning: ReasoningOptions?, control: ModelReasoningControl
  ) -> String {
    guard let reasoning, let options = control.normalize(reasoning) else { return "" }
    if options.enabled == false { return "Off" }

    var parts: [String] = []
    if let effort = options.effort {
      switch effort {
      case .minimal: parts.append("Min")
      case .low: parts.append("Low")
      case .medium: parts.append("Med")
      case .high: parts.append("High")
      case .xhigh: parts.append("X-High")
      case .max: parts.append("Max")
      }
    }
    if let tokens = options.maxTokens {
      parts.append(tokens == -1 ? "Auto" : compactBudget(tokens))
    }
    if parts.isEmpty { return "On" }
    return parts.joined(separator: " · ")
  }

  private static func compactBudget(_ tokens: Int) -> String {
    guard tokens >= 1_000 else { return "\(tokens)" }
    if tokens % 1_000 == 0 { return "\(tokens / 1_000)K" }
    let kilo = Double(tokens) / 1_000
    if kilo < 1.05 { return "1K" }
    return String(format: "%.1fK", kilo)
  }

  private static func shortProviderName(providerID: ProviderID, displayName: String) -> String {
    switch providerID {
    case BuiltInProviders.openRouterID: return "OR"
    case BuiltInProviders.nvidiaID: return "NV"
    case BuiltInProviders.deepSeekID: return "DS"
    case BuiltInProviders.zAIID: return "Z.ai"
    case BuiltInProviders.moonshotID: return "Moonshot"
    case BuiltInProviders.minimaxID: return "MiniMax"
    case BuiltInProviders.mistralID: return "Mistral"
    case BuiltInProviders.anthropicID: return "Anthropic"
    case BuiltInProviders.geminiID: return "Gemini"
    case BuiltInProviders.ollamaID: return "Ollama"
    case BuiltInProviders.lmStudioID: return "LM Studio"
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
