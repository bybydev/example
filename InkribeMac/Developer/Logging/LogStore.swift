#if DEBUG
import Combine

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []

    let maximumEntries: Int

    init(maximumEntries: Int = 500) {
        precondition(maximumEntries > 0)
        self.maximumEntries = maximumEntries
    }

    func append(_ entry: LogEntry) {
        entries.append(entry)
        let overflow = entries.count - maximumEntries
        if overflow > 0 {
            entries.removeFirst(overflow)
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
#endif
