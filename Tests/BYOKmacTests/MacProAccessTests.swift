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

  @Test("Free Library has ten saved-file slots")
  func libraryLimit() {
    #expect(MacProAccess.canCreateLibraryItem(currentCount: 9, hasPro: false))
    #expect(!MacProAccess.canCreateLibraryItem(currentCount: 10, hasPro: false))
    #expect(MacProAccess.remainingLibraryCapacity(currentCount: 7, hasPro: false) == 3)
    #expect(MacProAccess.remainingLibraryCapacity(currentCount: 10, hasPro: false) == 0)
    #expect(MacProAccess.remainingLibraryCapacity(currentCount: 100, hasPro: true) == nil)
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

  @Test("Free backup restore restricts only restored overflow and frees slots dynamically")
  func restoredOverflowPolicy() {
    let suite = "MacProAccessTests.restoredOverflow.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let restrictions = MacProResourceRestrictions(defaults: defaults, keyPrefix: "test")

    let p1 = ProviderAccountID(rawValue: "p1")
    let p2 = ProviderAccountID(rawValue: "p2")
    let project1 = ProjectID(rawValue: "project-1")
    let project2 = ProjectID(rawValue: "project-2")
    let server1 = MCPServerID(rawValue: "server-1")
    let server2 = MCPServerID(rawValue: "server-2")
    let libraryIDs = (1...11).map { "library-\($0)" }

    restrictions.recordFullBackupImport(
      before: MacProResourceSnapshot(),
      after: MacProResourceSnapshot(
        providerAccountIDs: [p1.rawValue, p2.rawValue],
        projectIDs: [project1.rawValue, project2.rawValue],
        mcpServerIDs: [server1.rawValue, server2.rawValue],
        libraryEntryIDs: libraryIDs
      ),
      strategy: .replaceExisting,
      entitlement: .free
    )

    #expect(!restrictions.isProviderRestricted(p1, currentIDs: [p1, p2], entitlement: .free))
    #expect(restrictions.isProviderRestricted(p2, currentIDs: [p1, p2], entitlement: .free))
    #expect(!restrictions.isProjectRestricted(project1, currentIDs: [project1, project2], entitlement: .free))
    #expect(restrictions.isProjectRestricted(project2, currentIDs: [project1, project2], entitlement: .free))
    #expect(!restrictions.isMCPServerRestricted(server1, currentIDs: [server1, server2], entitlement: .free))
    #expect(restrictions.isMCPServerRestricted(server2, currentIDs: [server1, server2], entitlement: .free))

    let typedLibraryIDs = libraryIDs.map { LibraryEntryID(rawValue: $0) }
    #expect(!restrictions.isLibraryEntryRestricted(typedLibraryIDs[9], currentIDs: typedLibraryIDs, entitlement: .free))
    #expect(restrictions.isLibraryEntryRestricted(typedLibraryIDs[10], currentIDs: typedLibraryIDs, entitlement: .free))

    // Deleting the first restored provider frees the one Free slot for the next
    // restored candidate without deleting or rewriting the backup-restored data.
    #expect(!restrictions.isProviderRestricted(p2, currentIDs: [p2], entitlement: .free))
    #expect(!restrictions.isProjectRestricted(project2, currentIDs: [project2], entitlement: .pro))
  }

  @Test("Merge restore never locks resources that existed before import")
  func mergeRestorePreservesExistingResources() {
    let suite = "MacProAccessTests.mergeRestore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let restrictions = MacProResourceRestrictions(defaults: defaults, keyPrefix: "test")

    let existing = ProviderAccountID(rawValue: "existing")
    let imported = ProviderAccountID(rawValue: "imported")
    restrictions.recordFullBackupImport(
      before: MacProResourceSnapshot(providerAccountIDs: [existing.rawValue]),
      after: MacProResourceSnapshot(providerAccountIDs: [existing.rawValue, imported.rawValue]),
      strategy: .keepExisting,
      entitlement: .free
    )

    #expect(!restrictions.isProviderRestricted(existing, currentIDs: [existing, imported], entitlement: .free))
    #expect(restrictions.isProviderRestricted(imported, currentIDs: [existing, imported], entitlement: .free))
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
  @Test("Provider workspace separates overview, models, and connection")
  func providerWorkspaceTabs() {
    #expect(
      MacProviderDetailTab.allCases.map(\.rawValue)
        == ["Overview", "Models", "Connection"]
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