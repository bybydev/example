/// Canonical product event names for iOS and macOS. Keep wire names stable.
public enum BYOKProductAnalyticsEvent: String, CaseIterable, Sendable {
  case onboardingCompleted = "onboarding_completed"
  case connectionCreated = "connection_created"
  case connectionTestSucceeded = "connection_test_succeeded"
  case connectionTestFailed = "connection_test_failed"
  case chatTurnStarted = "chat_turn_started"
  case chatTurnCompleted = "chat_turn_completed"
  case chatTurnFailed = "chat_turn_failed"
  case chatTurnCancelled = "chat_turn_cancelled"
  case chatPreparationFailed = "chat_preparation_failed"
  case messageSent = "message_sent"
  case messageEdited = "message_edited"
  case responseRegenerated = "response_regenerated"
  case attachmentSent = "attachment_sent"
  case toolRoundCompleted = "tool_round_completed"
  case firstResponseCompleted = "first_response_completed"
  case projectCreated = "project_created"
  case libraryItemSaved = "library_item_saved"
  case mcpServerCreated = "mcp_server_created"
  case mcpDiscoverySucceeded = "mcp_discovery_succeeded"
  case mcpDiscoveryFailed = "mcp_discovery_failed"
  case contentCopied = "content_copied"
  case featureOpened = "feature_opened"
  case analyticsRangeSelected = "analytics_range_selected"
  case upgradeRequested = "upgrade_requested"
}

/// Only fixed categories may be uploaded; never content or resource identifiers.
public enum BYOKProductAnalyticsDimension: String, Sendable {
  case anthropic, openai, xai, gemini, deepseek, zai, moonshot, minimax, qwen, mistral, groq, openrouter, nvidia, ollama, lmstudio, custom
  case image, file, mixed
  case message, code, diagram, reasoning
  case providers, library, projects, mcp, analytics, settings, themes
  case today, sevenDays = "7d", thirtyDays = "30d", month, all
  case analyticsHistory = "analytics_history"
  case chatSearch = "chat_search"

  public init(providerKind: ProviderKind) {
    switch providerKind {
    case .anthropic: self = .anthropic
    case .openai: self = .openai
    case .xAI: self = .xai
    case .gemini: self = .gemini
    case .deepSeek: self = .deepseek
    case .zAI: self = .zai
    case .moonshot: self = .moonshot
    case .minimax: self = .minimax
    case .qwen: self = .qwen
    case .mistral: self = .mistral
    case .groq: self = .groq
    case .openRouter: self = .openrouter
    case .nvidia: self = .nvidia
    case .ollama: self = .ollama
    case .lmStudio: self = .lmstudio
    case .openAICompatible: self = .custom
    }
  }

  public static func provider(_ id: ProviderID?) -> Self {
    Self(providerKind: id.map { ProviderKind(providerID: $0) } ?? .openAICompatible)
  }

  public init(range: UsageAnalyticsRange) {
    switch range {
    case .today: self = .today
    case .sevenDays: self = .sevenDays
    case .thirtyDays: self = .thirtyDays
    case .month: self = .month
    case .all: self = .all
    }
  }
}
