#if DEBUG
import Foundation
import Logging

struct LogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: Logger.Level
    let label: String
    let message: String
    let metadata: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        level: Logger.Level,
        label: String,
        message: String,
        metadata: String?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.label = label
        self.message = message
        self.metadata = metadata
    }
}
#endif
