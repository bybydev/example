import UIKit

/// Holds a UIKit background-task assertion while chat generations are active
/// so a briefly backgrounded app can finish streaming instead of being
/// suspended mid-socket. If the system revokes the window first, `onExpiration`
/// runs and the assertion is dropped.
@MainActor
final class BackgroundActivityKeeper {
  private let onExpiration: () -> Void
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  init(onExpiration: @escaping () -> Void) {
    self.onExpiration = onExpiration
  }

  /// Idempotent: starts the assertion only when none is held.
  func begin() {
    guard identifier == .invalid else { return }
    identifier = UIApplication.shared.beginBackgroundTask(withName: "BYOKchat streaming") {
      [weak self] in
      self?.expire()
    }
  }

  /// Idempotent: ends and invalidates the held assertion, if any.
  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }

  private func expire() {
    onExpiration()
    end()
  }
}
