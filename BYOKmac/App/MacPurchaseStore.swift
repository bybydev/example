import BYOKchatProviderCore
import Foundation
import MacAppFoundation
import Observation
import SwiftUI

@MainActor
enum MacWindowID {
  static let proPaywall = "byokchat.pro-paywall"
}

enum MacSettingsTab: String, CaseIterable, Sendable {
  case general
  case plan
  case theme
  case connections
  case tools
  case data
  case diagnostics
}

/// Routes requests from anywhere in the app to a specific Settings tab, using
/// the same request-ID pattern as `MacProGateCenter` so an already-open
/// Settings window still reacts.
@MainActor
@Observable
final class MacSettingsRouter {
  static let shared = MacSettingsRouter()

  private(set) var requestID = 0
  private(set) var requestedTab: MacSettingsTab?

  private init() {}

  func request(_ tab: MacSettingsTab) {
    requestedTab = tab
    requestID &+= 1
  }
}

enum MacProEntitlementAccess: Sendable, Equatable {
  case checking
  case free
  case pro
}

enum MacProGateDecision: Sendable, Equatable {
  case allowed
  case checking
  case requiresPro
}

struct MacProResourceSnapshot: Sendable, Equatable {
  var providerAccountIDs: [String] = []
  var projectIDs: [String] = []
  var mcpServerIDs: [String] = []
  var libraryEntryIDs: [String] = []
}

/// Tracks only resources introduced by a Free full-backup restore that exceed
/// the Free allowance. Existing resources from a former Pro subscription are
/// deliberately not locked on downgrade.
///
/// Candidate order is persisted. If the user deletes an existing unrestricted
/// resource, the earliest restored candidate automatically occupies the newly
/// free slot without rewriting the backup-restored workspace.
@MainActor
final class MacProResourceRestrictions {
  private enum Suffix {
    static let providers = "providers"
    static let projects = "projects"
    static let mcp = "mcp"
    static let library = "library"
  }

  private let defaults: UserDefaults
  private let keyPrefix: String

  init(
    defaults: UserDefaults = .standard,
    keyPrefix: String = "byokchat.mac.pro-restored-restrictions"
  ) {
    self.defaults = defaults
    self.keyPrefix = keyPrefix
  }

  func clear() {
    for suffix in [Suffix.providers, Suffix.projects, Suffix.mcp, Suffix.library] {
      defaults.removeObject(forKey: key(suffix))
    }
  }

  func recordFullBackupImport(
    before: MacProResourceSnapshot,
    after: MacProResourceSnapshot,
    strategy: ProviderImportStrategy,
    entitlement: MacProEntitlementAccess
  ) {
    guard entitlement != .pro else {
      clear()
      return
    }

    switch strategy {
    case .replaceExisting:
      write(after.providerAccountIDs, suffix: Suffix.providers)
      write(after.projectIDs, suffix: Suffix.projects)
      write(after.mcpServerIDs, suffix: Suffix.mcp)
      write(after.libraryEntryIDs, suffix: Suffix.library)

    case .keepExisting:
      appendNewCandidates(
        before: before.providerAccountIDs,
        after: after.providerAccountIDs,
        suffix: Suffix.providers
      )
      appendNewCandidates(
        before: before.projectIDs,
        after: after.projectIDs,
        suffix: Suffix.projects
      )
      appendNewCandidates(
        before: before.mcpServerIDs,
        after: after.mcpServerIDs,
        suffix: Suffix.mcp
      )
      appendNewCandidates(
        before: before.libraryEntryIDs,
        after: after.libraryEntryIDs,
        suffix: Suffix.library
      )
    }
  }

  func isProviderRestricted(
    _ id: ProviderAccountID,
    currentIDs: [ProviderAccountID],
    entitlement: MacProEntitlementAccess
  ) -> Bool {
    isRestricted(
      id.rawValue,
      currentIDs: currentIDs.map(\.rawValue),
      candidates: read(Suffix.providers),
      freeLimit: BYOKProPolicy.freeProviderAccountLimit,
      entitlement: entitlement
    )
  }

  func isProjectRestricted(
    _ id: ProjectID,
    currentIDs: [ProjectID],
    entitlement: MacProEntitlementAccess
  ) -> Bool {
    isRestricted(
      id.rawValue,
      currentIDs: currentIDs.map(\.rawValue),
      candidates: read(Suffix.projects),
      freeLimit: BYOKProPolicy.freeProjectLimit,
      entitlement: entitlement
    )
  }

