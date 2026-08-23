import AppFoundation
import BYOKchatProviderCore
import SwiftUI
import UIKit

extension ChatView {
  @ViewBuilder
  func chatContent(_ conversation: ChatConversation) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          LazyVStack(spacing: 24) {
            if let issue = configurationIssue(conversation) {
              RepairBanner(message: issue) { showTargetSettings = true }
            }

            if conversation.lastContextOmittedMessageCount > 0 {
              Label(
                "\(conversation.lastContextOmittedMessageCount) earlier messages were omitted from the latest request.",
                systemImage: "text.badge.minus"
              )
              .font(.system(size: 12))
              .foregroundStyle(theme.secondaryForegroundColor)
              .frame(maxWidth: .infinity, alignment: .leading)
            }

            if conversation.messages.isEmpty {
              VStack(spacing: 12) {
                Text("How can I help?")
                  .font(.system(size: 30, weight: .semibold))
                Text("Using \(targetLabel(conversation))")
                  .font(.system(size: 14))
                  .foregroundStyle(theme.secondaryForegroundColor)
              }
              .frame(maxWidth: .infinity)
              .padding(.top, 112)
            } else {
              ForEach(conversation.messages) { stored in
                let displayed = chats.displayMessage(stored)
                VStack(alignment: .leading, spacing: 10) {
                  ChatMessageView(
                    message: displayed,
                    accountLabel: accountLabel(for: stored),
                    failureContext: failureContextLabel(for: stored),
                    canEdit: stored.role == .user && !chats.isGenerating(conversationID),
                    canRegenerate: stored.id == latestAssistantID
                      && !chats.isGenerating(conversationID),
                    edit: {
                      editText = stored.content
                      editTarget = stored
                    },
                    regenerate: regenerate,
                    copy: { UIPasteboard.general.string = displayed.content }
                  )

                  if stored.role == .assistant,
                    let rounds = displayed.toolRounds,
                    !rounds.isEmpty
                  {
                    ForEach(rounds) { round in
                      ChatToolRoundView(
                        round: round,
                        displayName: { mcp.toolDisplayName($0) }
                      )
                    }
                  }
                }
                .id(stored.id)
              }
            }

            let approvals = mcp.pendingApprovals(for: conversationID)
            let approvalCallIDs = Set(approvals.map(\.callID))
            ForEach(approvals) { request in
              MCPToolApprovalCard(request: request) { decision in
                Task { @MainActor in
                  await mcp.resolveApproval(request.id, decision: decision)
                }
              }
            }

            ForEach(mcp.pendingElicitations(for: conversationID)) { request in
              MCPElicitationCard(request: request) { decision in
                Task { @MainActor in
                  await mcp.resolveElicitation(request.id, decision: decision)
                }
              }
            }

            ForEach(chats.activeToolCalls(for: conversationID)) { call in
              MCPToolRunningCard(
                call: call,
                displayName: mcp.toolDisplayName(call.name),
                isWaitingForApproval: approvalCallIDs.contains(call.id)
              )
            }
          }
          .padding(.horizontal, 20)
          .padding(.top, 14)
          .padding(.bottom, 18)

