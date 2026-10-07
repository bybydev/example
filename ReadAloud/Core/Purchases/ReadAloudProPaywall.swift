import AppFoundation
import SwiftUI

struct ReadAloudProPaywall: View {
    @Environment(PurchaseManager.self)
    private var purchases

    var body: some View {
        ProPaywallView(
            purchases: purchases,
            configuration:
                ReadAloudCommerce
                    .paywallConfiguration
        )
    }
}
