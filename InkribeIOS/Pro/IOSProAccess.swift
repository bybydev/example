import AppFoundation
import Foundation
import Observation

@MainActor
@Observable
final class IOSProAccess {
    let purchases = IOSCommerce.makePurchases()
    private var clockGeneration = 0
    @ObservationIgnored private var expiration: Task<Void, Never>?

    var isChecking: Bool { purchases.entitlementState == .checking }
    var hasPro: Bool {
        _ = clockGeneration
        guard case .active(let snapshot) = purchases.entitlementState else { return false }
        if snapshot.activeProductIDs.contains(IOSCommerce.lifetimeID) { return true }
        return snapshot.activeProductIDs.contains(IOSCommerce.monthlyID)
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
        guard case .active(let snapshot) = purchases.entitlementState,
              !snapshot.activeProductIDs.contains(IOSCommerce.lifetimeID),
              let end = snapshot.latestExpirationDate, end > Date() else { return }
        let delay = min(86_400, max(0.01, end.timeIntervalSinceNow))
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            await self.refreshForRequest()
        }
    }

    func require(_ feature: IOSProFeature) throws {
        guard hasPro else { throw IOSProError.requiresPro(feature) }
    }

    func canChangeStyle(from before: IOSCaptionStyle, to next: IOSCaptionStyle) -> Bool {
        if hasPro { return true }
        // Preserve existing looks after expiry. New premium font/effect choices
        // require Pro; free color/size/position changes and a reset remain possible.
        return (next.font == .modern || next.font == before.font)
            && (next.effect == .none || next.effect == before.effect)
    }
}
