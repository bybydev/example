import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Testing
@testable import BYOKmac

@MainActor
struct MacProAccessTests {
  @Test("Only the two GitHub themes are Free")
  func themeAccessConfiguration() {
    let configuration = MacThemeFoundation.configuration

    #expect(configuration.themes.count == 13)
    #expect(configuration.defaultThemeID == .githubLight)
    #expect(!configuration.isProTheme(.githubDarkDimmed))
    #expect(!configuration.isProTheme(.githubLight))
    #expect(configuration.isProTheme(.system))
    #expect(configuration.isProTheme(.midnight))
    #expect(configuration.proThemeIDs.count == 11)
  }

  @Test("Free provider accounts stop at one")
  func providerAccountLimit() {
    #expect(MacProAccess.canCreateProviderAccount(currentCount: 0, hasPro: false))
    #expect(!MacProAccess.canCreateProviderAccount(currentCount: 1, hasPro: false))
    #expect(MacProAccess.canCreateProviderAccount(currentCount: 10, hasPro: true))
  }

  @Test("Free projects stop at one")
  func projectLimit() {
    #expect(MacProAccess.canCreateProject(currentCount: 0, hasPro: false))
    #expect(!MacProAccess.canCreateProject(currentCount: 1, hasPro: false))
    #expect(MacProAccess.canCreateProject(currentCount: 10, hasPro: true))
  }

  @Test("Free MCP servers stop at one")
  func mcpLimit() {
    #expect(MacProAccess.canCreateMCPServer(currentCount: 0, hasPro: false))
    #expect(!MacProAccess.canCreateMCPServer(currentCount: 1, hasPro: false))
    #expect(MacProAccess.canCreateMCPServer(currentCount: 10, hasPro: true))
  }

