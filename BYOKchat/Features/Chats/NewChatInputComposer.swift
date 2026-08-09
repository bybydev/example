import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct NewChatTargetSelection: Equatable {
  let accountID: ProviderAccountID
  let modelID: ModelID
  let reasoning: ReasoningOptions?
}

struct NewChatInputComposer: View {
  @Binding var draft: String
  let attachments: [ChatAttachment]
  let isCreating: Bool
  let canSend: Bool
  let targetSummary: String
  let targetDetails: String
  let openTarget: () -> Void
  let pickPhoto: () -> Void
  let pickFile: () -> Void
  let removeAttachment: (String) -> Void
  let send: () -> Void

  @Environment(\.appFoundationTheme) private var theme
  @FocusState private var isEditorFocused: Bool
  @State private var isExpanded = false

  private var normalizedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSubmit: Bool {
    canSend && (!normalizedDraft.isEmpty || !attachments.isEmpty)
  }

  private var isCompact: Bool {
    !isExpanded && !isEditorFocused && attachments.isEmpty && normalizedDraft.isEmpty && !isCreating
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
    .onChange(of: isEditorFocused) { _, focused in
      if !focused && attachments.isEmpty && normalizedDraft.isEmpty && !isCreating {
        isExpanded = false
      }
    }
    .onChange(of: isCreating) { _, creating in
      if creating {
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
    Button(action: openTarget) {
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
    .disabled(isCreating)
    .accessibilityLabel("Change provider, model, and reasoning. Currently \(targetDetails)")
    .accessibilityValue(targetSummary)
  }

  private var sendButton: some View {
    Button {
      send()
      isEditorFocused = false
    } label: {
      Group {
        if isCreating {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "arrow.up")
            .font(.system(size: 15, weight: .bold))
        }
      }
      .frame(width: 40, height: 40)
      .background(canSubmit ? theme.accentColor : theme.surfaceColor, in: Circle())
      .foregroundStyle(canSubmit ? theme.backgroundColor : theme.secondaryForegroundColor)
    }
    .buttonStyle(.plain)
    .disabled(isCreating || !canSubmit)
    .accessibilityLabel(isCreating ? "Creating chat" : "Send message")
  }

  private func expandAndFocus() {
    isExpanded = true
    Task { @MainActor in
      await Task.yield()
      isEditorFocused = true
    }
  }
}

struct NewChatTargetPickerView: View {
  let initialAccountID: ProviderAccountID
  let initialModelID: ModelID
  let initialReasoning: ReasoningOptions?
  @Bindable var providers: ProviderManagementModel
  let useSelection: (NewChatTargetSelection) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var accountID: ProviderAccountID
  @State private var modelID: ModelID
  @State private var reasoningEnabled: Bool
  @State private var reasoningEffort: ReasoningEffort

  init(
    initialAccountID: ProviderAccountID,
    initialModelID: ModelID,
    initialReasoning: ReasoningOptions?,
    providers: ProviderManagementModel,
    useSelection: @escaping (NewChatTargetSelection) -> Void
  ) {
    self.initialAccountID = initialAccountID
    self.initialModelID = initialModelID
    self.initialReasoning = initialReasoning
    self.providers = providers
    self.useSelection = useSelection
    _accountID = State(initialValue: initialAccountID)
    _modelID = State(initialValue: initialModelID)
    _reasoningEnabled = State(initialValue: initialReasoning?.enabled ?? false)
    _reasoningEffort = State(initialValue: initialReasoning?.effort ?? .high)
  }

  private var accounts: [ProviderAccount] {
    providers.accounts.filter(\.isEnabled)
  }

  private var selectedAccount: ProviderAccount? {
    accounts.first { $0.id == accountID }
  }

  private var models: [AccountModelRecord] {
    providers.models(for: accountID)
  }

  private var selectedModel: AccountModelRecord? {
    models.first { $0.model.id == modelID }
  }

  private var supportsReasoning: Bool {
    let parameters = selectedModel?.model.supportedParameters ?? []
    return !parameters.isDisjoint(with: [
      "reasoning", "thinking", "reasoning_effort", "thinkingConfig", "effort",
    ])
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Provider") {
          ForEach(accounts) { account in
            Button {
              selectAccount(account)
            } label: {
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(account.label)
                    .foregroundStyle(.primary)
                  if let provider = providers.provider(for: account.providerID),
                    provider.displayName != account.label
                  {
                    Text(provider.displayName)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
                Spacer()
                if account.id == accountID {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }

        Section("Model") {
          NavigationLink {
            NewChatModelPickerView(
              accountID: accountID,
              selection: $modelID,
              providers: providers
            )
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(selectedModel?.model.displayName ?? modelID.rawValue)
                .font(.body.weight(.medium))
                .lineLimit(2)
              Text(selectedModel?.model.id.rawValue ?? modelID.rawValue)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }

        if supportsReasoning {
          Section("Reasoning") {
            Toggle("Reasoning", isOn: $reasoningEnabled)
            if reasoningEnabled {
              Picker("Effort", selection: $reasoningEffort) {
                ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                  Text(reasoningTitle(effort)).tag(effort)
                }
              }
            }
          }
        }
      }
      .navigationTitle("Choose Model")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Use") { save() }
            .disabled(selectedAccount == nil || selectedModel?.isAvailable != true)
        }
      }
      .onChange(of: modelID) { _, _ in normalizeReasoning() }
    }
  }

  private func selectAccount(_ account: ProviderAccount) {
    guard account.id != accountID else { return }
    accountID = account.id
    modelID =
      account.defaultModelID
      ?? providers.models(for: account.id).first(where: \.isAvailable)?.model.id
      ?? providers.models(for: account.id).first?.model.id
      ?? modelID
    normalizeReasoning()
  }

  private func normalizeReasoning() {
    guard supportsReasoning else {
      reasoningEnabled = false
      return
    }
    reasoningEnabled = true
    reasoningEffort = selectedAccount?.providerID == BuiltInProviders.geminiID ? .medium : .high
  }

  private func save() {
    guard selectedAccount != nil, selectedModel?.isAvailable == true else { return }
    let reasoning = supportsReasoning && reasoningEnabled
      ? ReasoningOptions(enabled: true, effort: reasoningEffort)
      : nil
    useSelection(
      NewChatTargetSelection(
        accountID: accountID,
        modelID: modelID,
        reasoning: reasoning
      )
    )
    dismiss()
  }

  private func reasoningTitle(_ effort: ReasoningEffort) -> String {
    switch effort {
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .max: "Max"
    }
  }
}

private struct NewChatModelPickerView: View {
  let accountID: ProviderAccountID
  @Binding var selection: ModelID
  @Bindable var providers: ProviderManagementModel

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private var records: [AccountModelRecord] {
    let all = providers.models(for: accountID)
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return all }
    return all.filter { record in
      record.model.displayName.localizedCaseInsensitiveContains(trimmed)
        || record.model.id.rawValue.localizedCaseInsensitiveContains(trimmed)
    }
  }

  var body: some View {
    List(records) { record in
      Button {
        guard record.isAvailable else { return }
        selection = record.model.id
        dismiss()
      } label: {
        HStack(alignment: .top, spacing: 10) {
          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
              Text(record.model.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
              if record.model.id == selection {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
              }
            }
            Text(record.model.id.rawValue)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!record.isAvailable)
    }
    .navigationTitle("Models")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search models")
  }
}
