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

nonisolated enum ReadAloudUpsellReason {
    case listening
    case offlineGeneration
}

/// The contextual upgrade entry points share AppFoundation's first-step upsell.
/// Its explicit upgrade action is the only path from here to the paywall.
struct ReadAloudProUpsell: View {
    @Environment(ProjectRuntimeManager.self) private var runtimeManager
    let reason: ReadAloudUpsellReason

    var body: some View {
        LimitReachedUpsellFlow(configuration: configuration) {
            ReadAloudProPaywall()
        }
    }

    private var configuration: LimitReachedUpsellConfiguration {
        switch reason {
        case .listening:
            let allowance = runtimeManager.listeningAllowance
            let reset = allowance.resetDate().formatted(date: .abbreviated, time: .shortened)
            let message = allowance.isExhausted()
                ? "\(allowance.usageDescription()). Your position is saved. Continue when your allowance resets \(reset), or unlock unlimited listening with Pro."
                : "\(allowance.usageDescription()). Your allowance resets \(reset). Unlock unlimited listening with Pro."
            return LimitReachedUpsellConfiguration(
                navigationTitle: "Unlimited Listening",
                title: allowance.isExhausted()
                    ? "Your weekly listening time is used" : "Listen without limits",
                message: message,
                unlockButtonTitle: "Unlock Unlimited Listening"
            )
        case .offlineGeneration:
            return LimitReachedUpsellConfiguration(
                navigationTitle: "Prepare Audio Ahead",
                title: "Prepare chapters before you listen",
                message: "Unlock Pro to generate complete chapters or books ahead of time. You can keep reading and listening within your plan, and existing queued work stays available.",
                unlockButtonTitle: "Unlock Audio Preparation"
            )
        }
    }
}

/// UI-only policy: never apply this gate to execution, recovery or queue actions.
@MainActor
enum ReadAloudOfflineGenerationGate {
    static func allowsRequest(
        purchases: PurchaseManager, isUpsellPresented: Binding<Bool>
    ) -> Bool {
        guard purchases.hasPro else {
            isUpsellPresented.wrappedValue = true
            return false
        }
        return true
    }
}

struct ReadAloudOfflineGenerateLabel: View {
    @Environment(PurchaseManager.self) private var purchases
    let title: String
    let systemImage: String

    var body: some View {
        Label(
            purchases.hasPro ? title : "\(title) · Pro",
            systemImage: purchases.hasPro ? systemImage : "crown.fill"
        )
    }
}

