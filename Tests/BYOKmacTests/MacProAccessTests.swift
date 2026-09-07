import BYOKchatProviderCore
import Foundation
import Testing
@testable import BYOKmac

@MainActor
struct MacProAccessTests {
  @Test("Free theme access is limited to two themes")
  func themeLimit() {
    let themes = MacThemeID.allCases
    #expect(themes.count > MacProAccess.freeThemeCount)
    #expect(MacProAccess.canUseTheme(themes[0], hasPro: false))
    #expect(MacProAccess.canUseTheme(themes[1], hasPro: false))
    #expect(!MacProAccess.canUseTheme(themes[2], hasPro: false))
    #expect(MacProAccess.canUseTheme(themes[2], hasPro: true))
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
