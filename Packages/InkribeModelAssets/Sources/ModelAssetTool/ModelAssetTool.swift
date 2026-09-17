import Darwin
import Foundation
import InkribeModelAssets

@main
struct ModelAssetTool {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("\(message(for: error))\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { throw ToolError.usage }
        let output = try outputDirectory(from: arguments)
        let manifest = try ModelAssetCatalog.bundledManifest()

        switch command {
        case "download":
            try await download(manifest.assets, to: output)
        case "verify":
            try verify(manifest.assets, in: output)
        case "manifest":
            for asset in manifest.assets {
                print("\(asset.id)\t\(asset.relativePath)\t\(asset.byteCount)\t\(asset.sha256)")
            }
        default:
            throw ToolError.usage
        }
    }

    private static func outputDirectory(from arguments: [String]) throws -> URL {
        if let index = arguments.firstIndex(of: "--output") {
            guard arguments.indices.contains(index + 1) else { throw ToolError.usage }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(ModelAssetCatalog.resourceRootName, isDirectory: true)
    }

    private static func download(_ assets: [ModelAssetDescriptor], to root: URL) async throws {
        for asset in assets {
            let destination = root.appendingPathComponent(asset.relativePath)
            if FileManager.default.fileExists(atPath: destination.path),
               (try? ModelAssetIntegrityChecker.check(destination, against: asset)) != nil {
                print("Using \(asset.displayName): \(destination.path)")
                continue
            }

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)

            var lastError: Error?
            for attempt in 1...3 {
                do {
                    let (temporaryURL, response) = try await URLSession.shared.download(from: asset.downloadURL)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw ToolError.badResponse(asset.id)
                    }

                    let staging = destination.deletingLastPathComponent()
                        .appendingPathComponent(".\(asset.fileName).\(UUID().uuidString).partial")
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try FileManager.default.copyItem(at: temporaryURL, to: staging)
                    try ModelAssetIntegrityChecker.check(staging, against: asset)
                    try FileManager.default.moveItem(at: staging, to: destination)
                    print("Installed \(asset.displayName): \(destination.path)")
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < 3 {
                        try await Task.sleep(for: .seconds(attempt))
                    }
                }
            }
            if let lastError { throw lastError }
        }
    }

    private static func verify(_ assets: [ModelAssetDescriptor], in root: URL) throws {
        for asset in assets {
            let url = root.appendingPathComponent(asset.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ModelAssetError.missingAsset(asset.id, expectedURL: url)
            }
            try ModelAssetIntegrityChecker.check(url, against: asset)
            print("OK \(asset.displayName)")
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return "Model asset error: \(description)"
        }
        return "Model asset error: \(String(describing: error))"
    }
}

private enum ToolError: LocalizedError {
    case usage
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: ModelAssetTool <download|verify|manifest> [--output <Models directory>]"
        case .badResponse(let id):
            "The download server returned an unsuccessful response for model \(id)."
        }
    }
}
