import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct NewChatTargetSelection: Equatable {
  let accountID: ProviderAccountID
  let modelID: ModelID
  let reasoning: ReasoningOptions?
}

/// Fresh-chat target staging now lives in the shared `TargetPickerView`;
/// this shim preserves the historical call shape for the composer chip.
struct NewChatTargetPickerView: View {
  let initialAccountID: ProviderAccountID
  let initialModelID: ModelID
  let initialReasoning: ReasoningOptions?
  @Bindable var providers: ProviderManagementModel
  let useSelection: (NewChatTargetSelection) -> Void

  var body: some View {
    TargetPickerView(
      providers: providers,
      initialAccountID: initialAccountID,
      initialModelID: initialModelID,
      initialReasoning: initialReasoning,
      mode: .stage(commit: useSelection)
    )
  }
}
