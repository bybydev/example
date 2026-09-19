import DiarizationRuntime
import Foundation
import InkribeModelAssets
import LLMRuntime
import Metal
import WhisperRuntime

struct InkribeModelDiagnostic: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let runtimeVersion: String
    let runtimeBuild: String
    let revision: String
    let expectedByteCount: Int64
    let license: String
    let isPresent: Bool
}

struct InkribeRuntimeDiagnosticsSnapshot: Equatable, Sendable {
    let architecture: String
    let processorCount: Int
    let physicalMemoryBytes: Int64
    let metalDeviceName: String?
    let transcriptionBackend: String
    let transcriptionThreadCount: Int32
    let aiBackend: String
    let aiThreadCount: Int32
    let aiContextSize: UInt32
    let models: [InkribeModelDiagnostic]

    static func capture(bundle: Bundle = .main) -> Self {
        let whisperConfiguration = WhisperRuntimeConfiguration.recommended
        let llmConfiguration = LLMRuntimeConfiguration.recommended
        let locator = try? ModelAssetLocator(bundle: bundle)

        let whisperDescriptor = try? WhisperModelAsset.descriptor()
        let segmentationDescriptor = try? SpeakerDiarizationModelAsset.segmentationDescriptor()
        let embeddingDescriptor = try? SpeakerDiarizationModelAsset.embeddingDescriptor()
        let llmDescriptors = (try? LLMModelAsset.descriptors()) ?? []
        let physicalMemory = min(
            ProcessInfo.processInfo.physicalMemory,
            UInt64(Int64.max)
        )

        var models = [
            modelDiagnostic(
                descriptor: whisperDescriptor,
                runtimeVersion: WhisperRuntimeRelease.stableVersion,
                runtimeBuild: WhisperRuntimeRelease.binaryTag,
                locator: locator
            )
        ].compactMap { $0 }
        models.append(
            contentsOf: [
                modelDiagnostic(
                    descriptor: segmentationDescriptor,
                    runtimeVersion: DiarizationRuntimeRelease.stableVersion,
                    runtimeBuild: String(DiarizationRuntimeRelease.revision.prefix(8)),
                    locator: locator
                ),
                modelDiagnostic(
                    descriptor: embeddingDescriptor,
                    runtimeVersion: DiarizationRuntimeRelease.stableVersion,
                    runtimeBuild: String(DiarizationRuntimeRelease.revision.prefix(8)),
                    locator: locator
                )
            ].compactMap { $0 }
        )
        models.append(
            contentsOf: llmDescriptors.compactMap {
                modelDiagnostic(
                    descriptor: $0,
                    runtimeVersion: LLMRuntimeRelease.stableVersion,
                    runtimeBuild: LLMRuntimeRelease.binaryTag,
                    locator: locator
                )
            }
        )

        return Self(
            architecture: architectureName,
            processorCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: Int64(physicalMemory),
            metalDeviceName: MTLCreateSystemDefaultDevice()?.name,
            transcriptionBackend: whisperConfiguration.useGPU ? "Metal" : "CPU",
            transcriptionThreadCount: whisperConfiguration.threadCount,
            aiBackend: llmConfiguration.useGPU ? "Metal" : "CPU",
            aiThreadCount: llmConfiguration.threadCount,
            aiContextSize: llmConfiguration.contextSize,
            models: models
        )
    }

    private static func modelDiagnostic(
        descriptor: ModelAssetDescriptor?,
        runtimeVersion: String,
        runtimeBuild: String,
        locator: ModelAssetLocator?
    ) -> InkribeModelDiagnostic? {
        guard let descriptor else { return nil }
        let modelURL = locator?.url(for: descriptor)
        let isPresent = modelURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false

        return InkribeModelDiagnostic(
            id: descriptor.id,
            displayName: descriptor.displayName,
            runtimeVersion: runtimeVersion,
            runtimeBuild: runtimeBuild,
            revision: descriptor.revision,
            expectedByteCount: descriptor.byteCount,
            license: descriptor.license,
            isPresent: isPresent
        )
    }

    private static var architectureName: String {
        #if arch(arm64)
        "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        "Intel (x86_64)"
        #else
        "Unknown"
        #endif
    }
}
