import BYOKchatProviderCore
import MacAppFoundation
import SwiftUI

struct MacSettingsView: View {
  let model: MacAppModel
  let purchaseManager: PurchaseManager

  @Environment(\.openWindow) private var openWindow
  @Environment(MacSettingsRouter.self) private var settingsRouter
  @State private var selection: MacSettingsTab = .general

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 218)

      Rectangle()
        .fill(MacDesignTokens.Colors.separator.opacity(0.85))
        .frame(width: 1)

      detail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacDesignTokens.Colors.canvas)
    }
    .frame(minWidth: 900, idealWidth: 940, minHeight: 620, idealHeight: 660)
    .background(MacDesignTokens.Colors.canvas)
    .groupBoxStyle(MacSettingsGroupBoxStyle())
    .onAppear {
      consumeRouterRequest()
      MacAppAnalytics.track(.featureOpened, dimension: .settings)
    }
    .onChange(of: settingsRouter.requestID) { _, _ in
      consumeRouterRequest()
    }
    .macProUpsellPresenter()
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "gearshape.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.accent)
          .frame(width: 28, height: 28)
          .background(
            MacDesignTokens.Colors.accentSoft,
            in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
          )

        Text("Settings")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      }
      .padding(.horizontal, 14)
      .padding(.top, 16)
      .padding(.bottom, 14)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          settingsSidebarSection("Application", tabs: [.general, .theme])
          settingsSidebarSection("Account", tabs: [.plan, .connections])
          settingsSidebarSection("Features", tabs: [.tools])
          settingsSidebarSection("Advanced", tabs: [.data, .diagnostics])
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 14)
      }
      .scrollIndicators(.hidden)

      Spacer(minLength: 0)
    }
    .background(MacDesignTokens.Colors.surface)
  }

  private func settingsSidebarSection(_ sectionTitle: String, tabs: [MacSettingsTab]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(sectionTitle.uppercased())
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.82))
        .tracking(0.55)
        .padding(.horizontal, 9)
        .padding(.bottom, 1)

      ForEach(tabs, id: \.self) { tab in
        MacSettingsSidebarRow(
          title: title(for: tab),
          systemImage: systemImage(for: tab),
          isSelected: selection == tab
        ) {
          selection = tab
        }
      }
    }
  }

  private var detail: some View {
    VStack(spacing: 0) {
      MacSettingsDetailHeader(
        title: title(for: selection),
        subtitle: subtitle(for: selection),
        systemImage: systemImage(for: selection)
      )

      Rectangle()
        .fill(MacDesignTokens.Colors.separator.opacity(0.72))
        .frame(height: 1)

      detailContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    switch selection {
    case .general:
      MacGeneralSettingsView(
        preferences: model.preferences,
        chats: model.chats
      )
    case .plan:
      ZStack {
        MacDesignTokens.Colors.canvas
        ProPlanPane(
          purchaseManager: purchaseManager,
          configuration: MacPurchaseStore.planConfiguration,
          onUpgrade: { openWindow(id: MacWindowID.proPaywall) }
        )
        .padding(20)
        .frame(maxWidth: 760, maxHeight: .infinity)
      }
    case .theme:
      MacAppThemeSettingsPane(
        themeStore: model.themeStore,
        purchaseManager: purchaseManager,
        variant: .compact,
        onUpgrade: {
          MacProAccess.requestUpgrade(.themes)
        }
      )
    case .connections:
      MacConnectionSettingsView(model: model)
    case .tools:
      MacToolsSettingsView(model: model)
    case .data:
      MacDataSettingsView(model: model)
    case .diagnostics:
      MacDiagnosticsSettingsView(model: model)
    }
  }

  private func title(for tab: MacSettingsTab) -> String {
    switch tab {
    case .general: "General"
    case .plan: "Plan"
    case .theme: "Theme"
    case .connections: "Connections"
    case .tools: "Tools"
    case .data: "Data"
    case .diagnostics: "Diagnostics"
    }
  }

  private func subtitle(for tab: MacSettingsTab) -> String {
    switch tab {
    case .general:
      "Chat defaults, privacy, and app information."
    case .plan:
      "Manage BYOK Pro access, purchases, and subscription status."
    case .theme:
      "Choose the color theme used throughout BYOKchat."
    case .connections:
      "Configure the provider accounts used to run chats."
    case .tools:
      "Manage MCP servers and the tools available to conversations."
    case .data:
      "Back up, restore, inspect, or reset local application data."
    case .diagnostics:
      "Inspect local telemetry health, storage, and diagnostic events."
    }
  }

  private func systemImage(for tab: MacSettingsTab) -> String {
    switch tab {
    case .general: "gearshape"
    case .plan: "creditcard"
    case .theme: "paintpalette"
    case .connections: "bolt.horizontal.circle"
    case .tools: "wrench.and.screwdriver"
    case .data: "externaldrive"
    case .diagnostics: "waveform.path.ecg"
    }
  }

  private func consumeRouterRequest() {
    if let tab = settingsRouter.requestedTab {
      selection = tab
    }
  }
}

