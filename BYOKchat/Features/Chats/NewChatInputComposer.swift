import BYOKchatProviderCore

struct NewChatTargetSelection: Equatable {
  let accountID: ProviderAccountID
  let modelID: ModelID
  let reasoning: ReasoningOptions?
}
