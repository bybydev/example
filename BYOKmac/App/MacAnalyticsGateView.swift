import BYOKchatProviderCore
import SwiftUI

struct MacAnalyticsGateView: View {
  let services: BYOKCoreServices

  var body: some View {
    MacAnalyticsView(services: services)
  }
}