private struct MacSettingsSidebarRow: View {
  let title: String
  let systemImage: String
  let isSelected: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 9) {
        Image(systemName: systemImage)
          .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(
            isSelected ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted
          )
          .frame(width: 18)

        Text(title)
          .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 9)
      .frame(height: 32)
      .contentShape(Rectangle())
      .background(
        rowBackground,
        in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
      )
      .overlay {
        if isSelected {
          RoundedRectangle(cornerRadius: MacDesignTokens.Radius.small, style: .continuous)
            .stroke(MacDesignTokens.Colors.accent.opacity(0.18), lineWidth: 1)
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityLabel(title)
    .accessibilityValue(isSelected ? "Selected" : "")
  }

  private var rowBackground: Color {
    if isSelected { return MacDesignTokens.Colors.selection }
    if isHovering { return MacDesignTokens.Colors.selection.opacity(0.48) }
    return .clear
  }
}

private struct MacSettingsDetailHeader: View {
  let title: String
  let subtitle: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.accent)
        .frame(width: 34, height: 34)
        .background(
          MacDesignTokens.Colors.accentSoft,
          in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
        )

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        Text(subtitle)
          .font(.system(size: 11.5))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
          .lineLimit(1)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 22)
    .frame(height: 72)
    .background(MacDesignTokens.Colors.canvas)
  }
}

private struct MacSettingsGroupBoxStyle: GroupBoxStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      configuration.label
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)

      configuration.content
        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
    }
    .padding(16)
    .background(
      MacDesignTokens.Colors.surface,
      in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: MacDesignTokens.Radius.large, style: .continuous)
        .stroke(MacDesignTokens.Colors.separator.opacity(0.82), lineWidth: 1)
    }
  }
}

private struct MacGeneralSettingsView: View {
  @Bindable var preferences: MacPreferencesModel
  let chats: MacChatSessionModel?

  @State private var promptDraft: String
  @State private var lastSyncedPrompt: String
  @State private var confirmClearPrompt = false
  @FocusState private var isPromptFocused: Bool

  init(preferences: MacPreferencesModel, chats: MacChatSessionModel?) {
    self.preferences = preferences
    self.chats = chats
    let initial = MacPreferencesModel.normalizedSystemPrompt(preferences.defaultSystemPrompt)
    _promptDraft = State(initialValue: initial)
    _lastSyncedPrompt = State(initialValue: initial)
  }

  private var trimmedPrompt: String {
    MacPreferencesModel.normalizedSystemPrompt(promptDraft)
  }

  private var appVersionSummary: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    return "\(version) (\(build))"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox("Chat") {
          LabeledContent("Keyboard") {
            Text("Return sends · Shift-Return inserts a line")
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
          }
        }