  func isMCPServerRestricted(
    _ id: MCPServerID,
    currentIDs: [MCPServerID],
    entitlement: MacProEntitlementAccess
  ) -> Bool {
    isRestricted(
      id.rawValue,
      currentIDs: currentIDs.map(\.rawValue),
      candidates: read(Suffix.mcp),
      freeLimit: BYOKProPolicy.freeMCPServerLimit,
      entitlement: entitlement
    )
  }

  func isLibraryEntryRestricted(
    _ id: LibraryEntryID,
    currentIDs: [LibraryEntryID],
    entitlement: MacProEntitlementAccess
  ) -> Bool {
    isRestricted(
      id.rawValue,
      currentIDs: currentIDs.map(\.rawValue),
      candidates: read(Suffix.library),
      freeLimit: BYOKProPolicy.freeLibraryItemLimit,
      entitlement: entitlement
    )
  }

  private func appendNewCandidates(before: [String], after: [String], suffix: String) {
    let beforeSet = Set(before)
    let newIDs = after.filter { !beforeSet.contains($0) }
    guard !newIDs.isEmpty else { return }

    var candidates = read(suffix)
    var existing = Set(candidates)
    for id in newIDs where existing.insert(id).inserted {
      candidates.append(id)
    }
    write(candidates, suffix: suffix)
  }

  private func isRestricted(
    _ id: String,
    currentIDs: [String],
    candidates: [String],
    freeLimit: Int,
    entitlement: MacProEntitlementAccess
  ) -> Bool {
    guard entitlement != .pro else { return false }

    let currentSet = Set(currentIDs)
    let activeCandidates = candidates.filter { currentSet.contains($0) }
    let candidateSet = Set(activeCandidates)
    guard candidateSet.contains(id) else { return false }

    let unrestrictedCount = currentIDs.reduce(into: 0) { count, currentID in
      if !candidateSet.contains(currentID) { count += 1 }
    }
    let availableSlots = max(0, freeLimit - unrestrictedCount)
    let unlockedCandidates = Set(activeCandidates.prefix(availableSlots))
    return !unlockedCandidates.contains(id)
  }

  private func key(_ suffix: String) -> String {
    "\(keyPrefix).\(suffix)"
  }

  private func read(_ suffix: String) -> [String] {
    defaults.stringArray(forKey: key(suffix)) ?? []
  }

  private func write(_ values: [String], suffix: String) {
    defaults.set(values, forKey: key(suffix))
  }
}

@MainActor
enum MacPurchaseStore {
  static let monthlyProductID = BYOKProCatalog.monthlyProductID
  static let yearlyProductID = BYOKProCatalog.yearlyProductID
  static let lifetimeProductID = BYOKProCatalog.lifetimeProductID
  static let restrictions = MacProResourceRestrictions()

  #if DEBUG
  static let simulatedModeKey = "byokchat.mac.developer.simulatedPurchases"
  #endif

  static let features: [PurchaseFeature] = [
    PurchaseFeature(
      id: "themes",
      systemImage: "paintpalette.fill",
      title: "All themes",
      message: "GitHub Dark Dimmed and GitHub Light are free. Pro unlocks every MAF theme.",
      freeValue: "2 GitHub themes",
      proValue: "All themes"
    ),
    PurchaseFeature(
      id: "provider-accounts",
      systemImage: "key.horizontal.fill",
      title: "Unlimited provider accounts",
      message: "Connect as many provider accounts as you need instead of the single free account.",
      freeValue: "1 connection",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "projects",
      systemImage: "folder.fill",
      title: "Unlimited projects",
      message: "Organize chats, files, prompts, models, and tools across unlimited projects.",
      freeValue: "1 project",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "mcp-servers",
      systemImage: "shippingbox.fill",
      title: "Unlimited MCP servers",
      message: "Connect unlimited remote MCP servers instead of the single free server.",
      freeValue: "1 server",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "library-items",
      systemImage: "books.vertical.fill",
      title: "Unlimited saved files",
      message: "Keep using existing files and save more than the 10-file free limit.",
      freeValue: "10 files",
      proValue: "Unlimited"
    ),
    PurchaseFeature(
      id: "advanced-analytics",
      systemImage: "chart.bar.xaxis",
      title: "Advanced usage analytics",
      message: "Add performance, reliability, provider/model breakdowns, budgets, and deeper insights.",
      freeValue: "Basic",
      proValue: "Advanced"
    ),
  ]