          Color.clear
            .frame(height: 1)
            .onScrollVisibilityChange(threshold: 0.01) { isVisible in
              isNearBottom = isVisible
              if isVisible {
                followsLatest = true
                showJumpToLatest = false
              } else if hasCompletedInitialScroll && isUserDraggingTimeline {
                followsLatest = false
                showJumpToLatest = true
              }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
          dismissKeyboard()
        }
      }
      .defaultScrollAnchor(
        initialScrollMessageID == nil ? UnitPoint.bottom : nil,
        for: .initialOffset
      )
      .scrollPosition($chatScrollPosition)
      .scrollDismissesKeyboard(.interactively)
      .onScrollPhaseChange { _, newPhase in
        switch newPhase {
        case .tracking, .interacting, .decelerating:
          isUserDraggingTimeline = true
          if !isNearBottom {
            followsLatest = false
            showJumpToLatest = true
          }
        case .idle:
          let wasUserDriven = isUserDraggingTimeline
          isUserDraggingTimeline = false
          if isNearBottom {
            followsLatest = true
            showJumpToLatest = false
          } else if wasUserDriven {
            followsLatest = false
            showJumpToLatest = true
          }
        case .animating:
          isUserDraggingTimeline = false
        @unknown default:
          break
        }
      }
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentSize.height
      } action: { oldHeight, newHeight in
        guard oldHeight != newHeight,
          hasCompletedInitialScroll,
          followsLatest,
          !isUserDraggingTimeline,
          chats.isGenerating(conversationID)
        else { return }

        scrollToBottom(proxy, animated: false)
      }
      .onChange(of: chats.isGenerating(conversationID)) { _, generating in
        if generating {
          followsLatest = true
          showJumpToLatest = false
        } else if !isNearBottom {
          showJumpToLatest = true
        }
      }
      .task(id: conversationID) {
        hasCompletedInitialScroll = false
        followsLatest = initialScrollMessageID == nil
        showJumpToLatest = initialScrollMessageID != nil

        guard initialScrollMessageID != nil else {
          await Task.yield()
          hasCompletedInitialScroll = true
          return
        }

        await Task.yield()
        scrollToInitialTarget(proxy)

        do {
          try await Task.sleep(for: .milliseconds(32))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        scrollToInitialTarget(proxy)
        hasCompletedInitialScroll = true
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 4) {
          if showJumpToLatest {
            Button {
              followsLatest = true
              isUserDraggingTimeline = false
              showJumpToLatest = false
              scrollToBottom(proxy)
            } label: {
              Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondaryForegroundColor)
                .frame(width: 32, height: 32)
                .glassEffect(.clear, in: Circle())
                .overlay(Circle().stroke(.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .zIndex(10)
            .accessibilityLabel("Scroll to bottom of chat")
          }

          ChatInputComposer(
            draft: $draft,
            attachments: pendingAttachments,
            isGenerating: chats.isGenerating(conversationID),
            canSend: configurationIssue(conversation) == nil,
            conversation: conversation,
            chats: chats,
            providers: providers,
            openChatSettings: { showTargetSettings = true },
            pickPhoto: { showPhotoPicker = true },
            pickFile: { showFileImporter = true },
            removeAttachment: removePendingAttachment,
            send: send,
            stop: {
              Task { @MainActor in
                await chats.stop(conversationID)
              }
            }
          )
        }
      }
    }
  }

  private func scrollToInitialTarget(_ proxy: ScrollViewProxy) {
    guard let initialScrollMessageID else { return }
    proxy.scrollTo(initialScrollMessageID, anchor: .center)
  }

  private func send() {
    let text = draft
    let attachments = pendingAttachments
    draft = ""
    pendingAttachments = []
    followsLatest = true
    showJumpToLatest = false
    chats.send(
      conversationID: conversationID,
      text: text,
      attachments: attachments
    )
  }

  private func regenerate() {
    followsLatest = true
    showJumpToLatest = false
    if chats.latestAssistantRequiresRegenerationConfirmation(conversationID) {
      showRegenerateConfirmation = true
    } else {
      chats.regenerate(conversationID: conversationID)
    }
  }

  private func targetLabel(_ conversation: ChatConversation) -> String {
    let accountName = providers.accounts.first(where: { $0.id == conversation.accountID })?.label
      ?? conversation.providerID.rawValue
    let modelName = providers.models(for: conversation.accountID, includeHidden: true)
      .first(where: { $0.model.id == conversation.modelID })?.model.displayName
      ?? conversation.modelID.rawValue
    return "\(accountName) · \(modelName)"
  }

  private func accountLabel(for message: ChatMessage) -> String? {
    guard let accountID = message.accountID else { return nil }
    return providers.accounts.first { $0.id == accountID }?.label
  }

  /// Remote failures name the connection that rejected the request: provider
  /// and model, with the account label only when one provider has several
  /// accounts and the label is the only way to tell them apart. Local failures
  /// never reached an account, so they get no context line at all.
  private func failureContextLabel(for message: ChatMessage) -> String? {
    guard message.status == .failed, message.failureOrigin == .remote else { return nil }
    guard let accountID = message.accountID,
      let account = providers.accounts.first(where: { $0.id == accountID })
    else { return nil }

    var parts: [String] = []
    if providers.accounts.filter({ $0.providerID == account.providerID }).count > 1 {
      parts.append(account.label)
    }
    parts.append(
      providers.provider(for: account.providerID)?.displayName ?? account.providerID.rawValue
    )

    if let modelID = message.modelID {
      let modelName = providers.models(for: account.id, includeHidden: true)
        .first(where: { $0.model.id == modelID })?.model.displayName
      parts.append(modelName ?? modelID.rawValue)
    }
    return parts.joined(separator: " · ")
  }

  private func configurationIssue(_ conversation: ChatConversation) -> String? {
    guard providers.definitions.contains(where: { $0.id == conversation.providerID }) else {
      return "This conversation references a provider that is no longer configured."
    }
    guard let account = providers.accounts.first(where: { $0.id == conversation.accountID }) else {
      return "The provider account used by this conversation was deleted. Select another account to continue."
    }
    guard account.isEnabled else {
      return "The selected provider account is disabled."
    }
    guard
      providers.credentialAccountIDs.contains(account.id)
        || providers.provider(for: account.providerID)?.authentication == ProviderAuthentication.none
    else {
      return "The selected account is missing its credential."
    }
    guard
      let model = providers.models(for: account.id, includeHidden: true).first(where: {
        $0.model.id == conversation.modelID
      })
    else {
      return "The selected model is missing. Choose another model to continue."
    }
    guard model.isAvailable else {
      return "The selected model is no longer reported by the provider."
    }
    return nil
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }

  private func scrollToBottom(_: ScrollViewProxy, animated: Bool = true) {
    if animated {
      withAnimation(.easeOut(duration: 0.18)) {
        chatScrollPosition.scrollTo(edge: .bottom)
      }
    } else {
      chatScrollPosition.scrollTo(edge: .bottom)
    }
  }
}

