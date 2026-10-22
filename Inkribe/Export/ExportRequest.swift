import CoreMedia
import Foundation

enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case mp4, srt
    var title: String { self == .mp4 ? "Captioned video" : "SRT subtitles" }
}

enum ExportResolution: Int, Codable, CaseIterable, Sendable {
    case hd = 720, fullHD = 1080
    var title: String { "\(rawValue)p" }

    /// The selected short edge for 16:9; square/custom canvases fit inside the
    /// corresponding landscape/portrait envelope. Always even H.264 dimensions.
    func canvas(for project: ProjectCanvas) throws -> RenderCanvas {
        try project.validate()
        let long = Double(rawValue) * 16 / 9
        let widthLimit = project.width >= project.height ? long : Double(rawValue)
        let heightLimit = project.width >= project.height ? Double(rawValue) : long
        let scale = min(widthLimit / Double(project.width), heightLimit / Double(project.height))
        let width = max(2, Int((Double(project.width) * scale / 2).rounded(.down)) * 2)
        let height = max(2, Int((Double(project.height) * scale / 2).rounded(.down)) * 2)
        return try RenderCanvas(width: width, height: height)
    }
}

struct ExportProfile: Codable, Equatable, Sendable {
    var format: ExportFormat = .mp4
    var resolution: ExportResolution = .hd
}

/// This file is durable input; the small JobQueue payload only identifies it.
struct ExportManifest: Codable, Sendable {
    let version: Int
    let jobID: UUID
    let document: ProjectDocument
    let profile: ExportProfile
}

struct FrozenExport: Sendable {
    let manifest: ExportManifest
    let directory: URL
    let urls: [UUID: URL]
    var partialURL: URL { directory.appendingPathComponent("partial." + manifest.profile.format.rawValue) }
    var outputURL: URL {
        let banned = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:?%*|\"<>"))
        let cleaned = String(manifest.document.title.unicodeScalars.map { banned.contains($0) ? "_" : String($0) }.joined().prefix(80))
        // File-system limits count UTF-8 bytes, not graphemes. Keep whole
        // characters (including emoji/combining sequences) within a safe basename.
        var basename = ""
        var bytes = 0
        for character in cleaned {
            let unit = String(character)
            guard bytes + unit.utf8.count <= 251 else { break }
            basename += unit
            bytes += unit.utf8.count
        }
        let title = basename.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return directory.appendingPathComponent("Result", isDirectory: true)
            .appendingPathComponent((title.isEmpty ? "Inkribe" : title) + "." + manifest.profile.format.rawValue)
    }
}

enum ExportError: LocalizedError, Sendable {
    case busy, noCaptions, invalidRequest, unavailableEncoder, decoding, encoding, stalled, invalidOutput, noSpace
    var errorDescription: String? {
        switch self {
        case .busy: "Finish or cancel the current export first."
        case .noCaptions: "There are no visible edited captions to export."
        case .invalidRequest: "This saved export request is unavailable. Start a new export."
        case .unavailableEncoder: "The requested H.264/AAC export is unavailable on this device."
        case .decoding: "A source media frame could not be decoded. Check the original file and try again."
        case .encoding: "The video could not be written. Check device storage and try again."
        case .stalled: "The video encoder stopped making progress. Try again with the app in the foreground."
        case .invalidOutput: "The completed file did not match the requested export. No file was published."
        case .noSpace: "Not enough device storage is available for this export. Free some space and try again."
        }
    }
}
