import Foundation
import Logging

struct InkribeConsoleLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug
    let label: String

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let timestamp = Date.now.formatted(.dateTime.hour().minute().second())
        print("[\(timestamp)][\(event.level)][\(label)] \(event.message)")
    }
}

#if DEBUG
struct InkribeStoreLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .debug

    private let label: String
    init(label: String) {
        self.label = label
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var combinedMetadata = metadata
        if let eventMetadata = event.metadata {
            combinedMetadata.merge(eventMetadata) { _, eventValue in eventValue }
        }

        let formattedMetadata = combinedMetadata.isEmpty
            ? nil
            : combinedMetadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")

        let entry = LogEntry(
            level: event.level,
            label: label,
            message: String(describing: event.message),
            metadata: formattedMetadata
        )

        Task { @MainActor in
            LogStore.shared.append(entry)
        }
    }
}
#endif

@MainActor
enum InkribeLogging {
    private static var didBootstrap = false

    static func bootstrap() {
        guard !didBootstrap else { return }

        LoggingSystem.bootstrap { label in
            var console = InkribeConsoleLogHandler(label: label)
            console.logLevel = .debug

            #if DEBUG
            var inMemory = InkribeStoreLogHandler(label: label)
            inMemory.logLevel = .debug
            return MultiplexLogHandler([console, inMemory])
            #else
            return console
            #endif
        }
        didBootstrap = true
    }
}
