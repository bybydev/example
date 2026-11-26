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

  static func toggled(_ id: ConversationID, in raw: String) -> String {
    var ids = parse(raw)
    if ids.contains(id.rawValue) {
      ids.remove(id.rawValue)
    } else {
      ids.insert(id.rawValue)
    }
    return serialize(ids)
  }

  static func removing(_ id: ConversationID, from raw: String) -> String {
    var ids = parse(raw)
    guard ids.remove(id.rawValue) != nil else { return raw }
    return serialize(ids)
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
  static let defaultTranscriptFontSize: Double = 15
  static let minimumTranscriptFontSize: Double = 12
  static let maximumTranscriptFontSize: Double = 22

  private enum Key {
    static let defaultSystemPrompt = "defaultSystemPrompt"
    static let transcriptFontSize = "byokchat.transcriptFontSize"
  }

  private let defaults: UserDefaults

  static func normalizedSystemPrompt(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func clampedTranscriptFontSize(_ value: Double) -> Double {
    min(max(value.rounded(), minimumTranscriptFontSize), maximumTranscriptFontSize)
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

  var transcriptFontSize: Double {
    didSet {
      let clamped = Self.clampedTranscriptFontSize(transcriptFontSize)
      if transcriptFontSize != clamped {
        transcriptFontSize = clamped
        return
      }
      guard oldValue != transcriptFontSize else { return }
      defaults.set(transcriptFontSize, forKey: Key.transcriptFontSize)
    }
  }

  var canIncreaseTranscriptFontSize: Bool {
    transcriptFontSize < Self.maximumTranscriptFontSize
  }

  var canDecreaseTranscriptFontSize: Bool {
    transcriptFontSize > Self.minimumTranscriptFontSize
  }

  func increaseTranscriptFontSize() {
    transcriptFontSize = Self.clampedTranscriptFontSize(transcriptFontSize + 1)
  }

  func decreaseTranscriptFontSize() {
    transcriptFontSize = Self.clampedTranscriptFontSize(transcriptFontSize - 1)
  }

  func resetTranscriptFontSize() {
    transcriptFontSize = Self.defaultTranscriptFontSize
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
    let storedFontSize = defaults.object(forKey: Key.transcriptFontSize) as? Double
    transcriptFontSize = Self.clampedTranscriptFontSize(
      storedFontSize ?? Self.defaultTranscriptFontSize
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
    transcriptFontSize = Self.defaultTranscriptFontSize
    clearPinnedConversations()
  }
}
