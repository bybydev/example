import Foundation

nonisolated struct SpeechChunk: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let targetBucketSeconds: Int
    let maxChunkSeconds: Double
    let estimatedDurationSeconds: Double
}

nonisolated struct SpeechChunkScheduler: Sendable {
    private let availableBuckets: [Int]
    private let keepsShortSourceChunks: Bool

    init(
        availableBuckets: [Int] = KokoroResources.buckets,
        keepsShortSourceChunks: Bool = KokoroResources.resourceMode == .fixture
    ) {
        let normalized = Array(Set(availableBuckets.filter { $0 > 0 })).sorted()
        self.availableBuckets = normalized.isEmpty ? [15] : normalized
        self.keepsShortSourceChunks = keepsShortSourceChunks
    }

    func chunks(
        for text: String,
        speed: Float = 1.0
    ) -> [SpeechChunk] {
        let normalizedSpeed = speed.isFinite ? max(Double(speed), 0.1) : 1.0
        var pending = sentenceUnits(from: text)

        guard !pending.isEmpty else {
            return []
        }

        var result: [SpeechChunk] = []
        var index = 0
        var isFirstChunk = true

        while !pending.isEmpty {
            let preferredSourceSeconds = preferredSourceSeconds(
                isFirstChunk: isFirstChunk
            )
            let preferredModelBucket = minimumBucket(
                forSourceTarget: preferredSourceSeconds
            )

            var unit = pending.removeFirst()
            var estimate = estimatedDuration(
                of: unit,
                speed: normalizedSpeed
            )

            if estimate > Double(preferredSourceSeconds) {
                let pieces = split(
                    unit,
                    targetDurationSeconds: Double(preferredSourceSeconds),
                    speed: normalizedSpeed
                )

                if let first = pieces.first {
                    unit = first
                    estimate = estimatedDuration(
                        of: first,
                        speed: normalizedSpeed
                    )

                    if pieces.count > 1 {
                        pending.insert(
                            contentsOf: pieces.dropFirst(),
                            at: 0
                        )
                    }
                }
            }

            if estimate <= Double(preferredSourceSeconds) {
                var combined = unit

                while let next = pending.first {
                    let candidate = combined + " " + next
                    let candidateEstimate = estimatedDuration(
                        of: candidate,
                        speed: normalizedSpeed
                    )

                    guard candidateEstimate <= Double(preferredSourceSeconds) else {
                        break
                    }

                    combined = candidate
                    pending.removeFirst()
                }

                unit = combined
                estimate = estimatedDuration(
                    of: unit,
                    speed: normalizedSpeed
                )
            }

            let bucket = smallestBucket(
                fitting: estimate,
                minimum: preferredModelBucket
            )

            result.append(
                SpeechChunk(
                    id: index,
                    text: unit,
                    targetBucketSeconds: bucket,
                    maxChunkSeconds: keepsShortSourceChunks
                        ? Double(preferredSourceSeconds)
                        : Double(bucket),
                    estimatedDurationSeconds: estimate
                )
            )

            index += 1
            isFirstChunk = false
        }

        return result
    }

    private func preferredSourceSeconds(isFirstChunk: Bool) -> Int {
        if keepsShortSourceChunks {
            return isFirstChunk ? 3 : 7
        }

        if isFirstChunk {
            return availableBuckets.first ?? 3
        }

        return availableBuckets.dropFirst().first
            ?? availableBuckets.first
            ?? 3
    }

    private func sentenceUnits(from text: String) -> [String] {
        let text = normalize(text)
        var units: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: .bySentences
        ) { sentence, _, _, _ in
            if let sentence {
                let unit = normalize(sentence)
                if !unit.isEmpty {
                    units.append(unit)
                }
            }
        }
        return units.isEmpty && !text.isEmpty ? [text] : units
    }

    private func normalize(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func estimatedDuration(
        of text: String,
        speed: Double
    ) -> Double {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let characters = text.count

        let wordEstimate = Double(words) / 2.6
        let characterEstimate = Double(characters) / 14.0
        let base = max(wordEstimate, characterEstimate, 0.25)

        return base / speed
    }

    private func minimumBucket(forSourceTarget target: Int) -> Int {
        availableBuckets.first { $0 >= target }
            ?? availableBuckets.last
            ?? target
    }

    private func smallestBucket(
        fitting duration: Double,
        minimum: Int
    ) -> Int {
        availableBuckets.first {
            $0 >= minimum && Double($0) >= duration
        } ?? (availableBuckets.last ?? minimum)
    }

    private func split(
        _ text: String,
        targetDurationSeconds: Double,
        speed: Double
    ) -> [String] {
        let maximum = Double(availableBuckets.last ?? 30)
        var clauses: [String] = []
        var words: [String] = []

        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            words.append(String(word))
            let ending = word.reversed().first { !"\"'”’)]}".contains($0) }
            if let ending, ",;:—–".contains(ending) {
                clauses.append(words.joined(separator: " "))
                words.removeAll(keepingCapacity: true)
            }
        }
        if !words.isEmpty {
            clauses.append(words.joined(separator: " "))
        }

        var pieces: [String] = []
        var current = ""

        for clause in clauses {
            let clauseDuration = estimatedDuration(
                of: clause,
                speed: speed
            )
            let requiresWordSplit = clauseDuration > maximum
                || (keepsShortSourceChunks && clauseDuration > targetDurationSeconds)

            if requiresWordSplit {
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }

                pieces.append(contentsOf: splitByWords(
                    clause,
                    maxDurationSeconds: keepsShortSourceChunks
                        ? min(targetDurationSeconds, maximum)
                        : maximum,
                    speed: speed
                ))
                continue
            }

            let candidate = current.isEmpty ? clause : current + " " + clause
            if !current.isEmpty,
               estimatedDuration(of: candidate, speed: speed) > targetDurationSeconds {
                pieces.append(current)
                current = clause
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            pieces.append(current)
        }

        return pieces
    }

    private func splitByWords(
        _ text: String,
        maxDurationSeconds: Double,
        speed: Double
    ) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace })

        guard !words.isEmpty else {
            return []
        }

        var pieces: [String] = []
        var currentWords: [Substring] = []

        for word in words {
            let candidateWords = currentWords + [word]
            let candidate = candidateWords.joined(separator: " ")

            if !currentWords.isEmpty,
               estimatedDuration(
                   of: candidate,
                   speed: speed
               ) > maxDurationSeconds
            {
                pieces.append(currentWords.joined(separator: " "))
                currentWords = [word]
            } else {
                currentWords = candidateWords
            }
        }

        if !currentWords.isEmpty {
            pieces.append(currentWords.joined(separator: " "))
        }

        return pieces
    }
}