  @Test("Entitlement checking blocks gated creation without treating the user as Free")
  func checkingDecision() {
    #expect(
      MacProAccess.providerAccountCapacityDecision(currentCount: 1, entitlement: .checking)
        == .checking
    )
    #expect(
      MacProAccess.providerAccountCapacityDecision(currentCount: 1, entitlement: .free)
        == .requiresPro
    )
    #expect(
      MacProAccess.providerAccountCapacityDecision(currentCount: 50, entitlement: .pro)
        == .allowed
    )
  }

  @Test("Provider configuration import cannot exceed Free capacity")
  func providerConfigurationImportLimit() {
    let existing = ProviderAccountID(rawValue: "existing")
    let imported = ProviderAccountID(rawValue: "imported")

    #expect(
      MacProAccess.providerConfigurationImportDecision(
        existingIDs: [existing],
        importedIDs: [imported],
        strategy: .keepExisting,
        entitlement: .free
      ) == .requiresPro
    )
    #expect(
      MacProAccess.providerConfigurationImportDecision(
        existingIDs: [existing],
        importedIDs: [imported],
        strategy: .keepExisting,
        entitlement: .checking
      ) == .checking
    )
    #expect(
      MacProAccess.providerConfigurationImportDecision(
        existingIDs: [existing],
        importedIDs: [imported],
        strategy: .keepExisting,
        entitlement: .pro
      ) == .allowed
    )
    #expect(
      MacProAccess.providerConfigurationImportDecision(
        existingIDs: [existing],
        importedIDs: [imported],
        strategy: .replaceExisting,
        entitlement: .free
      ) == .allowed
    )
  }

  @Test("MAF preserves a Pro preference while Free users see the GitHub fallback")
  func themeEntitlementFallback() {
    let suite = "MacProAccessTests.theme.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(MacAppThemeID.midnight.rawValue, forKey: MacThemeFoundation.storageKey)
    let store = MacThemeFoundation.makeStore(defaults: defaults)

    #expect(store.selectedThemeID == .midnight)
    #expect(store.effectiveThemeID(hasPro: false) == .githubLight)
    #expect(store.effectiveThemeID(hasPro: true) == .midnight)
    #expect(defaults.string(forKey: MacThemeFoundation.storageKey) == MacAppThemeID.midnight.rawValue)
  }

  @Test("Legacy BYOKchat theme IDs migrate to MAF IDs")
  func legacyThemeIDMigration() {
    let suite = "MacProAccessTests.themeMigration.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set("githubDarkDimmed", forKey: MacThemeFoundation.storageKey)
    let store = MacThemeFoundation.makeStore(defaults: defaults)

    #expect(store.selectedThemeID == .githubDarkDimmed)
    #expect(
      defaults.string(forKey: MacThemeFoundation.storageKey)
        == MacAppThemeID.githubDarkDimmed.rawValue
    )
  }

  @Test("MacProFeature includes themes and chatSearch with stable IDs and analytics dimensions")
  func proFeatureCatalogAndAnalyticsDimensions() {
    let all = MacProFeature.allCases
    #expect(all.count == 6)
    #expect(all.contains(.themes))
    #expect(all.contains(.chatSearch))
    #expect(all.contains(.providerAccounts))
    #expect(all.contains(.projects))
    #expect(all.contains(.mcpServers))
    #expect(all.contains(.analytics))
    #expect(Set(all.map(\.id)).count == all.count)

    for feature in all {
      #expect(feature.id == feature.rawValue)
    }

    #expect(MacAppAnalytics.Dimension(feature: .themes) == .themes)
    #expect(MacAppAnalytics.Dimension(feature: .chatSearch) == .chatSearch)
    #expect(MacAppAnalytics.Dimension(feature: .providerAccounts) == .providers)
    #expect(MacAppAnalytics.Dimension(feature: .projects) == .projects)
    #expect(MacAppAnalytics.Dimension(feature: .mcpServers) == .mcp)
    #expect(MacAppAnalytics.Dimension(feature: .analytics) == .analyticsHistory)
  }

  @Test("Full-text chat search requires BYOK Pro and respects checking state")
  func chatSearchDecisions() {
    #expect(!MacProAccess.canUseChatSearch(hasPro: false))
    #expect(MacProAccess.canUseChatSearch(hasPro: true))

    #expect(MacProAccess.chatSearchDecision(entitlement: .free) == .requiresPro)
    #expect(MacProAccess.chatSearchDecision(entitlement: .checking) == .checking)
    #expect(MacProAccess.chatSearchDecision(entitlement: .pro) == .allowed)
  }

  @Test("Theme decisions allow GitHub themes for Free and gate Pro themes cleanly")
  func themeDecisions() {
    #expect(!MacThemeFoundation.isProTheme(.githubLight))
    #expect(!MacThemeFoundation.isProTheme(.githubDarkDimmed))
    #expect(MacThemeFoundation.isFreeTheme(.githubLight))
    #expect(MacThemeFoundation.isFreeTheme(.githubDarkDimmed))
    #expect(MacThemeFoundation.isProTheme(.midnight))
    #expect(MacThemeFoundation.isProTheme(.system))

    #expect(MacProAccess.canUseTheme(.githubLight, hasPro: false))
    #expect(MacProAccess.canUseTheme(.githubDarkDimmed, hasPro: false))
    #expect(!MacProAccess.canUseTheme(.midnight, hasPro: false))
    #expect(MacProAccess.canUseTheme(.midnight, hasPro: true))

    #expect(MacProAccess.themeDecision(.githubLight, entitlement: .free) == .allowed)
    #expect(MacProAccess.themeDecision(.githubDarkDimmed, entitlement: .free) == .allowed)
    #expect(MacProAccess.themeDecision(.githubLight, entitlement: .checking) == .allowed)
    #expect(MacProAccess.themeDecision(.githubDarkDimmed, entitlement: .pro) == .allowed)

    #expect(MacProAccess.themeDecision(.midnight, entitlement: .free) == .requiresPro)
    #expect(MacProAccess.themeDecision(.midnight, entitlement: .checking) == .checking)
    #expect(MacProAccess.themeDecision(.midnight, entitlement: .pro) == .allowed)
    #expect(MacProAccess.themeDecision(.system, entitlement: .free) == .requiresPro)
    #expect(MacProAccess.themeDecision(.system, entitlement: .checking) == .checking)
    #expect(MacProAccess.themeDecision(.system, entitlement: .pro) == .allowed)
  }

  @Test("Every Pro feature provides complete Free-vs-Pro upsell metadata")
  func upsellMetadataCompleteness() {
    for feature in MacProFeature.allCases {
      let content = feature.upsellContent
      #expect(!content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(!content.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(!content.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(!content.systemImage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(content.comparisonTitle == "Free vs Pro")
      #expect(!content.comparisonFootnote.isEmpty)
      #expect(content.primaryActionTitle == "See BYOK Pro Plans")
      #expect(content.secondaryActionTitle == "Not Now")
      #expect(content.rows.count == MacProFeature.allCases.count)

      let highlighted = content.rows.filter(\.isHighlighted)
      #expect(highlighted.count == 1)
      #expect(highlighted.first?.id == feature.id)

      for row in content.rows {
        #expect(!row.feature.isEmpty)
        #expect(!row.freeValue.isEmpty)
        #expect(!row.proValue.isEmpty)
        #expect(!row.systemImage.isEmpty)
      }
    }
  }

  @Test("MacProGateCenter separates contextual upsell requests from paywall opens")
  func gateCenterUpsellCoordination() {
    let gate = MacProGateCenter()
    #expect(gate.requestID == 0)
    #expect(gate.upsellRequestID == 0)
    #expect(gate.feature == nil)
    #expect(gate.claimPendingUpsell() == nil)

    gate.request(.chatSearch)
    #expect(gate.feature == .chatSearch)
    #expect(gate.upsellRequestID == 1)
    #expect(gate.requestID == 0)
    #expect(gate.claimPendingUpsell() == .chatSearch)
    #expect(gate.claimPendingUpsell() == nil)

    gate.request(.themes)
    #expect(gate.feature == .themes)
    #expect(gate.upsellRequestID == 2)
    #expect(gate.requestID == 0)
    #expect(gate.claimPendingUpsell() == .themes)

    gate.openPaywall()
    #expect(gate.requestID == 1)
    #expect(gate.claimPendingPaywallOpen())
    #expect(!gate.claimPendingPaywallOpen())
  }

  @Test("Free title search filters titles case- and diacritic-insensitively without message deep links")
  func freeLocalTitleSearch() {
    let conversations = [
      ChatConversation(
        id: ConversationID(rawValue: "c1"),
        title: "Café Architecture Notes",
        providerID: "openai",
        accountID: "acct-1",
        modelID: "gpt-4o"
      ),
      ChatConversation(
        id: ConversationID(rawValue: "c2"),
        title: "Swift Concurrency Review",
        providerID: "openai",
        accountID: "acct-1",
        modelID: "gpt-4o"
      ),
    ]

    #expect(MacSidebarSearchSupport.titleMatches(for: "   ", in: conversations).isEmpty)

    let matches = MacSidebarSearchSupport.titleMatches(for: "cafe", in: conversations)
    #expect(matches.count == 1)
    #expect(matches.first?.conversationID == ConversationID(rawValue: "c1"))
    #expect(matches.first?.messageID == nil)
    #expect(matches.first?.role == .title)
  }
}