private struct MCPToolApprovalCard: View {
  let request: MCPToolApprovalRequest
  let resolve: (MCPToolApprovalDecision) -> Void

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: request.destructiveHint == true ? "exclamationmark.shield" : "hand.raised")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(request.destructiveHint == true ? Color.orange : Color.primary)
          .frame(width: 28, height: 28)

        VStack(alignment: .leading, spacing: 3) {
          Text("Allow tool call?")
            .font(.system(size: 15, weight: .semibold))
          Text("\(request.serverName) · \(request.displayName)")
            .font(.system(size: 13, weight: .medium))
          Text(request.toolDescription)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryForegroundColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack(spacing: 7) {
        if request.readOnlyHint == true {
          Label("Read-only", systemImage: "eye")
        }
        if request.destructiveHint == true {
          Label("Destructive", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(theme.secondaryForegroundColor)

      DisclosureGroup("Arguments") {
        Text(request.arguments.prettyJSONString())
          .font(.system(size: 11, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 6)
      }
      .font(.system(size: 12, weight: .semibold))

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          denyButton
          Spacer(minLength: 4)
          allowOnceButton
          alwaysAllowButton
        }
        VStack(spacing: 8) {
          HStack(spacing: 8) {
            denyButton
            allowOnceButton
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
          alwaysAllowButton.frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
      .font(.system(size: 13, weight: .semibold))
    }
    .padding(14)
    .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(
          request.destructiveHint == true ? Color.orange.opacity(0.35) : theme.borderColor,
          lineWidth: 0.8
        )
    )
  }

  private var denyButton: some View {
    Button("Deny", role: .destructive) { resolve(.deny) }.buttonStyle(.bordered)
  }

  private var allowOnceButton: some View {
    Button("Allow Once") { resolve(.allowOnce) }.buttonStyle(.bordered)
  }

  private var alwaysAllowButton: some View {
    Button("Always Allow") { resolve(.alwaysAllow) }.buttonStyle(.borderedProminent)
  }
}

private struct MCPToolRunningCard: View {
  let call: ChatToolCall
  let displayName: String
  let isWaitingForApproval: Bool

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    HStack(spacing: 10) {
      ProgressView().controlSize(.small)
      VStack(alignment: .leading, spacing: 2) {
        Text(isWaitingForApproval ? "Waiting for approval" : "Tool requested")
          .font(.system(size: 12, weight: .semibold))
        Text(displayName)
          .font(.system(size: 12))
          .foregroundStyle(theme.secondaryForegroundColor)
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      theme.surfaceColor,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.75)
    )
  }
}

private struct ChatToolRoundView: View {
  let round: ChatToolRound
  let displayName: (String) -> String

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(round.calls) { call in
        let result = round.results.first { $0.callID == call.id }
        toolCard(call, result: result)
      }
    }
  }

  private func toolCard(_ call: ChatToolCall, result: ChatToolResult?) -> some View {
    let failed = result?.isError == true || result == nil
    return DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Arguments").font(.caption.weight(.semibold))
          Text(call.arguments.prettyJSONString())
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
        }
        if let result {
          VStack(alignment: .leading, spacing: 4) {
            Text(result.isError ? "Error" : "Result").font(.caption.weight(.semibold))
            Text(result.content.prettyJSONString())
              .font(.system(size: 11, design: .monospaced))
              .textSelection(.enabled)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
          .foregroundStyle(failed ? Color.orange : theme.secondaryForegroundColor)
        Text(displayName(call.name))
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(2)
        Spacer()
        Text(failed ? "Failed" : "Done")
          .font(.system(size: 11))
          .foregroundStyle(theme.secondaryForegroundColor)
      }
    }
    .tint(theme.secondaryForegroundColor)
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(
      theme.surfaceColor,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.75)
    )
  }
}