  static let configuration = PurchaseConfiguration(
    productIDs: BYOKProCatalog.productIDs,
    preferredProductID: BYOKProCatalog.preferredProductID,
    features: features
  )

  static let simulatedProducts: [StoreProduct] = [
    StoreProduct(
      id: monthlyProductID,
      displayName: "BYOK Pro Monthly",
      description: "BYOK Pro for one month",
      displayPrice: "$6.99",
      price: 6.99,
      subscriptionPeriod: .init(value: 1, unit: .month)
    ),
    StoreProduct(
      id: yearlyProductID,
      displayName: "BYOK Pro Yearly",
      description: "BYOK Pro for one year",
      displayPrice: "$49.99",
      price: 49.99,
      subscriptionPeriod: .init(value: 1, unit: .year)
    ),
    StoreProduct(
      id: lifetimeProductID,
      displayName: "BYOK Pro Lifetime",
      description: "Pay once and keep BYOK Pro forever",
      displayPrice: "$129.99",
      price: 129.99,
      subscriptionPeriod: nil
    ),
  ]

  static let manager: PurchaseManager = {
    #if DEBUG
    let startsSimulated = UserDefaults.standard.bool(forKey: simulatedModeKey)
    #else
    let startsSimulated = false
    #endif

    return PurchaseManager(
      configuration: configuration,
      simulated: startsSimulated,
      simulatedProducts: simulatedProducts,
      simulatedPersistenceKey: "byokchat.mac.simulatedPurchases"
    )
  }()

  static let paywallConfiguration = ProPaywallConfiguration(
    title: "BYOK Pro",
    subtitle: "Unlock every theme, unlimited configurations, saved files, and advanced local analytics.",
    highlightedProductID: yearlyProductID,
    highlightedProductBadge: "BEST VALUE",
    termsURL: URL(string: "https://byok.pro/terms")!,
    privacyURL: URL(string: "https://byok.pro/privacy")!,
    showsRedeemCode: true
  )

  static let planConfiguration = ProPlanPaneConfiguration(appName: "BYOKchat")

  #if DEBUG
  static var developerConfiguration: FoundationDeveloperConfiguration {
    FoundationDeveloperConfiguration(
      replays: [
        FoundationDeveloperReplay(
          id: "paywall",
          title: "Pro Paywall",
          systemImage: "crown.fill"
        ) { dismiss in
          ProPaywallView(
            purchaseManager: manager,
            configuration: paywallConfiguration,
            onPurchased: { _ in dismiss() },
            onRestored: dismiss,
            onClose: dismiss
          )
        }
      ]
    )
  }
  #endif
}

enum MacProFeature: String, Sendable {
  case providerAccounts
  case projects
  case mcpServers
  case libraryItems
  case analytics
}

@MainActor
@Observable
final class MacProGateCenter {
  static let shared = MacProGateCenter()

  private(set) var requestID = 0
  private(set) var feature: MacProFeature?

  private init() {}

  func request(_ feature: MacProFeature) {
    self.feature = feature
    requestID &+= 1
  }
}

@MainActor
enum MacProAccess {
  static let freeProviderAccountLimit = BYOKProPolicy.freeProviderAccountLimit
  static let freeProjectLimit = BYOKProPolicy.freeProjectLimit
  static let freeMCPServerLimit = BYOKProPolicy.freeMCPServerLimit
  static let freeLibraryItemLimit = BYOKProPolicy.freeLibraryItemLimit

  static var entitlementAccess: MacProEntitlementAccess {
    switch MacPurchaseStore.manager.entitlementState {
    case .checking:
      .checking
    case .inactive:
      .free
    case .active:
      .pro
    }
  }

  static var hasPro: Bool { entitlementAccess == .pro }
  static var isCheckingEntitlement: Bool { entitlementAccess == .checking }

