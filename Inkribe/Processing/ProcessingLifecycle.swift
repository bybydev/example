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
    private(set) var isSwitchingModel = false
    private(set) var workGeneration = UUID()
    private(set) var backgroundKinds: Set<ProcessingKind> = []
    private(set) var systemPausedKinds: Set<ProcessingKind> = []
    var needsResume: Bool { userPaused || !systemPausedKinds.isEmpty }
    var canTranscribe: Bool { canProcess(.transcription) && !isSwitchingModel }
    var canExport: Bool { canProcess(.export) }

    private func canProcess(_ kind: ProcessingKind) -> Bool {
        (foreground || backgroundKinds.contains(kind)) && !userPaused && error == nil &&
            !systemPausedKinds.contains(kind)
    }
    func setBackground(_ granted: Bool, for kind: ProcessingKind) {
        if granted { backgroundKinds.insert(kind) } else { backgroundKinds.remove(kind) }
    }
    func interrupt(_ kind: ProcessingKind) { systemPausedKinds.insert(kind) }
    func resumeInterrupted(_ kind: ProcessingKind) { systemPausedKinds.remove(kind) }
    func resumeInterrupted() { systemPausedKinds.removeAll() }

    func pauseDescription(for kind: ProcessingKind) -> String? {
        if userPaused { return "Paused by you. Resume in Queue when you’re ready." }
        if systemPausedKinds.contains(kind) {
            return "Paused by iOS. Resume in Queue to continue."
        }
        if !foreground && !backgroundKinds.contains(kind) {
            return "Processing paused outside Inkribe. Return to the app to continue."
        }
        return nil
    }

    func beginModelSwitch() throws {
        guard !isSwitchingModel else { throw SpeechError.busy }
        isSwitchingModel = true
        workGeneration = UUID()
    }
    func endModelSwitch() { isSwitchingModel = false }
    func requireAdmission(_ generation: UUID) throws {
        guard !isSwitchingModel, generation == workGeneration else { throw CancellationError() }
    }

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