@Suite("macOS Library feature")
struct MacLibraryFeatureTests {
  @Test("Kind and source filters match Library entries")
  func filtersMatchEntries() {
    let chatEntry = LibraryEntry(
      filename: "photo.jpg",
      kind: .image,
      mimeType: "image/jpeg",
      byteCount: 128,
      source: .chat(conversationID: "chat-1", messageID: "message-1")
    )
    let projectEntry = LibraryEntry(
      filename: "notes.txt",
      kind: .file,
      mimeType: "text/plain",
      byteCount: 64,
      source: .project("project-1")
    )

    #expect(MacLibraryKindFilter.images.matches(chatEntry))
    #expect(!MacLibraryKindFilter.files.matches(chatEntry))
    #expect(MacLibraryKindFilter.files.matches(projectEntry))
    #expect(MacLibrarySourceFilter.chats.matches(chatEntry))
    #expect(MacLibrarySourceFilter.projects.matches(projectEntry))
    #expect(!MacLibrarySourceFilter.saved.matches(projectEntry))
  }

  @Test("Date grouping keeps recent buckets in display order")
  func dateGrouping() {
    let now = Date()
    let calendar = Calendar.current
    let entries = [
      LibraryEntry(
        filename: "today.txt",
        kind: .file,
        mimeType: "text/plain",
        byteCount: 1,
        createdAt: now
      ),
      LibraryEntry(
        filename: "yesterday.txt",
        kind: .file,
        mimeType: "text/plain",
        byteCount: 1,
        createdAt: calendar.date(byAdding: .day, value: -1, to: now) ?? now
      ),
      LibraryEntry(
        filename: "week.txt",
        kind: .file,
        mimeType: "text/plain",
        byteCount: 1,
        createdAt: calendar.date(byAdding: .day, value: -3, to: now) ?? now
      ),
    ]

    let sections = MacLibraryDateGrouper.sections(for: entries, now: now)
    #expect(sections.map(\.title) == ["Today", "Yesterday", "Previous 7 Days"])
  }
}

@Suite("macOS Projects feature")
struct MacProjectsFeatureTests {
  @Test("Project workspace separates overview, chats, sources, and tools")
  func projectWorkspaceSections() {
    #expect(
      MacProjectWorkspaceSection.allCases.map(\.rawValue)
        == ["Overview", "Chats", "Sources", "Tools"]
    )
  }

  @Test("Project files show byte size and estimated token context")
  func projectFileDetail() {
    let file = ProjectFile(
      filename: "reference.txt",
      mimeType: "text/plain",
      data: Data(repeating: 0x61, count: 4_000)
    )
    let detail = macProjectFileDetail(file)
    #expect(detail.contains("~1,000 tokens") || detail.contains("~1000 tokens"))
    #expect(detail.contains("KB") || detail.contains("kB"))
  }
}

