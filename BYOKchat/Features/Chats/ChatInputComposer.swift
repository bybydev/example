import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct ChatInputComposer: View {
  @Binding var draft: String
  let attachments: [ChatAttachment]
  let isGenerating: Bool
  let canSend: Bool
  let conversation: ChatConversation
  @Bindable var chats: ChatManagementModel
  let providers: ProviderManagementModel
  let openChatSettings: () -> Void
  let pickPhoto: () -> Void
  let pickFile: () -> Void
  let removeAttachment: (String) -> Void
  let send: () -> Void
  let stop: () -> Void

  @Environment(\.appFoundationTheme) private var theme
  @FocusState private var isEditorFocused: Bool
  @State private var isExpanded = false
  @State private var showTargetPicker = false

  private var normalizedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSubmit: Bool {
    canSend && (!normalizedDraft.isEmpty || !attachments.isEmpty)
  }

  private var isCompact: Bool {
    !isExpanded && !isEditorFocused && attachments.isEmpty && normalizedDraft.isEmpty && !isGenerating
  }

  private var selectedAccount: ProviderAccount? {
    providers.accounts.first { $0.id == conversation.accountID }
  }

  private var selectedModel: ProviderModel? {
    providers.models(for: conversation.accountID, includeHidden: true)
      .first { $0.model.id == conversation.modelID }?.model
  }

  private var providerDisplayName: String {
    providers.provider(for: conversation.providerID)?.displayName
      ?? selectedAccount?.label
      ?? conversation.providerID.rawValue
  }

  private var targetSummary: String {
    ComposerTargetLabelFormatter.make(
      providerID: conversation.providerID,
      providerName: providerDisplayName,
      modelName: selectedModel?.displayName ?? conversation.modelID.rawValue,
      modelID: conversation.modelID.rawValue,
      supportedParameters: selectedModel?.supportedParameters ?? [],
      reasoning: conversation.options.reasoning
    )
  }

  private var targetDetails: String {
    let accountName = selectedAccount?.label ?? providerDisplayName
    let modelName = selectedModel?.displayName ?? conversation.modelID.rawValue
    return "\(accountName) · \(modelName)"
  }

  var body: some View {
    Group {
      if isCompact {
        compactComposer
      } else {
        expandedComposer
      }
    }
    .foregroundStyle(theme.primaryForegroundColor)
    .background(theme.elevatedSurfaceColor, in: composerShape)
    .overlay(composerShape.stroke(theme.borderColor, lineWidth: 0.65))
    .shadow(color: theme.appearance.shadow.color, radius: 14, y: 6)
    .padding(.horizontal, 14)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .animation(.snappy(duration: 0.2), value: isCompact)
    .sheet(isPresented: $showTargetPicker) {
      ComposerTargetPickerView(
        conversation: chats.conversation(conversation.id) ?? conversation,
        chats: chats,
        providers: providers
      )
    }
    .onChange(of: isEditorFocused) { _, focused in
      if !focused && attachments.isEmpty && normalizedDraft.isEmpty && !isGenerating {
        isExpanded = false
      }
    }
    .onChange(of: isGenerating) { _, generating in
      if generating {
        isEditorFocused = false
        isExpanded = false
      }
    }
    .onDisappear {
      isEditorFocused = false
      isExpanded = false
    }
  }

  private var compactComposer: some View {
    HStack(spacing: 6) {
      optionsButton

      Button(action: expandAndFocus) {
        Text("Message...")
          .font(.system(size: 17))
          .foregroundStyle(theme.secondaryForegroundColor)
          .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Message")
      .accessibilityHint("Double tap to start typing")

      sendButton
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
  }

  private var expandedComposer: some View {
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
        .padding(.horizontal, 14)
        .padding(.top, attachments.isEmpty ? 10 : 4)
        .padding(.bottom, 2)

      HStack(spacing: 6) {
        optionsButton
        targetButton
        Spacer(minLength: 8)
        sendButton
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 8)
    }
  }

  private var composerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 28, style: .continuous)
  }

  private var messageField: some View {
    TextField("Message...", text: $draft, axis: .vertical)
      .font(.system(size: 17))
      .foregroundStyle(theme.primaryForegroundColor)
      .tint(theme.accentColor)
      .lineLimit(1...7)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
      .focused($isEditorFocused)
      .accessibilityLabel("Message")
  }

  private var optionsButton: some View {
    Menu {
      Button("Photo", systemImage: "photo", action: pickPhoto)
      Button("File", systemImage: "doc", action: pickFile)
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
      showTargetPicker = true
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
    .disabled(isGenerating)
    .accessibilityLabel("Change provider, model, and reasoning. Currently \(targetDetails)")
    .accessibilityValue(targetSummary)
  }

  private var sendButton: some View {
    Button {
      if isGenerating {
        stop()
      } else {
        send()
      }
      isEditorFocused = false
    } label: {
      Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
        .font(.system(size: 15, weight: .bold))
        .frame(width: 40, height: 40)
        .background(sendButtonBackground, in: Circle())
        .foregroundStyle(sendButtonForeground)
    }
    .buttonStyle(.plain)
    .disabled(!isGenerating && !canSubmit)
    .accessibilityLabel(isGenerating ? "Stop generation" : "Send message")
  }

  private func expandAndFocus() {
    isExpanded = true
    Task { @MainActor in
      await Task.yield()
      isEditorFocused = true
    }
  }

  private var sendButtonBackground: Color {
    if isGenerating || canSubmit { return theme.accentColor }
    return theme.surfaceColor
  }

  private var sendButtonForeground: Color {
    if isGenerating || canSubmit { return theme.backgroundColor }
    return theme.secondaryForegroundColor
  }
}

enum ComposerTargetLabelFormatter {
  private static let reasoningParameters: Set<String> = [
    "reasoning", "thinking", "reasoning_effort", "thinkingConfig", "effort",
  ]

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
    reasoning: ReasoningOptions?
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

    if !supportedParameters.isDisjoint(with: reasoningParameters) {
      parts.append(reasoningLabel(reasoning))
    }

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

  private static func reasoningLabel(_ reasoning: ReasoningOptions?) -> String {
    guard reasoning?.enabled == true else { return "Off" }
    guard let effort = reasoning?.effort else { return "On" }
    switch effort {
    case .minimal: return "Min"
    case .low: return "Low"
    case .medium: return "Med"
    case .high: return "High"
    case .max: return "Max"
    }
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
