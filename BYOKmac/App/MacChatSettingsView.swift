import BYOKchatProviderCore
import Foundation
import SwiftUI

nonisolated enum MacChatSettingsSupport {
  static func normalizedSystemPrompt(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func temperatureRange(for kind: ProviderKind?) -> ClosedRange<Double> {
    kind == .minimax ? 0.01...1.0 : 0.0...2.0
  }

  static func clampedTemperature(_ value: Double, for kind: ProviderKind?) -> Double {
    let range = temperatureRange(for: kind)
    let clamped = min(max(value, range.lowerBound), range.upperBound)
    return (clamped * 100).rounded() / 100
  }

  static func clampedTopP(_ value: Double) -> Double {
    let clamped = min(max(value, 0.05), 1.0)
    return (clamped * 100).rounded() / 100
  }

  static func supportsSamplingControls(
    kind: ProviderKind?,
    modelID: ModelID?,
    reasoning: ReasoningOptions?,
    reasoningControl: ModelReasoningControl
  ) -> Bool {
    guard let kind else { return true }
    switch kind {
    case .anthropic:
      return false
    case .openai:
      if reasoningControl.kind != .unsupported && reasoningControl.kind != .unknown {
        return reasoningControl.allowsOff && reasoning?.enabled == false
      }
      return true
    case .gemini:
      let id = (modelID?.rawValue ?? "").lowercased()
      return !id.hasPrefix("gemini-4")
        && !id.hasPrefix("gemini-3.8")
        && !id.hasPrefix("gemini-3.7")
        && !id.hasPrefix("gemini-3.6")
        && !id.hasPrefix("gemini-3.5-flash-lite")
    case .deepSeek:
      return reasoning?.enabled == false
    case .moonshot:
      let id = (modelID?.rawValue ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
      return !id.hasPrefix("kimi-k3")
        && !id.hasPrefix("kimi-k2.6")
        && !id.hasPrefix("kimi-k2.5")
    case .xAI, .openRouter, .zAI, .minimax, .qwen, .mistral, .groq, .together, .fireworks,
      .nvidia, .ollama, .lmStudio, .openAICompatible:
      return true
    }
  }

  static func parseMaxOutputTokens(
    _ raw: String,
    maxAllowed: Int?,
    anthropicReasoningBudget: Int?
  ) -> (value: Int?, error: String?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return (nil, nil) }
    guard let parsed = Int(trimmed), parsed > 0 else {
      return (nil, "Enter a positive whole number of tokens.")
    }
    if let maxAllowed, parsed > maxAllowed {
      return (nil, "This model supports at most \(maxAllowed.formatted()) output tokens.")
    }
    if let budget = anthropicReasoningBudget, parsed <= budget {
      return (
        nil,
        "Max output tokens must exceed the thinking budget (\((budget + 1).formatted()) or higher)."
      )
    }
    return (parsed, nil)
  }

  static func parseProviderOrder(_ raw: String) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for token in raw.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
      let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
      result.append(cleaned)
    }
    return result
  }

  static func normalizedOpenRouterRouting(
    _ routing: OpenRouterRoutingOptions
  ) -> OpenRouterRoutingOptions? {
    let hasValue =
      !routing.providerOrder.isEmpty
      || routing.allowFallbacks != nil
      || routing.requireParameters != nil
      || routing.dataCollection != nil
      || routing.zeroDataRetention != nil
      || routing.sort != nil
    return hasValue ? routing : nil
  }
}

struct MacChatSettingsView: View {
  private enum FallbackChoice: String, CaseIterable, Identifiable {
    case `default`
    case allow
    case disable

    var id: String { rawValue }

    var label: String {
      switch self {
      case .default: "Default"
      case .allow: "Allow"
      case .disable: "Disable"
      }
    }

    var boolValue: Bool? {
      switch self {
      case .default: nil
      case .allow: true
      case .disable: false
      }
    }

    init(boolValue: Bool?) {
      switch boolValue {
      case true: self = .allow
      case false: self = .disable
      case nil: self = .default
      }
    }
  }

