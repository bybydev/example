import Foundation
import Observation

@MainActor
@Observable
final class AppPreferencesModel {
  private enum Key {
    static let defaultSystemPrompt = "defaultSystemPrompt"
  }

  private let defaults: UserDefaults

  var defaultSystemPrompt: String {
    didSet { defaults.set(defaultSystemPrompt, forKey: Key.defaultSystemPrompt) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    defaultSystemPrompt = defaults.string(forKey: Key.defaultSystemPrompt) ?? ""
  }

  func reset() {
    defaultSystemPrompt = ""
  }
}
