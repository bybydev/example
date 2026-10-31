import Foundation
import Observation

/// Local controls and unpublished music ingress. Cancel/dismiss releases staging;
/// Done publishes the chosen file and every setting in one history operation.
@MainActor @Observable
final class MusicDraft {
    let session: EditorSession
    let expected: ProjectMusic?
    private(set) var music: ProjectMusic?
    private(set) var importing = false
    private(set) var saving = false
    var error: String?
    var volume: Double
    var isMuted: Bool
    var loopToFit: Bool
    var fadeIn: Double
    var fadeOut: Double
    var sourceStart: String
    var sourceEnd: String
    var outputStart: String
    @ObservationIgnored private var prepared: PreparedMusicImport?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var closed = false

    init(session: EditorSession) {
        self.session = session
        let music = session.document?.music
        expected = music; self.music = music
        volume = music?.volume ?? 0.2; isMuted = music?.isMuted ?? false
        loopToFit = music?.loopToFit ?? true
        fadeIn = music?.fadeIn ?? 0; fadeOut = music?.fadeOut ?? 0
        sourceStart = music.map { EditorTime.field($0.sourceInterval.start) } ?? "0.000"
        sourceEnd = music.map { EditorTime.field($0.sourceInterval.end) } ?? "0.000"
        outputStart = music.map { EditorTime.field($0.start) } ?? "0.000"
    }

    func importFile(_ input: ImportInput) {
        guard !importing, !saving, !closed else { return }
        importing = true; error = nil
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.importing = false; self.work = nil }
            var pending: PreparedMusicImport?
            do {
                let importer = MediaImporter(repository: .shared)
                let result = try await importer.prepareMusic(input)
                pending = result
                try Task.checkCancellation()
                guard !self.closed else { throw CancellationError() }
                var replacement = try ProjectMusic(asset: result.asset)
                replacement.start = self.music?.start ?? self.expected?.start ?? .zero
                let old = self.prepared
                self.prepared = result; pending = nil; self.music = replacement
                self.sourceStart = EditorTime.field(replacement.sourceInterval.start)
                self.sourceEnd = EditorTime.field(replacement.sourceInterval.end)
                if let old { try? await ProjectRepository.shared.discardStaging(old.staging) }
            } catch {
                if let pending { try? await ProjectRepository.shared.discardStaging(pending.staging) }
                if !self.closed, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func remove() {
        guard !saving, !importing else { return }
        music = nil; error = nil
    }

    func save() async -> Bool {
        guard !saving, !importing, !closed else { return false }
        saving = true; error = nil
        defer {
            saving = false
            if closed { discardPrepared() }
        }
        do {
            let proposed = try value()
            try await session.saveMusicDraft(proposed, replacing: expected,
                imported: proposed == nil ? nil : prepared)
            // The repository consumed the selected staging after publication.
            // A removed, unpublished selection is released by close().
            if proposed != nil { prepared = nil }
            return !closed
        } catch {
            if !closed { self.error = error.localizedDescription }
            return false
        }
    }

    private func value() throws -> ProjectMusic? {
        guard var value = music else { return nil }
        value.volume = volume; value.isMuted = isMuted; value.loopToFit = loopToFit
        value.fadeIn = fadeIn; value.fadeOut = fadeOut
        value.sourceInterval = try EditorTime.interval(start: sourceStart, end: sourceEnd,
            preserving: value.sourceInterval)
        if outputStart != EditorTime.field(value.start) {
            guard let seconds = Double(outputStart.replacingOccurrences(of: ",", with: ".")) else {
                throw MusicEditError.invalidSettings
            }
            value.start = try EditorTime.stamp(seconds)
        }
        try value.validate(outputDuration: session.duration)
        return value
    }

    func close() {
        closed = true
        work?.cancel()
        // Do not remove a source from underneath an admitted repository save.
        // The save's defer releases it after a failed publication if necessary.
        if !saving { discardPrepared() }
    }

    private func discardPrepared() {
        if let prepared {
            self.prepared = nil
            Task { try? await ProjectRepository.shared.discardStaging(prepared.staging) }
        }
    }
}
