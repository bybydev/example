import BYOKchatProviderCore
import Foundation
import Observation

nonisolated enum SidebarPinStore {
  static let storageKey = "byokchat.sidebar.pinnedConversationIDs"

  static func parse(_ raw: String) -> Set<String> {
    Set(raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
  }

  static func serialize(_ ids: Set<String>) -> String {
    ids.sorted().joined(separator: "\n")
  }

  static func toggled(_ id: ConversationID, in raw: String) -> String {
    var values = parse(raw)
    if !values.insert(id.rawValue).inserted {
      values.remove(id.rawValue)
    }
    return serialize(values)
  }

  static func removing(_ id: ConversationID, from raw: String) -> String {
    var values = parse(raw)
    values.remove(id.rawValue)
    return serialize(values)
  }

  static func pruned(_ raw: String, keeping validIDs: Set<ConversationID>) -> String {
    let validRawIDs = Set(validIDs.map(\.rawValue))
    return serialize(parse(raw).intersection(validRawIDs))
  }

  static func prune(keeping validIDs: Set<ConversationID>, in defaults: UserDefaults = .standard) {
    guard let raw = defaults.string(forKey: storageKey), !raw.isEmpty else { return }
    let updated = pruned(raw, keeping: validIDs)
    if updated != raw {
      defaults.set(updated, forKey: storageKey)
    }
  }

  static func clear(in defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: storageKey)
  }
}

@MainActor
@Observable
final class AppPreferencesModel {
  private enum Key {
    static let defaultSystemPrompt = "defaultSystemPrompt"
  }

  private let defaults: UserDefaults

  static func normalizedSystemPrompt(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var defaultSystemPrompt: String {
    didSet {
      guard oldValue != defaultSystemPrompt else { return }
      defaults.set(defaultSystemPrompt, forKey: Key.defaultSystemPrompt)
    }
  }

  var hasDefaultSystemPrompt: Bool {
    !Self.normalizedSystemPrompt(defaultSystemPrompt).isEmpty
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    defaultSystemPrompt = Self.normalizedSystemPrompt(
      defaults.string(forKey: Key.defaultSystemPrompt) ?? ""
    )
  }

  func prunePinnedConversations(keeping validIDs: Set<ConversationID>) {
    SidebarPinStore.prune(keeping: validIDs, in: defaults)
  }

  func clearPinnedConversations() {
    SidebarPinStore.clear(in: defaults)
  }

  func reset() {
    defaultSystemPrompt = ""
    clearPinnedConversations()
  }
}

/// Coordinates native App Store review prompts (`requestReview`) around
/// high-satisfaction moments while respecting tenure, error, paywall, and
/// cooldown guardrails.
@MainActor
@Observable
final class AppReviewPromptController {
  static let appStoreID = "6799335915"

  static var writeReviewURL: URL? {
    URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
  }

  private enum Key {
    static let firstSeenAt = "byokchat.reviewPrompt.firstSeenAt"
    static let completedTurnCount = "byokchat.reviewPrompt.completedTurnCount"
    static let completedConversationIDs = "byokchat.reviewPrompt.completedConversationIDs"
    static let lastPromptedAt = "byokchat.reviewPrompt.lastPromptedAt"
    static let lastPromptedVersion = "byokchat.reviewPrompt.lastPromptedVersion"
    static let hasRequestedPostProReview = "byokchat.reviewPrompt.hasRequestedPostProReview"
  }

  private static let minDaysSinceFirstSeen: TimeInterval = 3 * 86_400
  private static let minCompletedTurnsForCopy = 8
  private static let minCompletedTurnsForTurnFallback = 10
  private static let minDistinctConversations = 2
  private static let cooldownInterval: TimeInterval = 120 * 86_400

  private let defaults: UserDefaults
  private let currentVersion: String

  private(set) var promptRequestID: UInt = 0
  private(set) var promptDelay: Duration = .seconds(1)

  @ObservationIgnored private var hadSessionError = false
  @ObservationIgnored private var didShowPaywallThisSession = false
  @ObservationIgnored private var hasPromptedThisSession = false
  @ObservationIgnored private var pendingPostProReview = false
  @ObservationIgnored private var pendingRequestBypassesTenure = false
  @ObservationIgnored private var consumedPromptRequestID: UInt = 0

