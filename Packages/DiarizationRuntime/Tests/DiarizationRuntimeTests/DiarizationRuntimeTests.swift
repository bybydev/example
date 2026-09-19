import Foundation
import Testing
@testable import DiarizationRuntime

@Suite("Diarization runtime")
struct DiarizationRuntimeTests {
    @Test func releaseAndModelPinsAreStable() throws {
        #expect(DiarizationRuntimeRelease.stableVersion == "1.13.8")
        #expect(DiarizationRuntimeRelease.revision.count == 40)

        let segmentation = try SpeakerDiarizationModelAsset.segmentationDescriptor()
        #expect(segmentation.id == "pyannote-segmentation-3-onnx")
        #expect(segmentation.relativePath == "diarization/pyannote-segmentation-3.0.onnx")
        #expect(segmentation.license == "MIT")

        let embedding = try SpeakerDiarizationModelAsset.embeddingDescriptor()
        #expect(embedding.id == "3dspeaker-eres2net-base-3dspeaker-16k")
        #expect(embedding.relativePath == "diarization/3dspeaker-eres2net-base.onnx")
        #expect(embedding.license == "Apache-2.0")
    }

    @Test func configurationClampsUnsafeValues() {
        let configuration = SpeakerDiarizationConfiguration(
            threadCount: 0,
            clusteringThreshold: 4,
            minDurationOn: -1,
            minDurationOff: -2,
            windowShiftRatio: 2
        )

        #expect(configuration.threadCount == 1)
        #expect(configuration.clusteringThreshold == 1)
        #expect(configuration.minDurationOn == 0)
        #expect(configuration.minDurationOff == 0)
        #expect(configuration.windowShiftRatio == 1)
    }

    @Test func speakerTurnNormalizesBounds() {
        let turn = SpeakerTurn(
            speakerID: -3,
            startTime: -2,
            endTime: -4
        )

        #expect(turn.speakerID == 0)
        #expect(turn.startTime == 0)
        #expect(turn.endTime == 0)
    }
}
