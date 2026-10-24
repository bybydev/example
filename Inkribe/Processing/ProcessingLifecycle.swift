import Foundation
import InkribeCore
import Observation

/// iOS owns lifecycle and durable user intent. The shared core owns the format.
@MainActor
@Observable
final class ProcessingLifecycle {
    private(set) var userPaused = false
    var foreground = false
    private(set) var error: String?
    private var fileURL: URL?
    private var pendingPause: Bool?
    var canRun: Bool { foreground && !userPaused && error == nil }

    init() { reload() }

    func reload() {
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("InkribeIOSProcessing", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("processing-control.json")
            fileURL = url
            if let pendingPause {
                try JSONEncoder().encode(ProcessingControlState(userPaused: pendingPause)).write(to: url, options: .atomic)
                self.pendingPause = nil
            }
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
                let state = try JSONDecoder().decode(ProcessingControlState.self, from: Data(contentsOf: url))
                guard state.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                userPaused = state.userPaused
            } else { userPaused = false }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func setUserPaused(_ value: Bool) throws {
        guard error == nil, let fileURL else { throw ProjectStoreError.unavailableRoot }
        pendingPause = value
        do {
            try JSONEncoder().encode(ProcessingControlState(userPaused: value)).write(to: fileURL, options: .atomic)
            userPaused = value
            pendingPause = nil
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }
}
