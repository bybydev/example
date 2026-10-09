import Foundation
import OnnxRuntimeBindings

/// Small CPU BART decoder used only for OOV pronunciation. Keeping this
/// separate from the Kokoro 82M session avoids ever constructing MLX tensors.
nonisolated final class ONNXG2PBART {
    enum Error: LocalizedError {
        case invalidMetadata(String)
        case incompatibleModelSignature
        case invalidOutput
        case invalidPhonemes
        case inputTooLong

        var errorDescription: String? {
            switch self {
            case .invalidMetadata(let field):
                "The ONNX pronunciation dictionary has invalid \(field) metadata."
            case .incompatibleModelSignature:
                "The ONNX pronunciation model has an incompatible input/output signature."
            case .invalidOutput:
                "The ONNX pronunciation model returned an invalid tensor."
            case .invalidPhonemes:
                "The ONNX pronunciation model could not pronounce a word."
            case .inputTooLong:
                "A word exceeds the ONNX pronunciation model's input budget."
            }
        }
    }

    private let environment: ORTEnv
    private let session: ORTSession
    private let outputName: String
    private let graphemeIDs: [Character: Int64]
    private let phonemes: [String]
    private let startID: Int64
    private let bosID: Int64
    private let eosID: Int64
    private let unknownID: Int64
    private let maxSteps: Int

    init(model: URL, metadata: [String: Any]) throws {
        func int(_ key: String) throws -> Int64 {
            guard let value = metadata[key] as? NSNumber else {
                throw Error.invalidMetadata(key)
            }
            return value.int64Value
        }

        // The published Misaki ONNX sidecar stores these tables as *strings*
        // (from grapheme_chars / phoneme_chars in the source BART config).
        // Enumerate each character in order: its index is the model token ID.
        // Also accept an array representation for compatible future exports.
        func symbols(_ key: String) throws -> [String] {
            if let characters = metadata[key] as? String, !characters.isEmpty {
                return characters.map(String.init)
            }
            if let values = metadata[key] as? [String],
               !values.isEmpty, values.allSatisfy({ $0.count == 1 }) {
                return values
            }
            throw Error.invalidMetadata(key)
        }

        let graphemes = try symbols("graphemes")
        let phonemes = try symbols("phonemes")
        var ids: [Character: Int64] = [:]
        for (index, g) in graphemes.enumerated() {
            if g.count == 1, let c = g.first {
                ids[c] = Int64(index)
            }
        }
        self.graphemeIDs = ids
        self.phonemes = phonemes
        self.startID = try int("start_id")
        self.bosID = try int("bos_id")
        self.eosID = try int("eos_id")
        self.unknownID = try int("unknown_id")
        let configuredSteps = try int("max_steps")
        self.maxSteps = min(64, max(2, Int(configuredSteps)))

        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        try options.setGraphOptimizationLevel(.all)
        let session = try ORTSession(
            env: env, modelPath: model.path, sessionOptions: options
        )
        let inputs = Set(try session.inputNames())
        let outputs = try session.outputNames()
        guard inputs.contains("input_ids"),
              inputs.contains("decoder_input_ids"),
              outputs.contains("logits") else {
            throw Error.incompatibleModelSignature
        }
        let outputName = "logits"
        self.environment = env
        self.session = session
        self.outputName = outputName
    }

    /// Greedy token-by-token decode. The ONNX export has no KV cache: each
    /// iteration receives the full decoder prefix. Inputs are bounded.
    func pronounce(_ word: String) throws -> String {
        try Task.checkCancellation()
        guard word.count <= 60 else { throw Error.inputTooLong }
        let encoder = [bosID] + word.map { graphemeIDs[$0] ?? unknownID } + [eosID]
        var decoder: [Int64] = [startID]
        var spoken = ""

        for _ in 0..<(maxSteps - 1) {
            try Task.checkCancellation()
            let next = try autoreleasepool {
                let input = try ORTValue(
                    tensorData: Self.data(encoder), elementType: .int64,
                    shape: [1, NSNumber(value: encoder.count)]
                )
                let prefix = try ORTValue(
                    tensorData: Self.data(decoder), elementType: .int64,
                    shape: [1, NSNumber(value: decoder.count)]
                )
                let outputs = try session.run(
                    withInputs: [
                        "input_ids": input,
                        "decoder_input_ids": prefix
                    ],
                    outputNames: Set([outputName]),
                    runOptions: nil
                )
                guard let logits = outputs[outputName] else {
                    throw Error.invalidOutput
                }
                let info = try logits.tensorTypeAndShapeInfo()
                guard info.elementType == .float,
                      info.shape.count == 3,
                      info.shape[0].intValue == 1,
                      info.shape[1].intValue == decoder.count,
                      info.shape[2].intValue > 4,
                      info.shape[2].intValue < 4096 else {
                    throw Error.invalidOutput
                }
                let vocabCount = info.shape[2].intValue
                let row = decoder.count - 1
                let offset = row * vocabCount
                let buffer = try logits.tensorData() as Data
                guard buffer.count == decoder.count * vocabCount * 4 else {
                    throw Error.invalidOutput
                }
                return buffer.withUnsafeBytes { raw -> Int64 in
                    let floats = raw.bindMemory(to: Float.self)
                    var bestIndex = 0
                    var bestScore = -Float.infinity
                    for i in 0..<vocabCount {
                        let value = floats[offset + i]
                        if value.isFinite && value > bestScore {
                            bestIndex = i
                            bestScore = value
                        }
                    }
                    return Int64(bestIndex)
                }
            }

            if next == eosID { break }
            guard next >= 0, next < Int64(phonemes.count) else {
                throw Error.invalidOutput
            }
            decoder.append(next)
            if next > 3 {
                spoken += phonemes[Int(next)]
            }
        }
        guard !spoken.isEmpty else { throw Error.invalidPhonemes }
        return spoken
    }

    private static func data(_ values: [Int64]) -> NSMutableData {
        NSMutableData(data: values.withUnsafeBytes { Data($0) })
    }
}
