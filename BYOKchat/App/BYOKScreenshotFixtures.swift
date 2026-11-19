import BYOKchatProviderCore
import Foundation
import Security

enum BYOKScreenshotFixtures {
  static let launchArgument = "UI_TEST_SCREENSHOTS"

  static let launchConversationID: ConversationID = "screenshot-launch-chat"
  static let researchConversationID: ConversationID = "screenshot-research-chat"
  static let travelConversationID: ConversationID = "screenshot-travel-chat"

  static let anthropicAccountID: ProviderAccountID = "screenshot-anthropic"
  static let openRouterAccountID: ProviderAccountID = "screenshot-openrouter"
  static let geminiAccountID: ProviderAccountID = "screenshot-gemini"

  private static let launchProjectID: ProjectID = "screenshot-project-launch"
  private static let researchProjectID: ProjectID = "screenshot-project-research"
  private static let travelProjectID: ProjectID = "screenshot-project-travel"

  private static let webServerID: MCPServerID = "screenshot-web"
  private static let githubServerID: MCPServerID = "screenshot-github"

  static var isEnabled: Bool {
    ProcessInfo.processInfo.arguments.contains(launchArgument)
  }

  static func prepareIfNeeded() {
    guard isEnabled else { return }

    do {
      let now = Date()
      prepareDefaults()
      try prepareCredentials()
      try writeFixtures(now: now)
    } catch {
      fatalError("Unable to prepare BYOK screenshot fixtures: \(error)")
    }
  }