  static func canCreateProviderAccount(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateProviderAccount(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateProject(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateProject(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateMCPServer(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateMCPServer(currentCount: currentCount, hasPro: hasPro)
  }

  static func remainingLibraryCapacity(currentCount: Int, hasPro: Bool) -> Int? {
    BYOKProPolicy.remainingLibraryCapacity(currentCount: currentCount, hasPro: hasPro)
  }

  static func canCreateLibraryItem(currentCount: Int, hasPro: Bool) -> Bool {
    BYOKProPolicy.canCreateLibraryItem(currentCount: currentCount, hasPro: hasPro)
  }

  static func providerAccountCapacityDecision(
    currentCount: Int,
    entitlement: MacProEntitlementAccess? = nil
  ) -> MacProGateDecision {
    capacityDecision(
      currentCount: currentCount,
      limit: freeProviderAccountLimit,
      entitlement: entitlement ?? entitlementAccess
    )
  }

  static func projectCapacityDecision(
    currentCount: Int,
    entitlement: MacProEntitlementAccess? = nil
  ) -> MacProGateDecision {
    capacityDecision(
      currentCount: currentCount,
      limit: freeProjectLimit,
      entitlement: entitlement ?? entitlementAccess
    )
  }

  static func mcpServerCapacityDecision(
    currentCount: Int,
    entitlement: MacProEntitlementAccess? = nil
  ) -> MacProGateDecision {
    capacityDecision(
      currentCount: currentCount,
      limit: freeMCPServerLimit,
      entitlement: entitlement ?? entitlementAccess
    )
  }

  static func providerConfigurationImportDecision(
    existingIDs: [ProviderAccountID],
    importedIDs: [ProviderAccountID],
    strategy: ProviderImportStrategy,
    entitlement: MacProEntitlementAccess? = nil
  ) -> MacProGateDecision {
    let projectedCount: Int
    switch strategy {
    case .replaceExisting:
      projectedCount = Set(importedIDs).count
    case .keepExisting:
      projectedCount = Set(existingIDs).union(importedIDs).count
    }

    let access = entitlement ?? entitlementAccess
    if access == .pro || projectedCount <= freeProviderAccountLimit { return .allowed }
    return access == .checking ? .checking : .requiresPro
  }

  static func requireProviderAccountCapacity(currentCount: Int) -> Bool {
    requireCapacity(
      decision: providerAccountCapacityDecision(currentCount: currentCount),
      feature: .providerAccounts
    )
  }

  static func requireProjectCapacity(currentCount: Int) -> Bool {
    requireCapacity(
      decision: projectCapacityDecision(currentCount: currentCount),
      feature: .projects
    )
  }

  static func requireMCPServerCapacity(currentCount: Int) -> Bool {
    requireCapacity(
      decision: mcpServerCapacityDecision(currentCount: currentCount),
      feature: .mcpServers
    )
  }

  static func requireLibraryCapacity(currentCount: Int, additions: Int = 1) -> Int {
    guard additions > 0 else { return 0 }

    switch entitlementAccess {
    case .pro:
      return additions
    case .checking:
      let remaining = max(0, freeLibraryItemLimit - currentCount)
      return min(additions, remaining)
    case .free:
      let remaining = max(0, freeLibraryItemLimit - currentCount)
      guard remaining > 0 else {
        MacProGateCenter.shared.request(.libraryItems)
        return 0
      }
      if additions > remaining {
        MacProGateCenter.shared.request(.libraryItems)
      }
      return min(additions, remaining)
    }
  }

  static func requestUpgrade(_ feature: MacProFeature) {
    guard entitlementAccess == .free else { return }
    MacProGateCenter.shared.request(feature)
  }

  static func blockedMessage(freeMessage: String) -> String {
    isCheckingEntitlement
      ? "Checking your BYOK Pro status. Try again in a moment."
      : freeMessage
  }

  static func restoredResourceBlockedMessage(_ resource: String) -> String {
    isCheckingEntitlement
      ? "Checking your BYOK Pro status before using this restored \(resource). Try again in a moment."
      : "This restored \(resource) is above the Free limit. Upgrade to BYOK Pro to use it."
  }

  private static func capacityDecision(
    currentCount: Int,
    limit: Int,
    entitlement: MacProEntitlementAccess
  ) -> MacProGateDecision {
    if entitlement == .pro || currentCount < limit { return .allowed }
    return entitlement == .checking ? .checking : .requiresPro
  }

  private static func requireCapacity(
    decision: MacProGateDecision,
    feature: MacProFeature
  ) -> Bool {
    switch decision {
    case .allowed:
      return true
    case .checking:
      return false
    case .requiresPro:
      MacProGateCenter.shared.request(feature)
      return false
    }
  }
}

struct MacProPaywallWindow: View {
  let purchaseManager: PurchaseManager

  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    ProPaywallView(
      purchaseManager: purchaseManager,
      configuration: MacPurchaseStore.paywallConfiguration,
      onPurchased: { _ in close() },
      onRestored: close,
      onClose: close
    )
  }

  private func close() {
    dismissWindow(id: MacWindowID.proPaywall)
  }
}