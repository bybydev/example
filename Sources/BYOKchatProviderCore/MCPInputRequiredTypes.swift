import Foundation

public enum MCPToolCallRoundResult: Sendable, Equatable {
  case complete(MCPToolCallOutput)
  case inputRequired(MCPInputRequiredRound)
}