  private static func prepareDefaults() {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: "byokchat.onboarding.completed.v1")
    defaults.set(true, forKey: "byokchat.developer.simulatedPurchases")
    defaults.removeObject(forKey: "byokchat.simulatedPurchases")
    defaults.removeObject(forKey: "byokchat.themeState.v1")
    defaults.set(launchConversationID.rawValue, forKey: "byokchat.sidebar.pinnedConversationIDs")
    defaults.set(25.0, forKey: "byokchat.usage.monthlyBudgetUSD")
    defaults.set(0.8, forKey: "byokchat.usage.budgetWarningFraction")
  }

  private static func prepareCredentials() throws {
    for accountID in [anthropicAccountID, openRouterAccountID, geminiAccountID] {
      try writeFixtureCredential(accountID: accountID)
    }
  }

  private static func writeFixtureCredential(accountID: ProviderAccountID) throws {
    let service = "com.hoangbkit.byokchat.credentials"
    let account = "\(accountID.rawValue):\(ProviderAccountManager.apiKeyField)"
    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrGeneric as String: Data(accountID.rawValue.utf8),
    ]

    let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
    guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
      throw FixtureError.keychain(deleteStatus)
    }

    var insert = baseQuery
    insert[kSecValueData as String] = Data("byok-screenshot-key".utf8)
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let insertStatus = SecItemAdd(insert as CFDictionary, nil)
    guard insertStatus == errSecSuccess else {
      throw FixtureError.keychain(insertStatus)
    }
  }

  private static func writeFixtures(now: Date) throws {
    let supportDirectory = try supportDirectory()
    try FileManager.default.createDirectory(
      at: supportDirectory,
      withIntermediateDirectories: true
    )

    try encode(providerState(now: now))
      .write(to: supportDirectory.appendingPathComponent("providers-v1.json"), options: .atomic)
    let conversationsDirectory = supportDirectory
      .appendingPathComponent("conversations-v1", isDirectory: true)
    try FileManager.default.createDirectory(
      at: conversationsDirectory,
      withIntermediateDirectories: true
    )
    for conversation in conversationState(now: now).conversations {
      try encode(conversation).write(
        to: conversationsDirectory.appendingPathComponent("\(conversation.id.rawValue).json"),
        options: .atomic
      )
    }
    try encodeProject(projectState(now: now))
      .write(to: supportDirectory.appendingPathComponent("projects-v1.json"), options: .atomic)
    try encode(mcpState(now: now))
      .write(to: supportDirectory.appendingPathComponent("mcp-servers-v1.json"), options: .atomic)
  }

  private static func supportDirectory() throws -> URL {
    guard let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw FixtureError.missingApplicationSupport
    }

    return base.appendingPathComponent("BYOKchat", isDirectory: true)
  }

  private static func providerState(now: Date) -> ProviderWorkspaceState {
    let claude = ProviderModel(
      providerID: BuiltInProviders.anthropicID,
      id: "claude-sonnet-5",
      displayName: "Claude Sonnet 5",
      contextWindow: 1_000_000,
      contextWindowKind: .inputOnly,
      maxOutputTokens: 128_000,
      supportedParameters: ["max_tokens", "thinking", "effort", "tools"],
      inputModalities: ["text", "image", "file"]
    )
    let openRouter = ProviderModel(
      providerID: BuiltInProviders.openRouterID,
      id: "anthropic/claude-sonnet-5",
      displayName: "Claude Sonnet 5",
      contextWindow: 1_000_000,
      contextWindowKind: .combined,
      maxOutputTokens: 128_000,
      supportedParameters: ["temperature", "top_p", "max_tokens", "reasoning", "tools"],
      inputModalities: ["text", "image", "file"]
    )
    let gemini = ProviderModel(
      providerID: BuiltInProviders.geminiID,
      id: "gemini-3.8-flash",
      displayName: "Gemini 3.8 Flash",
      contextWindow: 1_048_576,
      contextWindowKind: .inputOnly,
      maxOutputTokens: 65_536,
      supportedParameters: ["maxOutputTokens", "thinkingConfig", "tools"],
      inputModalities: ["text", "image", "audio", "file"]
    )

    let accounts = [
      ProviderAccount(
        kind: .anthropic,
        id: anthropicAccountID,
        label: "Personal",
        defaultModelID: claude.id,
        createdAt: now.addingTimeInterval(-86_400 * 18),
        updatedAt: now.addingTimeInterval(-1_800)
      ),
      ProviderAccount(
        kind: .openRouter,
        id: openRouterAccountID,
        label: "Research",
        metadata: ["appTitle": "BYOK"],
        defaultModelID: openRouter.id,
        createdAt: now.addingTimeInterval(-86_400 * 12),
        updatedAt: now.addingTimeInterval(-3_600)
      ),
      ProviderAccount(
        kind: .gemini,
        id: geminiAccountID,
        label: "Fast",
        defaultModelID: gemini.id,
        createdAt: now.addingTimeInterval(-86_400 * 8),
        updatedAt: now.addingTimeInterval(-7_200)
      ),
    ]

    return ProviderWorkspaceState(
      accounts: accounts,
      modelRecords: [
        AccountModelRecord(
          accountID: anthropicAccountID,
          model: claude,
          isFavorite: true,
          isManual: false,
          isAvailable: true
        ),
        AccountModelRecord(
          accountID: openRouterAccountID,
          model: openRouter,
          isFavorite: true,
          isManual: true,
          isAvailable: true
        ),
        AccountModelRecord(
          accountID: geminiAccountID,
          model: gemini,
          isFavorite: true,
          isManual: false,
          isAvailable: true
        ),
      ],
      defaultAccountID: anthropicAccountID,
      providerDefaultAccountIDs: [
        BuiltInProviders.anthropicID.rawValue: anthropicAccountID.rawValue,
        BuiltInProviders.openRouterID.rawValue: openRouterAccountID.rawValue,
        BuiltInProviders.geminiID.rawValue: geminiAccountID.rawValue,
      ]
    )
  }

  private static func conversationState(now: Date) -> ConversationWorkspaceState {
    ConversationWorkspaceState(
      conversations: [
        launchConversation(now: now),
        researchConversation(now: now),
        travelConversation(now: now),
      ]
    )
  }

  private static func launchConversation(now: Date) -> ChatConversation {
    let userDate = now.addingTimeInterval(-2_100)
    let assistantDate = now.addingTimeInterval(-1_800)
    let attachment = ChatAttachment(
      id: "screenshot-launch-checklist",
      kind: .file,
      filename: "launch-checklist.md",
      mimeType: "text/markdown",
      data: Data(
        """
        # Launch checklist
        - App Store metadata
        - Privacy manifest
        - Export compliance
        - Screenshots
        - Final device build
        """.utf8
      )
    )
    let toolRound = ChatToolRound(
      id: "screenshot-tool-round",
      calls: [
        ChatToolCall(
          id: "screenshot-search-call",
          name: "search_web",
          arguments: .object([
            "query": .string("App Store release checklist for an AI client")
          ])
        )
      ],
      results: [
        ChatToolResult(
          callID: "screenshot-search-call",
          name: "search_web",
          content: .object([
            "status": .string("complete"),
            "summary": .string("Metadata, privacy, export compliance, and screenshots checked.")
          ])
        )
      ],
      assistantText: "I checked the release checklist before answering.",
      assistantReasoning: "Verify the launch blockers first, then reduce the plan to the few remaining actions.",
      usage: ProviderUsage(inputTokens: 412, outputTokens: 118, cachedInputTokens: 224),
      createdAt: assistantDate.addingTimeInterval(-60)
    )

    return ChatConversation(
      id: launchConversationID,
      title: "Ship a polished iOS launch",
      createdAt: now.addingTimeInterval(-86_400 * 5),
      updatedAt: assistantDate,
      providerID: BuiltInProviders.anthropicID,
      accountID: anthropicAccountID,
      modelID: "claude-sonnet-5",
      systemPrompt: "Be concise, practical, and release-focused.",
      options: ProviderRequestOptions(
        reasoning: ReasoningOptions(enabled: true, effort: .high)
      ),
      messages: [
        ChatMessage(
          id: "screenshot-launch-user",
          role: .user,
          content: "Review this launch checklist and turn it into the smallest release plan.",
          attachments: [attachment],
          createdAt: userDate,
          updatedAt: userDate,
          status: .complete,
          providerID: BuiltInProviders.anthropicID,
          accountID: anthropicAccountID,
          modelID: "claude-sonnet-5"
        ),
        ChatMessage(
          id: "screenshot-launch-assistant",
          role: .assistant,
          content: """
          ## Launch readiness

          You’re in good shape. I’d finish these three things:

          1. **Capture App Store screenshots** with deterministic fixture data.
          2. **Run a final device build** using the release configuration.
          3. **Verify provider and MCP onboarding** from a clean install.

          Your privacy manifest and export-compliance flag are already in place.
          """,
          reasoning: "The checklist already covers compliance, so the highest-value remaining work is visual proof and a clean-install pass.",
          toolRounds: [toolRound],
          createdAt: assistantDate,
          updatedAt: assistantDate,
          status: .complete,
          providerID: BuiltInProviders.anthropicID,
          accountID: anthropicAccountID,
          modelID: "claude-sonnet-5",
          finishReason: "stop",
          usage: ProviderUsage(
            inputTokens: 4_280,
            outputTokens: 864,
            cachedInputTokens: 2_140,
            reasoningTokens: 312
          ),
          metadata: [
            ChatBilling.costKey: "0.084",
            ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
            ChatBilling.modelRequestCountKey: "2",
            ChatBilling.toolCallCountKey: "1",
          ]
        ),
      ]
    )
  }

  private static func researchConversation(now: Date) -> ChatConversation {
    let userDate = now.addingTimeInterval(-7_200)
    let assistantDate = now.addingTimeInterval(-6_900)

    return ChatConversation(
      id: researchConversationID,
      title: "Compare local vs cloud models",
      createdAt: now.addingTimeInterval(-86_400 * 3),
      updatedAt: assistantDate,
      providerID: BuiltInProviders.openRouterID,
      accountID: openRouterAccountID,
      modelID: "anthropic/claude-sonnet-5",
      messages: [
        ChatMessage(
          id: "screenshot-research-user",
          role: .user,
          content: "When should I use a local model instead of a cloud model on iPhone?",
          createdAt: userDate,
          updatedAt: userDate,
          status: .complete,
          providerID: BuiltInProviders.openRouterID,
          accountID: openRouterAccountID,
          modelID: "anthropic/claude-sonnet-5"
        ),
        ChatMessage(
          id: "screenshot-research-assistant",
          role: .assistant,
          content: "Use local models for privacy, offline access, and predictable cost. Use cloud models when you need stronger reasoning, larger context, vision, or tool support.",
          createdAt: assistantDate,
          updatedAt: assistantDate,
          status: .complete,
          providerID: BuiltInProviders.openRouterID,
          accountID: openRouterAccountID,
          modelID: "anthropic/claude-sonnet-5",
          finishReason: "stop",
          usage: ProviderUsage(inputTokens: 1_120, outputTokens: 286),
          metadata: [
            ChatBilling.costKey: "0.021",
            ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
            ChatBilling.modelRequestCountKey: "1",
            ChatBilling.toolCallCountKey: "0",
          ]
        ),
      ]
    )
  }

  private static func travelConversation(now: Date) -> ChatConversation {
    let userDate = now.addingTimeInterval(-13_200)
    let assistantDate = now.addingTimeInterval(-12_900)

    return ChatConversation(
      id: travelConversationID,
      title: "Plan a Tokyo work trip",
      createdAt: now.addingTimeInterval(-86_400 * 2),
      updatedAt: assistantDate,
      providerID: BuiltInProviders.geminiID,
      accountID: geminiAccountID,
      modelID: "gemini-3.8-flash",
      messages: [
        ChatMessage(
          id: "screenshot-travel-user",
          role: .user,
          content: "Plan a four-day Tokyo trip with mornings for work and relaxed evenings.",
          createdAt: userDate,
          updatedAt: userDate,
          status: .complete,
          providerID: BuiltInProviders.geminiID,
          accountID: geminiAccountID,
          modelID: "gemini-3.8-flash"
        ),
        ChatMessage(
          id: "screenshot-travel-assistant",
          role: .assistant,
          content: "Base yourself around Shibuya or Shinjuku, protect 8–12 for focused work, then keep each afternoon to one neighborhood: Daikanyama, Asakusa, Ginza, and Kichijoji.",
          createdAt: assistantDate,
          updatedAt: assistantDate,
          status: .complete,
          providerID: BuiltInProviders.geminiID,
          accountID: geminiAccountID,
          modelID: "gemini-3.8-flash",
          finishReason: "stop",
          usage: ProviderUsage(inputTokens: 980, outputTokens: 241),
          metadata: [
            ChatBilling.costKey: "0.006",
            ChatBilling.accuracyKey: ChatCostAccuracy.providerReported.rawValue,
            ChatBilling.modelRequestCountKey: "1",
            ChatBilling.toolCallCountKey: "0",
          ]
        ),
      ]
    )
  }

  private static func projectState(now: Date) -> ProjectWorkspaceState {
    let launchFile = ProjectFile(
      id: "screenshot-release-notes",
      filename: "release-notes.md",
      mimeType: "text/markdown",
      data: Data("Release notes, ASO copy, privacy checklist, and screenshot plan.".utf8),
      createdAt: now.addingTimeInterval(-86_400 * 4)
    )
    let researchFile = ProjectFile(
      id: "screenshot-model-notes",
      filename: "model-notes.md",
      mimeType: "text/markdown",
      data: Data("Latency, quality, privacy, context window, and tool support notes.".utf8),
      createdAt: now.addingTimeInterval(-86_400 * 2)
    )

    let projects = [
      ChatProject(
        id: launchProjectID,
        name: "BYOK Launch",
        symbolName: "app.badge.checkmark",
        accentID: "blue",
        accountID: anthropicAccountID,
        modelID: "claude-sonnet-5",
        instructions: "Keep recommendations practical and focused on shipping a polished iPhone release.",
        createdAt: now.addingTimeInterval(-86_400 * 10),
        updatedAt: now.addingTimeInterval(-1_800),
        files: [launchFile],
        promptPresets: [
          ProjectPromptPreset(
            id: "screenshot-preset-release",
            name: "Release Review",
            prompt: "Review the current release state and list only remaining blockers."
          )
        ]
      ),
      ChatProject(
        id: researchProjectID,
        name: "Model Research",
        symbolName: "sparkles",
        accentID: "purple",
        accountID: openRouterAccountID,
        modelID: "anthropic/claude-sonnet-5",
        instructions: "Compare models by quality, latency, privacy, context, and cost.",
        createdAt: now.addingTimeInterval(-86_400 * 8),
        updatedAt: now.addingTimeInterval(-6_900),
        files: [researchFile]
      ),
      ChatProject(
        id: travelProjectID,
        name: "Tokyo Work Trip",
        symbolName: "airplane",
        accentID: "orange",
        accountID: geminiAccountID,
        modelID: "gemini-3.8-flash",
        instructions: "Prefer calm neighborhoods, simple transit, and flexible evenings.",
        createdAt: now.addingTimeInterval(-86_400 * 6),
        updatedAt: now.addingTimeInterval(-12_900)
      ),
    ]

    return ProjectWorkspaceState(
      projects: projects,
      conversationProjectIDs: [
        launchConversationID.rawValue: launchProjectID.rawValue,
        researchConversationID.rawValue: researchProjectID.rawValue,
        travelConversationID.rawValue: travelProjectID.rawValue,
      ]
    )
  }

  private static func mcpState(now: Date) -> MCPWorkspaceState {
    let webServer = MCPRemoteServer(
      id: webServerID,
      name: "Web Search",
      endpoint: URL(string: "https://mcp.example.com/web")!,
      isEnabled: true,
      createdAt: now.addingTimeInterval(-86_400 * 12),
      updatedAt: now.addingTimeInterval(-900)
    )
    let githubServer = MCPRemoteServer(
      id: githubServerID,
      name: "GitHub",
      endpoint: URL(string: "https://mcp.example.com/github")!,
      isEnabled: true,
      createdAt: now.addingTimeInterval(-86_400 * 9),
      updatedAt: now.addingTimeInterval(-1_200)
    )

    let webSnapshot = MCPServerSnapshot(
      serverID: webServerID,
      protocolVersion: "2025-06-18",
      era: .modern,
      serverInfo: MCPImplementationInfo(
        name: "web-search",
        version: "1.4.0",
        title: "Web Search"
      ),
      capabilities: .object(["tools": .object([:])]),
      instructions: "Search and read public web pages.",
      tools: [
        MCPRemoteTool(
          remoteName: "search_web",
          title: "Search Web",
          description: "Search the web for current information.",
          inputSchema: objectSchema(properties: [
            "query": .object(["type": .string("string")])
          ])
        ),
        MCPRemoteTool(
          remoteName: "fetch_page",
          title: "Fetch Page",
          description: "Read a web page from a URL.",
          inputSchema: objectSchema(properties: [
            "url": .object(["type": .string("string")])
          ])
        ),
        MCPRemoteTool(
          remoteName: "extract_links",
          title: "Extract Links",
          description: "Extract useful links from a page.",
          inputSchema: objectSchema(properties: [
            "url": .object(["type": .string("string")])
          ])
        ),
      ],
      refreshedAt: now.addingTimeInterval(-900),
      expiresAt: now.addingTimeInterval(86_400 * 7),
      cacheScope: "public"
    )

    let githubSnapshot = MCPServerSnapshot(
      serverID: githubServerID,
      protocolVersion: "2025-06-18",
      era: .modern,
      serverInfo: MCPImplementationInfo(
        name: "github",
        version: "2.1.0",
        title: "GitHub"
      ),
      capabilities: .object(["tools": .object([:])]),
      instructions: "Read repositories, code, issues, and pull requests.",
      tools: [
        MCPRemoteTool(
          remoteName: "search_code",
          title: "Search Code",
          description: "Search source code in connected repositories.",
          inputSchema: objectSchema(properties: [
            "query": .object(["type": .string("string")])
          ])
        ),
        MCPRemoteTool(
          remoteName: "read_file",
          title: "Read File",
          description: "Read a repository file.",
          inputSchema: objectSchema(properties: [
            "path": .object(["type": .string("string")])
          ])
        ),
        MCPRemoteTool(
          remoteName: "open_pull_request",
          title: "Open Pull Request",
          description: "Open a pull request with prepared changes.",
          inputSchema: objectSchema(properties: [
            "title": .object(["type": .string("string")])
          ])
        ),
      ],
      refreshedAt: now.addingTimeInterval(-1_200),
      expiresAt: now.addingTimeInterval(86_400 * 7),
      cacheScope: "connected"
    )

    return MCPWorkspaceState(
      servers: [webServer, githubServer],
      snapshots: [webSnapshot, githubSnapshot]
    )
  }

  private static func objectSchema(properties: [String: JSONValue]) -> JSONValue {
    .object([
      "type": .string("object"),
      "properties": .object(properties),
    ])
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func encodeProject(_ value: ProjectWorkspaceState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private enum FixtureError: Error {
    case missingApplicationSupport
    case keychain(OSStatus)
  }
}