private struct MCPElicitationCard: View {
  let request: MCPElicitationRequest
  let resolve: (MCPElicitationDecision) -> Void

  @State private var textValues: [String: String]
  @State private var boolValues: [String: Bool]

  @Environment(\.appFoundationTheme) private var theme

  init(request: MCPElicitationRequest, resolve: @escaping (MCPElicitationDecision) -> Void) {
    self.request = request
    self.resolve = resolve
    var text: [String: String] = [:]
    var bools: [String: Bool] = [:]
    for field in request.fields {
      switch (field.kind, field.defaultValue) {
      case (.boolean, .bool(let value)): bools[field.name] = value
      case (.string, .string(let value)): text[field.name] = value
      case (.integer, .number(let value)), (.number, .number(let value)):
        text[field.name] = String(value)
      case (.stringArray, .array(let values)):
        text[field.name] = values.compactMap {
          if case .string(let value) = $0 { return value }
          return nil
        }.joined(separator: ", ")
      default:
        if field.kind == .boolean { bools[field.name] = false }
      }
    }
    _textValues = State(initialValue: text)
    _boolValues = State(initialValue: bools)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("\(request.serverName) needs input", systemImage: "text.bubble")
        .font(.system(size: 14, weight: .semibold))
      Text(request.message)
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)

