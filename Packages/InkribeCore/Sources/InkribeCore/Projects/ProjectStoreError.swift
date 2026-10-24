import Foundation

public enum ProjectStoreError: LocalizedError, Sendable {
    case unavailableRoot
    case invalidDocument(String)
    case unsupportedSchema(Int)
    case unsupportedCaptionStyle(Int)
    case missingProject(UUID)
    case staleRevision(expected: UInt64, actual: UInt64)
    case invalidPath(String)
    case missingOriginal(String)
    case insufficientSpace
    case unsupportedMedia
    case rightsNotConfirmed
    case unsupportedURL
    case oversizedImport
    case duplicateProject(UUID)
    case packageConflict(UUID)
    case unsupportedPackageVersion(Int)
    case oversizedProjectMetadata

    public var errorDescription: String? {
        switch self {
        case .unavailableRoot: "The app's local project storage is unavailable."
        case .invalidDocument(let reason): "The project could not be read: \(reason)"
        case .unsupportedSchema(let version): "This project uses a newer document version (\(version)). Update Inkribe to open it."
        case .unsupportedCaptionStyle(let version): "This project uses a newer caption style version (\(version)). Update Inkribe to open it."
        case .missingProject: "The project is unavailable."
        case .staleRevision: "The project changed since this edit began. Reload it before saving."
        case .invalidPath: "An unsafe media path was rejected."
        case .missingOriginal: "A required original media file is missing."
        case .insufficientSpace: "Not enough device storage is available for this import."
        case .unsupportedMedia: "This file has no supported audio or video track."
        case .rightsNotConfirmed: "Confirm that you have permission to import this media."
        case .unsupportedURL: "Only HTTPS direct media links are supported."
        case .oversizedImport: "This file exceeds the supported import size."
        case .duplicateProject: "A project with this identity already exists."
        case .packageConflict: "Two folders claim the same project. Both were kept unchanged. Resolve the duplicate before opening this project."
        case .unsupportedPackageVersion(let version): "This project uses an unsupported package version (\(version)). Update Inkribe to open it."
        case .oversizedProjectMetadata: "This project's metadata exceeds the supported size. Its files were kept unchanged."
        }
    }
}