  @Bindable var chats: MacChatSessionModel
  @Bindable var providers: MacProviderModel
  let conversationID: ConversationID?
  let project: ChatProject?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.macToastCenter) private var toastCenter

  @State private var systemPrompt: String
  @State private var useCustomTemperature: Bool
  @State private var temperature: Double
  @State private var useCustomTopP: Bool
  @State private var topP: Double
  @State private var maxOutputTokensText: String
  @State private var openRouterSort: OpenRouterSort?
  @State private var openRouterDataCollection: OpenRouterDataCollection?
  @State private var openRouterFallbacks: FallbackChoice
  @State private var openRouterRequireParameters: Bool
  @State private var openRouterZeroDataRetention: Bool
  @State private var openRouterProviderOrderText: String

  @State private var showingTargetPicker = false
  @State private var isSaving = false
  @State private var saveError: String?

  init(
    chats: MacChatSessionModel,
    providers: MacProviderModel,
    conversationID: ConversationID?,
    project: ChatProject?
  ) {
    self.chats = chats
    self.providers = providers
    self.conversationID = conversationID
    self.project = project

    let initialPrompt = chats.effectiveSystemPrompt(for: conversationID, project: project)
    let initialOptions = chats.effectiveOptions(for: conversationID)
    let target = chats.target(for: conversationID)
    let accountKind = providers.account(target?.accountID)?.kind
    let initialTemp = initialOptions.temperature
    let initialTopP = initialOptions.topP
    let routing = initialOptions.openRouterRouting

    _systemPrompt = State(initialValue: initialPrompt)
    _useCustomTemperature = State(initialValue: initialTemp != nil)
    _temperature = State(
      initialValue: MacChatSettingsSupport.clampedTemperature(initialTemp ?? 0.7, for: accountKind)
    )
    _useCustomTopP = State(initialValue: initialTopP != nil)
    _topP = State(initialValue: MacChatSettingsSupport.clampedTopP(initialTopP ?? 1.0))
    _maxOutputTokensText = State(
      initialValue: initialOptions.maxOutputTokens.map(String.init) ?? ""
    )
    _openRouterSort = State(initialValue: routing?.sort)
    _openRouterDataCollection = State(initialValue: routing?.dataCollection)
    _openRouterFallbacks = State(initialValue: FallbackChoice(boolValue: routing?.allowFallbacks))
    _openRouterRequireParameters = State(initialValue: routing?.requireParameters == true)
    _openRouterZeroDataRetention = State(initialValue: routing?.zeroDataRetention == true)
    _openRouterProviderOrderText = State(
      initialValue: routing?.providerOrder.joined(separator: ", ") ?? ""
    )
  }

  private var liveTarget: MacChatTarget? {
    chats.target(for: conversationID)
  }

  private var liveOptions: ProviderRequestOptions {
    chats.effectiveOptions(for: conversationID)
  }

  private var account: ProviderAccount? {
    guard let accountID = liveTarget?.accountID else { return nil }
    return providers.account(accountID).flatMap { $0.isEnabled ? $0 : nil }
  }

  private var hasModelID: Bool {
    guard let modelID = liveTarget?.modelID else { return false }
    return !modelID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var modelRecord: AccountModelRecord? {
    guard let target = liveTarget, hasModelID else { return nil }
    return providers.models(for: target.accountID, includeHidden: true)
      .first { $0.model.id == target.modelID }
  }

  private var capabilities: ResolvedModelCapabilities? {
    guard let account, let target = liveTarget, hasModelID else { return nil }
    return ModelCapabilityResolver.resolve(
      kind: account.kind,
      modelID: target.modelID,
      model: modelRecord?.model
    )
  }

  private var reasoningControl: ModelReasoningControl {
    capabilities?.reasoning ?? .init()
  }

  private var supportsSamplingControls: Bool {
    MacChatSettingsSupport.supportsSamplingControls(
      kind: account?.kind,
      modelID: liveTarget?.modelID,
      reasoning: liveOptions.reasoning,
      reasoningControl: reasoningControl
    )
  }

  private var temperatureRange: ClosedRange<Double> {
    MacChatSettingsSupport.temperatureRange(for: account?.kind)
  }

  private var anthropicReasoningBudget: Int? {
    guard account?.kind == .anthropic else { return nil }
    let normalized = reasoningControl.normalize(liveOptions.reasoning)
    guard normalized?.enabled != false else { return nil }
    return normalized?.maxTokens
  }

  private var maxOutputTokensValidation: (value: Int?, error: String?) {
    MacChatSettingsSupport.parseMaxOutputTokens(
      maxOutputTokensText,
      maxAllowed: capabilities?.maxOutputTokens,
      anthropicReasoningBudget: anthropicReasoningBudget
    )
  }

  private var normalizedSystemPrompt: String {
    MacChatSettingsSupport.normalizedSystemPrompt(systemPrompt)
  }

  private var normalizedProjectInstructions: String {
    MacChatSettingsSupport.normalizedSystemPrompt(project?.instructions ?? "")
  }

  private var normalizedDefaultPrompt: String {
    MacChatSettingsSupport.normalizedSystemPrompt(chats.defaultSystemPrompt)
  }

  private var hasCustomParameters: Bool {
    (supportsSamplingControls && (useCustomTemperature || useCustomTopP))
      || !maxOutputTokensText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var hasCustomOpenRouterRouting: Bool {
    buildOpenRouterRouting() != nil
  }

  private var isGenerating: Bool {
    chats.isGenerating(conversationID)
  }

  private var canSave: Bool {
    !isSaving
      && !isGenerating
      && maxOutputTokensValidation.error == nil
      && (conversationID == nil || (account != nil && hasModelID))
  }

  private var modelDisplayTitle: String {
    if let record = modelRecord {
      return record.model.displayName
    }
    if let modelID = liveTarget?.modelID, hasModelID {
      return modelID.rawValue
    }
    return "Select Model"
  }

  private var modelSubtitle: String {
    var parts: [String] = []
    if let account {
      parts.append(account.label)
    } else {
      parts.append("No ready connection")
    }
    let reasoningLabel = reasoningControl.label(for: liveOptions.reasoning)
    if !reasoningLabel.isEmpty {
      parts.append("Reasoning: \(reasoningLabel)")
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          modelSection
          systemPromptSection
          parametersSection
          if account?.kind == .openRouter {
            openRouterRoutingSection
          }
        }
        .padding(18)
      }
    }
    .frame(width: 600, height: account?.kind == .openRouter ? 680 : 620)
    .background(MacDesignTokens.Colors.canvas)
    .sheet(isPresented: $showingTargetPicker) {
      MacTargetPickerView(
        providers: providers,
        initialTarget: liveTarget,
        maxOutputTokens: maxOutputTokensValidation.value ?? liveOptions.maxOutputTokens
      ) { target in
        await chats.applyTarget(target, conversationID: conversationID)
      }
    }
    .onChange(of: account?.kind) { _, newKind in
      temperature = MacChatSettingsSupport.clampedTemperature(temperature, for: newKind)
    }
    .alert(
      "Chat Settings Error",
      isPresented: Binding(
        get: { saveError != nil },
        set: { if !$0 { saveError = nil } }
      )
    ) {
      Button("OK") { saveError = nil }
    } message: {
      Text(saveError ?? "Unable to save chat settings.")
    }
  }

  private var headerBar: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Chat Settings")
          .font(.headline)
        Text(conversationID == nil ? "Applies when this new chat starts" : "Overrides defaults for this conversation")
          .font(.caption)
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }

      Spacer()

      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .disabled(isSaving)

      if isSaving {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Saving chat settings")
      } else {
        Button("Save") {
          Task { await save() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
      }
    }
    .padding(16)
  }

  private var modelSection: some View {
    settingsCard("Model & Reasoning", systemImage: "cpu") {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(modelDisplayTitle)
              .font(.system(size: 13.5, weight: .semibold))
              .foregroundStyle(MacDesignTokens.Colors.textPrimary)
              .lineLimit(1)
            Text(modelSubtitle)
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .lineLimit(1)
          }

          Spacer(minLength: 10)

          Button("Change…") {
            showingTargetPicker = true
          }
          .disabled(isSaving || isGenerating)
        }

        if conversationID != nil && (account == nil || !hasModelID) {
          Label(
            "Choose an enabled connection and model before saving chat settings.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        } else if isGenerating {
          Label(
            "Wait for the current response to finish before saving changes.",
            systemImage: "hourglass"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }
      }
    }
  }

  private var systemPromptSection: some View {
    settingsCard("System Prompt", systemImage: "text.alignleft") {
      VStack(alignment: .leading, spacing: 10) {
        ZStack(alignment: .topLeading) {
          TextEditor(text: $systemPrompt)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 120, maxHeight: 180)
            .background(
              MacDesignTokens.Colors.canvas.opacity(0.65),
              in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MacDesignTokens.Colors.separator.opacity(0.8), lineWidth: 0.75)
            }
            .disabled(isSaving)
            .accessibilityLabel("Chat System Prompt")

          if systemPrompt.isEmpty {
            Text("Optional instructions for this conversation…")
              .font(.body)
              .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.65))
              .padding(.top, 11)
              .padding(.leading, 11)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }

        HStack(spacing: 8) {
          if !normalizedProjectInstructions.isEmpty,
            normalizedSystemPrompt != normalizedProjectInstructions
          {
            Button("Reset to Project") {
              systemPrompt = normalizedProjectInstructions
            }
            .controlSize(.small)
            .disabled(isSaving)
          }

          if !normalizedDefaultPrompt.isEmpty,
            normalizedSystemPrompt != normalizedDefaultPrompt
          {
            Button("Reset to Default") {
              systemPrompt = normalizedDefaultPrompt
            }
            .controlSize(.small)
            .disabled(isSaving)
          }

          Spacer(minLength: 0)

          if !normalizedSystemPrompt.isEmpty {
            Button("Clear", role: .destructive) {
              systemPrompt = ""
            }
            .controlSize(.small)
            .disabled(isSaving)
          }
        }

        Text(
          project != nil && !normalizedProjectInstructions.isEmpty
            ? "Applies only to this conversation. Instructions from \(project?.name ?? "this project") are used by default."
            : "Applies only to this conversation and overrides your global default system prompt."
        )
        .font(.caption)
        .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
    }
  }

  private var parametersSection: some View {
    settingsCard("Parameters", systemImage: "slider.horizontal.3") {
      VStack(alignment: .leading, spacing: 12) {
        if supportsSamplingControls {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Toggle("Temperature", isOn: $useCustomTemperature)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isSaving)
              Spacer()
              Text(useCustomTemperature ? String(format: "%.2f", temperature) : "Default")
                .font(.caption.monospacedDigit())
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }

            if useCustomTemperature {
              Slider(value: $temperature, in: temperatureRange, step: 0.05)
                .disabled(isSaving)
                .accessibilityLabel("Temperature value")
            }
          }

          Divider()

          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Toggle("Top-P", isOn: $useCustomTopP)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isSaving)
              Spacer()
              Text(useCustomTopP ? String(format: "%.2f", topP) : "Default")
                .font(.caption.monospacedDigit())
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            }

            if useCustomTopP {
              Slider(value: $topP, in: 0.05...1.0, step: 0.05)
                .disabled(isSaving)
                .accessibilityLabel("Top-P value")
            }
          }

          Divider()
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 12) {
            Text("Max Output Tokens")
              .font(.system(size: 13))
            Spacer()
            TextField("Default", text: $maxOutputTokensText)
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing)
              .monospacedDigit()
              .frame(width: 130)
              .disabled(isSaving)
          }

          if let error = maxOutputTokensValidation.error {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
          }
        }

        HStack(alignment: .top, spacing: 8) {
          Text(parametersFooter)
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)

          Spacer(minLength: 8)

          if hasCustomParameters {
            Button("Reset Parameters") {
              useCustomTemperature = false
              useCustomTopP = false
              maxOutputTokensText = ""
            }
            .controlSize(.small)
            .disabled(isSaving)
          }
        }
      }
    }
  }

  private var parametersFooter: String {
    var parts: [String] = []
    if let maximum = capabilities?.maxOutputTokens {
      parts.append(
        "Leave Max Output Tokens blank to use the model default (up to \(maximum.formatted()) tokens)."
      )
    } else {
      parts.append("Leave Max Output Tokens blank to use the provider default.")
    }
    if !supportsSamplingControls {
      parts.append("Temperature and Top-P are managed automatically by this model.")
    }
    return parts.joined(separator: " ")
  }

  private var openRouterRoutingSection: some View {
    settingsCard("OpenRouter Routing", systemImage: "arrow.triangle.branch") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Sort")
            .font(.system(size: 13))
          Spacer()
          Picker("Sort", selection: $openRouterSort) {
            Text("Default").tag(OpenRouterSort?.none)
            Text("Price").tag(OpenRouterSort?.some(.price))
            Text("Throughput").tag(OpenRouterSort?.some(.throughput))
            Text("Latency").tag(OpenRouterSort?.some(.latency))
          }
          .labelsHidden()
          .frame(width: 160)
          .disabled(isSaving)
        }

        HStack {
          Text("Data Collection")
            .font(.system(size: 13))
          Spacer()
          Picker("Data Collection", selection: $openRouterDataCollection) {
            Text("Default").tag(OpenRouterDataCollection?.none)
            Text("Allow").tag(OpenRouterDataCollection?.some(.allow))
            Text("Deny").tag(OpenRouterDataCollection?.some(.deny))
          }
          .labelsHidden()
          .frame(width: 160)
          .disabled(isSaving)
        }

        HStack {
          Text("Allow Fallbacks")
            .font(.system(size: 13))
          Spacer()
          Picker("Allow Fallbacks", selection: $openRouterFallbacks) {
            ForEach(FallbackChoice.allCases) { choice in
              Text(choice.label).tag(choice)
            }
          }
          .labelsHidden()
          .frame(width: 160)
          .disabled(isSaving)
        }

        Toggle("Require Parameter Support", isOn: $openRouterRequireParameters)
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(isSaving)

        Toggle("Zero Data Retention (ZDR)", isOn: $openRouterZeroDataRetention)
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(isSaving)

        VStack(alignment: .leading, spacing: 4) {
          Text("Provider Order")
            .font(.caption.weight(.medium))
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          TextField("e.g. anthropic, openai", text: $openRouterProviderOrderText)
            .textFieldStyle(.roundedBorder)
            .disabled(isSaving)
        }

        HStack {
          Text("Optional routing preferences sent to OpenRouter for this conversation.")
            .font(.caption)
            .foregroundStyle(MacDesignTokens.Colors.textMuted)
          Spacer()
          if hasCustomOpenRouterRouting {
            Button("Reset Routing") {
              openRouterSort = nil
              openRouterDataCollection = nil
              openRouterFallbacks = .default
              openRouterRequireParameters = false
              openRouterZeroDataRetention = false
              openRouterProviderOrderText = ""
            }
            .controlSize(.small)
            .disabled(isSaving)
          }
        }
      }
    }
  }

  private func settingsCard<Content: View>(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(MacDesignTokens.Colors.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.75), lineWidth: 0.6)
    }
  }

  private func buildOpenRouterRouting() -> OpenRouterRoutingOptions? {
    let routing = OpenRouterRoutingOptions(
      providerOrder: MacChatSettingsSupport.parseProviderOrder(openRouterProviderOrderText),
      allowFallbacks: openRouterFallbacks.boolValue,
      requireParameters: openRouterRequireParameters ? true : nil,
      dataCollection: openRouterDataCollection,
      zeroDataRetention: openRouterZeroDataRetention ? true : nil,
      sort: openRouterSort
    )
    return MacChatSettingsSupport.normalizedOpenRouterRouting(routing)
  }

  private func save() async {
    guard canSave else { return }
    isSaving = true
    defer { isSaving = false }

    var updatedOptions = liveOptions
    if supportsSamplingControls {
      updatedOptions.temperature = useCustomTemperature
        ? MacChatSettingsSupport.clampedTemperature(temperature, for: account?.kind)
        : nil
      updatedOptions.topP = useCustomTopP
        ? MacChatSettingsSupport.clampedTopP(topP)
        : nil
    }
    updatedOptions.maxOutputTokens = maxOutputTokensValidation.value
    updatedOptions.openRouterRouting = account?.kind == .openRouter
      ? buildOpenRouterRouting()
      : nil

    let saved = await chats.updateChatSettings(
      conversationID: conversationID,
      systemPrompt: normalizedSystemPrompt,
      options: updatedOptions
    )

    if saved {
      toastCenter?.success("Chat settings saved")
      dismiss()
    } else {
      saveError = chats.errorMessage ?? "Unable to save chat settings."
    }
  }
}