      switch request.mode {
      case .form:
        formFields
      case .url:
        if let url = request.url {
          VStack(alignment: .leading, spacing: 8) {
            Text("Complete the requested step in your browser, then return here.")
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
            Link(destination: url) {
              Label("Open Link", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          Button("Cancel") { resolve(.cancel) }.buttonStyle(.bordered)
          Button("Decline", role: .destructive) { resolve(.decline) }.buttonStyle(.bordered)
          Spacer()
          submitButton
        }
        VStack(alignment: .trailing, spacing: 8) {
          HStack(spacing: 8) {
            Button("Cancel") { resolve(.cancel) }.buttonStyle(.bordered)
            Button("Decline", role: .destructive) { resolve(.decline) }.buttonStyle(.bordered)
          }
          submitButton
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
      .font(.system(size: 13, weight: .semibold))
    }
    .padding(14)
    .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 0.8)
    )
  }

  private var submitButton: some View {
    Button(request.mode == .url ? "Continue" : "Submit") {
      resolve(.accept(responseContent()))
    }
    .buttonStyle(.borderedProminent)
    .disabled(!canSubmit)
  }

  @ViewBuilder
  private var formFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(request.fields) { field in
        switch field.kind {
        case .boolean:
          Toggle(
            field.displayName,
            isOn: Binding(
              get: { boolValues[field.name] ?? false },
              set: { boolValues[field.name] = $0 }
            )
          )
        case .string where !field.allowedValues.isEmpty:
          Picker(
            field.displayName,
            selection: Binding(
              get: { textValues[field.name] ?? field.allowedValues.first ?? "" },
              set: { textValues[field.name] = $0 }
            )
          ) {
            ForEach(field.allowedValues, id: \.self) { value in Text(value).tag(value) }
          }
        default:
          TextField(
            field.isRequired ? field.displayName : "\(field.displayName) (optional)",
            text: Binding(
              get: { textValues[field.name] ?? "" },
              set: { textValues[field.name] = $0 }
            )
          )
          .textFieldStyle(.roundedBorder)
          .keyboardType(field.kind == .integer || field.kind == .number ? .decimalPad : .default)
        }
        if let description = field.description, !description.isEmpty {
          Text(description).font(.caption2).foregroundStyle(theme.secondaryForegroundColor)
        }
      }
    }
  }

  private var canSubmit: Bool {
    guard request.mode == .form else { return request.url != nil }
    for field in request.fields {
      let raw = (textValues[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if field.isRequired, field.kind != .boolean, raw.isEmpty { return false }
      if raw.isEmpty { continue }
      switch field.kind {
      case .integer:
        guard Int(raw) != nil else { return false }
      case .number:
        guard let value = Double(raw), value.isFinite else { return false }
      case .string, .boolean, .stringArray:
        break
      }
    }
    return true
  }

  private func responseContent() -> [String: JSONValue] {
    var values: [String: JSONValue] = [:]
    for field in request.fields {
      switch field.kind {
      case .boolean:
        values[field.name] = .bool(boolValues[field.name] ?? false)
      case .integer:
        if let value = Int(textValues[field.name] ?? "") { values[field.name] = .number(Double(value)) }
      case .number:
        if let value = Double(textValues[field.name] ?? ""), value.isFinite { values[field.name] = .number(value) }
      case .string:
        let value = textValues[field.name] ?? ""
        if !value.isEmpty || field.isRequired { values[field.name] = .string(value) }
      case .stringArray:
        let value = (textValues[field.name] ?? "")
          .split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .map(JSONValue.string)
        if !value.isEmpty || field.isRequired { values[field.name] = .array(value) }
      }
    }
    return values
  }
}

private extension JSONValue {
  func prettyJSONString() -> String {
    if case .string(let value) = self { return value }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let encoded = try? encoder.encode(self),
      let object = try? JSONSerialization.jsonObject(with: encoded),
      JSONSerialization.isValidJSONObject(object),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      ),
      let value = String(data: pretty, encoding: .utf8)
    else {
      return String(describing: self)
    }
    return value
  }
}
