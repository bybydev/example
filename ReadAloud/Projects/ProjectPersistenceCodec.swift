import CryptoKit
import Foundation

nonisolated enum ProjectDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    static func sha256(fileAt url: URL) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var digest = SHA256()
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                digest.update(data: data)
            }

            return digest.finalize()
                .map { String(format: "%02x", $0) }
                .joined()
        } catch {
            throw ProjectStoreError.io(String(describing: error))
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

nonisolated enum ProjectJSONCodec {
    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        relativePath: String
    ) throws -> T {
        let version: Int
        do {
            let envelopeDecoder = JSONDecoder()
            version = try envelopeDecoder.decode(
                SchemaEnvelope.self,
                from: data
            ).schemaVersion
        } catch {
            throw ProjectStoreError.corruptDocument(
                relativePath: relativePath,
                reason: "Missing or invalid schemaVersion"
            )
        }

        try ProjectMigrationPlan.requireReadable(
            version: version,
            relativePath: relativePath
        )

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.corruptDocument(
                relativePath: relativePath,
                reason: String(describing: error)
            )
        }
    }
}

nonisolated enum ProjectMigrationPlan {
    static let currentVersion = ProjectSchema.currentVersion

    static func requireReadable(
        version: Int,
        relativePath: String
    ) throws {
        if version > currentVersion {
            throw ProjectStoreError.unsupportedFutureSchema(
                relativePath: relativePath,
                found: version,
                current: currentVersion
            )
        }

        if version < 1 {
            throw ProjectStoreError.unsupportedLegacySchema(
                relativePath: relativePath,
                found: version
            )
        }

        // Version 1 is the first public on-disk schema. Future versions add
        // ordered vN -> vN+1 migrations here before decoding the current model.
        guard version == currentVersion else {
            throw ProjectStoreError.unsupportedLegacySchema(
                relativePath: relativePath,
                found: version
            )
        }
    }
}


nonisolated enum ProjectContentRevision {
    static func item(normalizedText: String) -> String {
        ProjectDigest.sha256(normalizedText)
    }

    static func project(
        manifestItems: [ContentManifestItem],
        items: [ProjectContentItem]
    ) throws -> String {
        var itemByID: [UUID: ProjectContentItem] = [:]
        for item in items {
            guard itemByID[item.id] == nil else {
                throw ProjectStoreError.invalidData(
                    "Project content revision received duplicate item IDs"
                )
            }
            itemByID[item.id] = item
        }
        guard itemByID.count == manifestItems.count else {
            throw ProjectStoreError.invalidData(
                "Project content revision requires one item per manifest entry"
            )
        }

        var canonical = "readaloud-content-v1\n"
        for entry in manifestItems.sorted(by: { $0.order < $1.order }) {
            guard let item = itemByID[entry.id],
                  item.order == entry.order else {
                throw ProjectStoreError.invalidData(
                    "Project content revision item/manifest mismatch"
                )
            }

            canonical += "id:\(ProjectPackagePaths.fileID(entry.id))\n"
            canonical += "order:\(entry.order)\n"
            canonical += "parent:\(entry.parentID.map(ProjectPackagePaths.fileID) ?? "-")\n"
            canonical += "revision:\(item.contentRevision)\n"
        }

        return ProjectDigest.sha256(canonical)
    }
}

nonisolated enum ProjectGenerationKey {
    static func make(_ input: GenerationKeyInput) throws -> String {
        guard ProjectDigest.isSHA256(input.contentRevision) else {
            throw ProjectStoreError.invalidData(
                "Generation key contentRevision must be SHA-256"
            )
        }
        guard !input.resolvedVoiceID.isEmpty,
              input.canonicalSpeed.isFinite,
              input.canonicalSpeed > 0,
              !input.kokoroRuntimeRevision.isEmpty,
              input.synthesisConfigVersion >= 1 else {
            throw ProjectStoreError.invalidData(
                "Generation key input is invalid"
            )
        }

        var canonical = Data("readaloud-generation-key-v1\n".utf8)
        append("contentRevision", input.contentRevision, to: &canonical)
        append("resolvedVoiceID", input.resolvedVoiceID, to: &canonical)
        append(
            "canonicalSpeedBits",
            String(format: "%016llx", input.canonicalSpeed.bitPattern),
            to: &canonical
        )
        append(
            "kokoroRuntimeRevision",
            input.kokoroRuntimeRevision,
            to: &canonical
        )
        append(
            "synthesisConfigVersion",
            String(input.synthesisConfigVersion),
            to: &canonical
        )

        return ProjectDigest.sha256(canonical)
    }

    private static func append(
        _ name: String,
        _ value: String,
        to data: inout Data
    ) {
        let valueData = Data(value.utf8)
        data.append(Data("\(name):\(valueData.count):".utf8))
        data.append(valueData)
        data.append(0x0A)
    }
}
