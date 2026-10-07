import Foundation

nonisolated enum ProjectValidation {
    static func validate(_ project: ProjectDocument) throws {
        try requireCurrentSchema(
            project.schemaVersion,
            relativePath: "project.json"
        )
        try requireNonempty(project.title, field: "project.title")
        try requireHash(project.source.sourceRevision, field: "source.sourceRevision")
        try requireNonempty(
            project.source.originalFileName,
            field: "source.originalFileName"
        )
        guard project.source.originalFileName
            == URL(fileURLWithPath: project.source.originalFileName).lastPathComponent,
              !project.source.originalFileName.contains("\\") else {
            throw ProjectStoreError.invalidData(
                "source.originalFileName must be a filename, not a path"
            )
        }
        try requireSafeRelativePath(
            project.source.relativePath,
            requiredPrefix: "source/"
        )
        let sourceComponents = project.source.relativePath.split(separator: "/")
        let sourceURL = URL(fileURLWithPath: project.source.relativePath)
        guard sourceComponents.count == 2,
              sourceComponents.first == "source",
              !sourceURL.pathExtension.isEmpty,
              sourceURL.deletingPathExtension().lastPathComponent
                == ProjectPackagePaths.fileID(project.source.id) else {
            throw ProjectStoreError.invalidData(
                "Source path must use the stable source UUID filename"
            )
        }

        if let artwork = project.artwork {
            try requireSafeRelativePath(
                artwork.relativePath,
                requiredPrefix: "cache/artwork/"
            )
        }

        if let voiceID = project.settings.voiceID {
            try requireNonempty(voiceID, field: "settings.voiceID")
        }
        if let speed = project.settings.speed {
            try requireSpeed(speed, field: "settings.speed")
        }
        guard project.updatedAt >= project.createdAt else {
            throw ProjectStoreError.invalidData(
                "project.updatedAt must not precede createdAt"
            )
        }

        if let playback = project.playback {
            try validate(playback)
        }
    }

    static func validate(_ manifest: ProjectContentManifest) throws {
        try requireCurrentSchema(
            manifest.schemaVersion,
            relativePath: "content/manifest.json"
        )
        try requireHash(
            manifest.contentRevision,
            field: "manifest.contentRevision"
        )

        var ids = Set<UUID>()
        var orders = Set<Int>()
        let allIDs = Set(manifest.items.map(\.id))

        for entry in manifest.items {
            guard entry.order >= 0 else {
                throw ProjectStoreError.invalidData(
                    "Manifest order must be non-negative"
                )
            }
            guard ids.insert(entry.id).inserted else {
                throw ProjectStoreError.invalidData(
                    "Manifest contains duplicate item ID \(entry.id)"
                )
            }
            guard orders.insert(entry.order).inserted else {
                throw ProjectStoreError.invalidData(
                    "Manifest contains duplicate order \(entry.order)"
                )
            }

            let expected = ProjectPackagePaths.relativeItemPath(entry.id)
            guard entry.relativePath == expected else {
                throw ProjectStoreError.invalidData(
                    "Manifest item path must be \(expected)"
                )
            }

            if let parentID = entry.parentID {
                guard parentID != entry.id, allIDs.contains(parentID) else {
                    throw ProjectStoreError.invalidData(
                        "Manifest item has invalid parentID"
                    )
                }
            }
        }

        try requireAcyclicHierarchy(manifest.items)
    }

    static func validate(_ item: ProjectContentItem) throws {
        try requireCurrentSchema(
            item.schemaVersion,
            relativePath: ProjectPackagePaths.relativeItemPath(item.id)
        )
        guard item.order >= 0 else {
            throw ProjectStoreError.invalidData(
                "Item order must be non-negative"
            )
        }
        try requireHash(
            item.contentRevision,
            field: "item.contentRevision"
        )
        guard item.contentRevision
                == ProjectContentRevision.item(normalizedText: item.text) else {
            throw ProjectStoreError.invalidData(
                "Item contentRevision does not match normalized stored text"
            )
        }
        try requireNonempty(
            item.sourceLocator.value,
            field: "item.sourceLocator.value"
        )
        try validate(item.settings)
    }

    static func validate(_ queue: ProjectQueueDocument) throws {
        try requireCurrentSchema(
            queue.schemaVersion,
            relativePath: "queue/jobs.json"
        )

        var ids = Set<UUID>()
        for job in queue.jobs {
            guard ids.insert(job.id).inserted else {
                throw ProjectStoreError.invalidData(
                    "Queue contains duplicate job ID \(job.id)"
                )
            }
            try requireHash(
                job.generationKey,
                field: "queue.generationKey"
            )
            guard job.attempt >= 0 else {
                throw ProjectStoreError.invalidData(
                    "Queue attempt must be non-negative"
                )
            }
            guard job.updatedAt >= job.createdAt else {
                throw ProjectStoreError.invalidData(
                    "Queue updatedAt must not precede createdAt"
                )
            }
        }
    }

    static func validate(_ metadata: GeneratedAudioMetadata) throws {
        try requireCurrentSchema(
            metadata.schemaVersion,
            relativePath: ProjectPackagePaths.relativeAudioMetadataPath(
                metadata.itemID
            )
        )
        try requireHash(metadata.generationKey, field: "audio.generationKey")
        try requireHash(metadata.audioRevision, field: "audio.audioRevision")
        try requireHash(metadata.contentRevision, field: "audio.contentRevision")
        try requireNonempty(metadata.voiceID, field: "audio.voiceID")
        try requireSpeed(metadata.speed, field: "audio.speed")
        try requireNonempty(
            metadata.runtimeRevision,
            field: "audio.runtimeRevision"
        )

        guard metadata.synthesisConfigVersion >= 1 else {
            throw ProjectStoreError.invalidData(
                "Audio synthesisConfigVersion must be positive"
            )
        }

        guard metadata.format == .wav24kMono else {
            throw ProjectStoreError.invalidData(
                "ReadAloud 1.0 audio must be 24 kHz mono WAV"
            )
        }

        guard metadata.durationSeconds.isFinite,
              metadata.durationSeconds > 0 else {
            throw ProjectStoreError.invalidData(
                "Audio duration must be finite and positive"
            )
        }

        guard !metadata.segments.isEmpty else {
            throw ProjectStoreError.invalidData(
                "Final audio metadata requires at least one source segment"
            )
        }

        var previousSourceEnd = 0
        var previousTimeEnd = 0.0

        for segment in metadata.segments {
            let source = segment.sourceRange
            guard source.startUTF16 >= 0,
                  source.endUTF16 > source.startUTF16,
                  source.startUTF16 >= previousSourceEnd else {
                throw ProjectStoreError.invalidData(
                    "Audio source ranges must be ordered and non-overlapping"
                )
            }

            guard segment.startSeconds.isFinite,
                  segment.endSeconds.isFinite,
                  segment.startSeconds >= 0,
                  segment.endSeconds > segment.startSeconds,
                  segment.startSeconds >= previousTimeEnd,
                  segment.endSeconds <= metadata.durationSeconds else {
                throw ProjectStoreError.invalidData(
                    "Audio segment times must be ordered and within duration"
                )
            }

            previousSourceEnd = source.endUTF16
            previousTimeEnd = segment.endSeconds
        }
    }

    static func requireSafeRelativePath(
        _ value: String,
        requiredPrefix: String? = nil
    ) throws {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\\") else {
            throw ProjectStoreError.unsafeRelativePath(value)
        }

        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )

        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw ProjectStoreError.unsafeRelativePath(value)
        }

        if let requiredPrefix,
           !value.hasPrefix(requiredPrefix) {
            throw ProjectStoreError.unsafeRelativePath(value)
        }
    }

    private static func validate(
        _ playback: ProjectPlaybackState
    ) throws {
        guard playback.projectProgress.isFinite,
              (0...1).contains(playback.projectProgress) else {
            throw ProjectStoreError.invalidData(
                "Playback projectProgress must be between 0 and 1"
            )
        }

        if playback.currentItemID == nil,
           playback.contentBookmark != nil || playback.audioPosition != nil {
            throw ProjectStoreError.invalidData(
                "Playback bookmark/position requires currentItemID"
            )
        }

        if let bookmark = playback.contentBookmark {
            try requireHash(
                bookmark.contentRevision,
                field: "playback.contentBookmark.contentRevision"
            )
            guard bookmark.textOffsetUTF16 >= 0 else {
                throw ProjectStoreError.invalidData(
                    "Playback textOffsetUTF16 must be non-negative"
                )
            }
        }

        if let audio = playback.audioPosition {
            try requireHash(
                audio.generationKey,
                field: "playback.audioPosition.generationKey"
            )
            try requireHash(
                audio.audioRevision,
                field: "playback.audioPosition.audioRevision"
            )
            guard audio.positionSeconds.isFinite,
                  audio.positionSeconds >= 0 else {
                throw ProjectStoreError.invalidData(
                    "Playback positionSeconds must be finite and non-negative"
                )
            }
        }
    }

    private static func validate(
        _ settings: ItemNarrationSettings
    ) throws {
        switch settings.voice.mode {
        case .inherit:
            if let remembered = settings.voice.customValue {
                try requireNonempty(
                    remembered,
                    field: "item.settings.voice.customValue"
                )
            }
        case .custom:
            guard let value = settings.voice.customValue else {
                throw ProjectStoreError.invalidData(
                    "Custom voice mode requires customValue"
                )
            }
            try requireNonempty(
                value,
                field: "item.settings.voice.customValue"
            )
        }

        switch settings.speed.mode {
        case .inherit:
            if let remembered = settings.speed.customValue {
                try requireSpeed(
                    remembered,
                    field: "item.settings.speed.customValue"
                )
            }
        case .custom:
            guard let value = settings.speed.customValue else {
                throw ProjectStoreError.invalidData(
                    "Custom speed mode requires customValue"
                )
            }
            try requireSpeed(
                value,
                field: "item.settings.speed.customValue"
            )
        }
    }

    private static func requireAcyclicHierarchy(
        _ entries: [ContentManifestItem]
    ) throws {
        let parentByID = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.id, $0.parentID) }
        )

        for entry in entries {
            var seen = Set<UUID>()
            var cursor: UUID? = entry.id

            while let id = cursor {
                guard seen.insert(id).inserted else {
                    throw ProjectStoreError.invalidData(
                        "Manifest hierarchy contains a cycle"
                    )
                }
                cursor = parentByID[id] ?? nil
            }
        }
    }

    private static func requireCurrentSchema(
        _ version: Int,
        relativePath: String
    ) throws {
        try ProjectMigrationPlan.requireReadable(
            version: version,
            relativePath: relativePath
        )
    }

    private static func requireHash(
        _ value: String,
        field: String
    ) throws {
        guard ProjectDigest.isSHA256(value) else {
            throw ProjectStoreError.invalidData(
                "\(field) must be a SHA-256 hex digest"
            )
        }
    }

    private static func requireNonempty(
        _ value: String,
        field: String
    ) throws {
        guard !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ProjectStoreError.invalidData(
                "\(field) must not be empty"
            )
        }
    }

    private static func requireSpeed(
        _ value: Double,
        field: String
    ) throws {
        guard value.isFinite, value > 0 else {
            throw ProjectStoreError.invalidData(
                "\(field) must be finite and positive"
            )
        }
    }
}