  init(
    defaults: UserDefaults = .standard,
    currentVersion: String =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  ) {
    self.defaults = defaults
    self.currentVersion = currentVersion
    if defaults.object(forKey: Key.firstSeenAt) == nil {
      defaults.set(Date.now.timeIntervalSince1970, forKey: Key.firstSeenAt)
    }
  }

  private var completedTurnCount: Int {
    defaults.integer(forKey: Key.completedTurnCount)
  }

  private var completedConversationIDs: Set<String> {
    Set(defaults.stringArray(forKey: Key.completedConversationIDs) ?? [])
  }

  func recordCompletedTurn(conversationID: ConversationID, isRegenerate: Bool) {
    let nextCount = completedTurnCount + 1
    defaults.set(nextCount, forKey: Key.completedTurnCount)

    var distinct = completedConversationIDs
    if distinct.count < Self.minDistinctConversations,
      distinct.insert(conversationID.rawValue).inserted
    {
      defaults.set(Array(distinct), forKey: Key.completedConversationIDs)
    }

    guard !isRegenerate else { return }

    if pendingPostProReview {
      schedulePromptIfEligible(delay: .seconds(1.5), bypassTenure: true)
      return
    }

    if nextCount >= Self.minCompletedTurnsForTurnFallback {
      schedulePromptIfEligible(delay: .seconds(1.5), bypassTenure: false)
    }
  }

  func recordAssistantContentCopied() {
    if pendingPostProReview {
      schedulePromptIfEligible(delay: .milliseconds(800), bypassTenure: true)
      return
    }
    guard completedTurnCount >= Self.minCompletedTurnsForCopy else { return }
    schedulePromptIfEligible(delay: .milliseconds(800), bypassTenure: false)
  }

  func recordProUpgraded() {
    guard !defaults.bool(forKey: Key.hasRequestedPostProReview) else { return }
    pendingPostProReview = true
    didShowPaywallThisSession = false
    schedulePromptIfEligible(delay: .seconds(2), bypassTenure: true)
  }

  func recordSessionError() {
    hadSessionError = true
  }

  func recordPaywallShown() {
    didShowPaywallThisSession = true
  }

  func consumePromptRequest(_ requestID: UInt, now: Date = .now) -> Bool {
    guard requestID > 0,
      requestID == promptRequestID,
      requestID != consumedPromptRequestID,
      isEligible(bypassTenure: pendingRequestBypassesTenure, now: now)
    else { return false }

    consumedPromptRequestID = requestID
    hasPromptedThisSession = true
    defaults.set(now.timeIntervalSince1970, forKey: Key.lastPromptedAt)
    if !currentVersion.isEmpty {
      defaults.set(currentVersion, forKey: Key.lastPromptedVersion)
    }
    if pendingPostProReview {
      defaults.set(true, forKey: Key.hasRequestedPostProReview)
      pendingPostProReview = false
    }
    return true
  }

  private func schedulePromptIfEligible(delay: Duration, bypassTenure: Bool) {
    guard isEligible(bypassTenure: bypassTenure) else { return }
    promptDelay = delay
    pendingRequestBypassesTenure = bypassTenure
    promptRequestID &+= 1
  }

  private func isEligible(bypassTenure: Bool, now: Date = .now) -> Bool {
    guard !BYOKAppAnalytics.isSuppressedForTesting else { return false }
    guard !hasPromptedThisSession, !hadSessionError, !didShowPaywallThisSession else {
      return false
    }
    if !currentVersion.isEmpty, defaults.string(forKey: Key.lastPromptedVersion) == currentVersion {
      return false
    }
    if let lastTimestamp = defaults.object(forKey: Key.lastPromptedAt) as? TimeInterval,
      now.timeIntervalSince(Date(timeIntervalSince1970: lastTimestamp)) < Self.cooldownInterval
    {
      return false
    }
    if !bypassTenure {
      let firstSeenTimestamp =
        defaults.object(forKey: Key.firstSeenAt) as? TimeInterval ?? now.timeIntervalSince1970
      guard
        now.timeIntervalSince(Date(timeIntervalSince1970: firstSeenTimestamp))
          >= Self.minDaysSinceFirstSeen
      else { return false }
      guard completedConversationIDs.count >= Self.minDistinctConversations else { return false }
    }
    return true
  }
}
