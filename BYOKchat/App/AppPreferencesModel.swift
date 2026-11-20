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