@Suite("macOS AI Providers feature")
struct MacAIProvidersFeatureTests {
  @Test("Provider workspace routes unify inline detail editing with pushed models")
  func providerWorkspaceRoutes() {
    let accountID = ProviderAccountID(rawValue: "acc-1")
    #expect(MacProviderWorkspaceRoute.list != .detail(accountID))
    #expect(MacProviderWorkspaceRoute.detail(accountID) != .models(accountID))
    #expect(
      MacProviderWorkspaceRoute.create(.openai, returnTo: .pickProvider)
        != .create(.anthropic, returnTo: .pickProvider)
    )
  }

  @Test("Provider presentation states remain explicit")
  func providerPresentationStates() {
    #expect(MacProviderPresentationState.ready.rawValue == "Ready")
    #expect(MacProviderPresentationState.disabled.rawValue == "Disabled")
    #expect(MacProviderPresentationState.credentialRequired.rawValue == "Credential required")
    #expect(MacProviderPresentationState.modelRequired.rawValue == "Model required")
  }
}

@Suite("macOS Analytics feature")
struct MacAnalyticsFeatureTests {
  @Test("Analytics workspace separates overview and conversations")
  func workspaceSections() {
    #expect(
      MacAnalyticsWorkspaceSection.allCases.map(\.rawValue)
        == ["Overview", "Conversations"]
    )
  }

  @Test("Analytics utility uses full workspace height")
  func fullHeightUtility() {
    #expect(!MacUtilitySheetDestination.analytics.showsFooter)
  }
}

@Suite("macOS MCP tools parity")
struct MacMCPToolsFeatureTests {
  @Test("Chat and project tool configuration use explicit iOS-parity labels")
  func configurationLabels() {
    let chat = MacMCPConfigurationContext.chat(projectName: "Demo")
    let project = MacMCPConfigurationContext.project

    #expect(chat.enableTitle == "Enable for This Chat")
    #expect(project.enableTitle == "Enable in Project")
    #expect(chat.guidance.contains("New tools default to Ask"))
    #expect(project.guidance.contains("project defaults"))
  }

  @Test("Server detail keeps management concerns separated")
  func serverDetailTabs() {
    #expect(MacMCPServerDetailTab.allCases.map(\.rawValue) == ["Overview", "Tools", "Connection"])
  }

  @Test("Server presentation distinguishes disabled, undiscovered, and discovered states")
  func serverPresentationStates() {
    let endpoint = URL(string: "https://example.com/mcp")!
    let enabled = MCPRemoteServer(name: "Demo", endpoint: endpoint)
    let disabled = MCPRemoteServer(name: "Disabled", endpoint: endpoint, isEnabled: false)
    let snapshot = MCPServerSnapshot(
      serverID: enabled.id,
      protocolVersion: "2025-06-18",
      era: .modern
    )

    #expect(macMCPServerPresentationState(server: disabled, snapshot: nil) == .disabled)
    #expect(macMCPServerPresentationState(server: enabled, snapshot: nil) == .needsDiscovery)
    #expect(macMCPServerPresentationState(server: enabled, snapshot: snapshot) == .discovered)
  }

  @Test("Tool catalog distinguishes discovery, zero-tool, and search empty states")
  func toolCatalogStates() {
    let serverID = MCPServerID(rawValue: "demo")
    let emptySnapshot = MCPServerSnapshot(
      serverID: serverID,
      protocolVersion: "2025-06-18",
      era: .modern
    )
    let toolSnapshot = MCPServerSnapshot(
      serverID: serverID,
      protocolVersion: "2025-06-18",
      era: .modern,
      tools: [
        MCPRemoteTool(
          remoteName: "search",
          description: "Search content",
          inputSchema: .object([:])
        )
      ]
    )

    #expect(macMCPToolCatalogState(snapshot: nil, filteredToolCount: 0, searchText: "") == .notDiscovered)
    #expect(macMCPToolCatalogState(snapshot: emptySnapshot, filteredToolCount: 0, searchText: "") == .noTools)
    #expect(macMCPToolCatalogState(snapshot: toolSnapshot, filteredToolCount: 0, searchText: "missing") == .noSearchResults)
    #expect(macMCPToolCatalogState(snapshot: toolSnapshot, filteredToolCount: 1, searchText: "") == .results)
  }
}