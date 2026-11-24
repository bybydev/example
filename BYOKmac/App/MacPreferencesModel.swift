import BYOKchatProviderCore
import Foundation
import Observation

enum MacSidebarPinStore {
  static let storageKey = "byokchat.sidebar.pinnedConversationIDs"

  static func parse(_ raw: String) -> Set<String> {
    Set(raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
  }

  static func serialize(_ ids: Set<String>) -> String {
    ids.sorted().joined(separator: "\n")
  }

  static func prune(keeping validIDs: Set<ConversationID>, in defaults: UserDefaults = .standard) {
    guard let raw = defaults.string(forKey: storageKey), !raw.isEmpty else { return }
    let validRawIDs = Set(validIDs.map(\.rawValue))
    let updated = serialize(parse(raw).intersection(validRawIDs))
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
final class MacPreferencesModel {
  private enum Key {
    static let defaultSystemPrompt = "defaultSystemPrompt"
  }

  private let defaults: UserDefaults

  static func normalizedSystemPrompt(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var defaultSystemPrompt: String {
    didSet {
      let normalized = Self.normalizedSystemPrompt(defaultSystemPrompt)
      if defaultSystemPrompt != normalized {
        defaultSystemPrompt = normalized
        return
      }
      guard oldValue != defaultSystemPrompt else { return }
      defaults.set(defaultSystemPrompt, forKey: Key.defaultSystemPrompt)
    }
  }

  var hasDefaultSystemPrompt: Bool {
    !Self.normalizedSystemPrompt(defaultSystemPrompt).isEmpty
  }

  var shareUsageData: Bool {
    didSet {
      guard oldValue != shareUsageData else { return }
      defaults.set(shareUsageData, forKey: MacAppAnalytics.preferenceKey)
    }
  }

  var sendOnReturn: Bool { true }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    defaultSystemPrompt = Self.normalizedSystemPrompt(
      defaults.string(forKey: Key.defaultSystemPrompt) ?? ""
    )
    shareUsageData = MacAppAnalytics.shareUsageDataPreference(in: defaults)
  }

  func prunePinnedConversations(keeping validIDs: Set<ConversationID>) {
    MacSidebarPinStore.prune(keeping: validIDs, in: defaults)
  }

  func clearPinnedConversations() {
    MacSidebarPinStore.clear(in: defaults)
  }

  func reset() {
    defaultSystemPrompt = ""
    clearPinnedConversations()
  }
}
