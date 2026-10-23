import AppFoundation
import Foundation
import Observation

@MainActor
@Observable
final class ProAccess {
    let purchases = Commerce.makePurchases()
    private var clockGeneration = 0
    @ObservationIgnored private var expiration: Task<Void, Never>?

    var isChecking: Bool { purchases.entitlementState == .checking }
    var hasPro: Bool {
        _ = clockGeneration
        #if DEBUG
        // AF's simulator grants monthly access without a real subscription expiry.
        if purchases.isUsingSimulatedPurchases { return purchases.hasPro }
        #endif
        guard case .active(let snapshot) = purchases.entitlementState else { return false }
        if snapshot.activeProductIDs.contains(Commerce.lifetimeID) { return true }
        return snapshot.activeProductIDs.contains(Commerce.monthlyID)
            && (snapshot.latestExpirationDate.map { $0 > Date() } ?? false)
    }

    func refreshForRequest() async {
        await purchases.refreshEntitlements()
        scheduleExpiration()
    }

    func scheduleExpiration() {
        clockGeneration += 1
        expiration?.cancel()
        expiration = nil
        #if DEBUG
        if purchases.isUsingSimulatedPurchases { return }
        #endif
        guard case .active(let snapshot) = purchases.entitlementState,
              !snapshot.activeProductIDs.contains(Commerce.lifetimeID),
              let end = snapshot.latestExpirationDate, end > Date() else { return }
        let delay = min(86_400, max(0.01, end.timeIntervalSinceNow))
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            await self.refreshForRequest()
        }
    }

    func require(_ feature: ProFeature) throws {
        guard hasPro else { throw ProError.requiresPro(feature) }
    }

    func canChangeStyle(from before: CaptionStyle, to next: CaptionStyle) -> Bool {
        if hasPro { return true }
        // Preserve existing looks after expiry. New premium font/effect choices
        // require Pro; free color/size/position changes and a reset remain possible.
        return (next.font == .modern || next.font == before.font)
            && (next.effect == .none || next.effect == before.effect)
    }
}
