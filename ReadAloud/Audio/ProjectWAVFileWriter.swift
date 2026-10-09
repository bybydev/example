import Foundation

/// Builds a final WAV on disk with one bounded paragraph in memory at a time.
actor ProjectWAVFileWriter {
    private let url: URL
    private var handle: FileHandle?
    private var sampleCount = 0

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("finalize-\(UUID().uuidString).wav")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ProjectStoreError.io("Unable to create temporary audio file.")
        }
        do {
            let file = try FileHandle(forWritingTo: url)
            try file.write(contentsOf: ProjectWAVCodec.header(sampleCount: 0))
            handle = file
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func append(samples: [Float]) throws -> (start: Int, end: Int) {
        try Task.checkCancellation()
        guard let handle,
              samples.count <= ReadAloudSafety.maximumParagraphSamples,
              sampleCount <= (Int(UInt32.max) - 36) / 2 - samples.count else {
            throw ProjectStoreError.invalidData("Audio finalization exceeded safe file limits.")
        }
        let start = sampleCount
        let data = try ProjectWAVCodec.encode(samples: samples, sampleRate: ProjectWAVCodec.requiredSampleRate)
        try handle.write(contentsOf: data.dropFirst(44))
        sampleCount += samples.count
        return (start, sampleCount)
    }

    func finish() throws -> (url: URL, samples: Int, revision: String) {
        try Task.checkCancellation()
        guard let handle, sampleCount > 0 else {
            throw ProjectStoreError.invalidData("Audio finalization produced no samples.")
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: ProjectWAVCodec.header(sampleCount: sampleCount))
        try handle.close()
        self.handle = nil
        return (url, sampleCount, try ProjectDigest.sha256(fileAt: url))
    }

    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }
}
