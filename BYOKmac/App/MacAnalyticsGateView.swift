import BYOKchatProviderCore
import SwiftUI

struct MacAnalyticsGateView: View {
  let services: BYOKCoreServices
  var initialConversationID: ConversationID? = nil

  var body: some View {
    MacAnalyticsView(
      services: services,
      initialConversationID: initialConversationID
    )
  }
}
