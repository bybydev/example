import MacAppFoundation
import SwiftUI

@MainActor
struct InkribeProPaywallView: View {
    let purchaseManager: PurchaseManager

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ProPaywallView(
            purchaseManager: purchaseManager,
            configuration: InkribeCommerce.paywallConfiguration,
            onPurchased: { _ in close() },
            onRestored: close,
            onClose: close
        )
    }

    private func close() {
        dismissWindow(id: InkribeWindowID.proPaywall)
    }
}

@MainActor
struct InkribeProUpsellView: View {
    let capability: InkribeProCapability
    let onUpgrade: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ProUpsellView(
            title: capability.upsellTitle,
            message: capability.upsellMessage,
            features: InkribeCommerce.configuration.features,
            primaryActionTitle: "Unlock Pro",
            secondaryActionTitle: "Continue Free",
            onPrimaryAction: onUpgrade,
            onSecondaryAction: onDismiss
        )
        .padding(24)
    }
}
