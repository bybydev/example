import Foundation

/// Shared policy for deletion tombstones recorded in workspace states.
///
/// Tombstones make deletions syncable: a synced device must be able to tell
/// "this record was deleted" apart from "this record was never created here",
/// otherwise deletes cannot propagate. They are pruned after a retention
/// window on load — long enough for any sane sync cadence to have delivered
/// the deletion everywhere.
public enum SyncTombstonePolicy {
  public static let retention: TimeInterval = 30 * 24 * 60 * 60

  public static func pruned(_ tombstones: [String: Date], now: Date = .now) -> [String: Date] {
    tombstones.filter { now.timeIntervalSince($0.value) < retention }
  }
}