        GroupBox("Default System Prompt") {
          VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
              TextEditor(text: $promptDraft)
                .font(.system(size: 13))
                .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($isPromptFocused)
                .frame(minHeight: 160)
                .padding(8)
                .accessibilityLabel("Default System Prompt")

              if promptDraft.isEmpty {
                Text("e.g. Be concise, direct, and explain trade-offs clearly.")
                  .font(.system(size: 13))
                  .foregroundStyle(MacDesignTokens.Colors.textMuted.opacity(0.65))
                  .padding(.top, 10)
                  .padding(.leading, 13)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .background(
              MacDesignTokens.Colors.codeSurface,
              in: RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: MacDesignTokens.Radius.medium, style: .continuous)
                .stroke(MacDesignTokens.Colors.separator.opacity(0.82), lineWidth: 1)
            }

            HStack(alignment: .center, spacing: 12) {
              Text("Copied into new conversations unless a project defines its own instructions. Existing conversations with messages are unchanged.")
                .font(.caption)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

              Spacer(minLength: 12)

              Button("Clear Prompt", role: .destructive) {
                confirmClearPrompt = true
              }
              .disabled(trimmedPrompt.isEmpty)
            }
          }
        }

        GroupBox("Privacy") {
          VStack(alignment: .leading, spacing: 8) {
            Toggle("Share Anonymous Usage Data", isOn: $preferences.shareUsageData)
              .onChange(of: preferences.shareUsageData) { _, enabled in
                Task { await MacAppAnalytics.setEnabled(enabled) }
              }

            Text("Sends anonymous product usage counters to help improve BYOKchat. Messages, prompts, and file names are never collected.")
              .font(.caption)
              .foregroundStyle(MacDesignTokens.Colors.textMuted)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        GroupBox("About & Legal") {
          VStack(alignment: .leading, spacing: 10) {
            aboutLinkRow(
              title: "Website",
              systemImage: "globe",
              destination: MacPurchaseStore.websiteURL
            )
            aboutLinkRow(
              title: "Contact Us",
              systemImage: "envelope",
              destination: MacPurchaseStore.contactURL
            )
            aboutLinkRow(
              title: "Privacy Policy",
              systemImage: "hand.raised",
              destination: MacPurchaseStore.privacyURL
            )
            aboutLinkRow(
              title: "Terms of Use",
              systemImage: "doc.text",
              destination: MacPurchaseStore.termsURL
            )

            Rectangle()
              .fill(MacDesignTokens.Colors.separator.opacity(0.72))
              .frame(height: 1)

            LabeledContent {
              Text(appVersionSummary)
                .foregroundStyle(MacDesignTokens.Colors.textMuted)
            } label: {
              Label("App Version", systemImage: "info.circle")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(22)
      .frame(maxWidth: 760, alignment: .leading)
    }
    .background(MacDesignTokens.Colors.canvas)
    .confirmationDialog(
      "Clear default system prompt?",
      isPresented: $confirmClearPrompt,
      titleVisibility: .visible
    ) {
      Button("Clear", role: .destructive) {
        isPromptFocused = false
        promptDraft = ""
        commitPromptIfNeeded()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("New conversations will start without a default system prompt.")
    }
    .task(id: promptDraft) {
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      commitPromptIfNeeded()
    }
    .onChange(of: isPromptFocused) { _, focused in
      if !focused {
        promptDraft = trimmedPrompt
        commitPromptIfNeeded()
      }
    }
    .onChange(of: preferences.defaultSystemPrompt) { _, updated in
      let normalized = MacPreferencesModel.normalizedSystemPrompt(updated)
      guard normalized != lastSyncedPrompt else { return }
      lastSyncedPrompt = normalized
      promptDraft = normalized
    }
    .onDisappear {
      commitPromptIfNeeded()
    }
  }

  private func aboutLinkRow(title: String, systemImage: String, destination: URL) -> some View {
    Link(destination: destination) {
      HStack(spacing: 8) {
        Label(title, systemImage: systemImage)
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(MacDesignTokens.Colors.textMuted)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func commitPromptIfNeeded() {
    let normalized = trimmedPrompt
    let previous = MacPreferencesModel.normalizedSystemPrompt(preferences.defaultSystemPrompt)
    lastSyncedPrompt = normalized
    if preferences.defaultSystemPrompt != normalized {
      preferences.defaultSystemPrompt = normalized
    }
    if previous != normalized {
      Task {
        await chats?.syncDefaultSystemPrompt(from: previous, to: normalized)
      }
    }
  }
}

private struct MacConnectionSettingsView: View {
  let model: MacAppModel
  @State private var showingConnections = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let providers = model.providers {
          GroupBox("Provider Connections") {
            HStack(alignment: .center, spacing: 18) {
              VStack(alignment: .leading, spacing: 5) {
                Text("\(providers.accounts.count) configured connection\(providers.accounts.count == 1 ? "" : "s")")
                  .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                Text("Provider credentials stay in Keychain and are used only when you send a request.")
                  .font(.caption)
                  .foregroundStyle(MacDesignTokens.Colors.textMuted)
              }
              Spacer(minLength: 20)
              Button("Manage Connections…") {
                showingConnections = true
              }
            }
          }
        } else {
          ContentUnavailableView(
            "Connections Unavailable",
            systemImage: "bolt.slash",
            description: Text("Finish app startup before editing provider connections.")
          )
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        }
      }
      .padding(22)
      .frame(maxWidth: 760, alignment: .leading)
    }
    .background(MacDesignTokens.Colors.canvas)
    .sheet(isPresented: $showingConnections) {
      if let providers = model.providers {
        MacProviderManagementView(model: providers)
          .macProUpsellPresenter()
      }
    }
  }
}

private struct MacToolsSettingsView: View {
  let model: MacAppModel
  @State private var showingServers = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let mcp = model.mcp {
          GroupBox("MCP Servers") {
            VStack(alignment: .leading, spacing: 12) {
              HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                  Text("\(mcp.servers.count) configured server\(mcp.servers.count == 1 ? "" : "s")")
                    .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                  Text("Tools are enabled per chat or inherited from Projects.")
                    .font(.caption)
                    .foregroundStyle(MacDesignTokens.Colors.textMuted)
                }
                Spacer(minLength: 20)
                Button("Manage MCP Servers…") {
                  showingServers = true
                }
              }

              if !mcp.servers.isEmpty {
                Rectangle()
                  .fill(MacDesignTokens.Colors.separator.opacity(0.72))
                  .frame(height: 1)

                VStack(spacing: 9) {
                  ForEach(mcp.servers.prefix(6)) { server in
                    HStack(spacing: 9) {
                      Image(systemName: server.isEnabled ? "shippingbox.fill" : "shippingbox")
                        .foregroundStyle(
                          server.isEnabled ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted
                        )
                        .frame(width: 18)
                      Text(server.name)
                        .foregroundStyle(MacDesignTokens.Colors.textPrimary)
                      Spacer()
                      Text("\(mcp.snapshot(for: server.id)?.tools.count ?? 0) tools")
                        .font(.caption)
                        .foregroundStyle(MacDesignTokens.Colors.textMuted)
                    }
                  }
                }
              }
            }
          }
        } else {
          ContentUnavailableView(
            "Tools Unavailable",
            systemImage: "wrench.and.screwdriver",
            description: Text("Finish app startup before configuring MCP servers.")
          )
          .foregroundStyle(MacDesignTokens.Colors.textPrimary)
        }
      }
      .padding(22)
      .frame(maxWidth: 760, alignment: .leading)
    }
    .background(MacDesignTokens.Colors.canvas)
    .sheet(isPresented: $showingServers) {
      if let mcp = model.mcp {
        MacMCPServerListView(mcp: mcp)
          .macProUpsellPresenter()
      }
    }
  }
}

private struct MacDataSettingsView: View {
  let model: MacAppModel

  var body: some View {
    if let data = model.dataManagement {
      MacDataManagementView(app: model, data: data)
    } else {
      ContentUnavailableView(
        "Data Management Unavailable",
        systemImage: "externaldrive.badge.exclamationmark",
        description: Text("Finish app startup before importing, exporting, or resetting data.")
      )
      .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(MacDesignTokens.Colors.canvas)
    }
  }
}

private struct MacDiagnosticsSettingsView: View {
  let model: MacAppModel

  var body: some View {
    if let diagnostics = model.diagnostics {
      MacDiagnosticsView(diagnostics: diagnostics)
    } else {
      ContentUnavailableView(
        "Diagnostics Unavailable",
        systemImage: "waveform.path.ecg.rectangle",
        description: Text("Finish app startup before inspecting local diagnostics.")
      )
      .foregroundStyle(MacDesignTokens.Colors.textPrimary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(MacDesignTokens.Colors.canvas)
    }
  }
}
