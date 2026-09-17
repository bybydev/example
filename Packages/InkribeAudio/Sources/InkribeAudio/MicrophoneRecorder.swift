import AVFoundation
import Foundation
import Observation
#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

public struct AudioInputDevice: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public enum MicrophoneRecordingState: Equatable, Sendable {
    case idle
    case recording
    case paused
}

@MainActor
@Observable
public final class MicrophoneRecorder {
    public private(set) var state: MicrophoneRecordingState = .idle
    public private(set) var level: Double = 0
    public private(set) var recordedDuration: TimeInterval = 0
    public private(set) var availableDevices: [AudioInputDevice] = []
    public private(set) var lastErrorDescription: String?

    private var engine: AVAudioEngine?
    private var sink: RecordingSink?

    public init() {
        refreshInputDevices()
    }

    public func refreshInputDevices() {
        #if os(macOS)
        availableDevices = (try? CoreAudioInputDevices.all()) ?? []
        #else
        if let device = AVCaptureDevice.default(for: .audio) {
            availableDevices = [
                AudioInputDevice(
                    id: device.uniqueID,
                    name: device.localizedName,
                    isDefault: true
                )
            ]
        } else {
            availableDevices = []
        }
        #endif
    }

    public func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }

    public func start(to url: URL, deviceID: String? = nil) throws {
        guard state == .idle else { return }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        #if os(macOS)
        if let deviceID {
            try CoreAudioInputDevices.apply(uid: deviceID, to: input)
        }
        #endif

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.inputFormatUnavailable
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let sink = RecordingSink(
            file: file,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            onLevel: { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.level = value
                }
            },
            onDuration: { [weak self] duration in
                Task { @MainActor [weak self] in
                    self?.recordedDuration = duration
                }
            },
            onError: { [weak self] description in
                Task { @MainActor [weak self] in
                    self?.lastErrorDescription = description
                    self?.stopAfterSinkFailure()
                }
            }
        )

        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { buffer, _ in
            sink.consume(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        self.engine = engine
        self.sink = sink
        level = 0
        recordedDuration = 0
        lastErrorDescription = nil
        state = .recording
    }

    public func pause() {
        guard state == .recording else { return }
        sink?.setPaused(true)
        level = 0
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        sink?.setPaused(false)
        state = .recording
    }

    @discardableResult
    public func stop() -> AudioMediaMetadata? {
        guard state != .idle else { return nil }
        let metadata = sink?.metadata
        tearDown(resetDuration: false)
        return metadata
    }

    public func resetDuration() {
        guard state == .idle else { return }
        recordedDuration = 0
    }

    private func stopAfterSinkFailure() {
        guard state != .idle else { return }
        tearDown(resetDuration: false)
    }

    private func tearDown(resetDuration: Bool) {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()
        }
        engine = nil
        sink = nil
        level = 0
        if resetDuration { recordedDuration = 0 }
        state = .idle
    }

    public enum RecorderError: LocalizedError, Equatable, Sendable {
        case inputFormatUnavailable

        public var errorDescription: String? {
            "The selected microphone does not provide a usable audio format."
        }
    }
}

private final class RecordingSink: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private let sampleRate: Double
    private let channelCount: Int
    private let onLevel: @Sendable (Double) -> Void
    private let onDuration: @Sendable (TimeInterval) -> Void
    private let onError: @Sendable (String) -> Void

    private var paused = false
    private var hasFailed = false
    private var writtenFrames: AVAudioFramePosition = 0

    init(
        file: AVAudioFile,
        sampleRate: Double,
        channelCount: Int,
        onLevel: @escaping @Sendable (Double) -> Void,
        onDuration: @escaping @Sendable (TimeInterval) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.file = file
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.onLevel = onLevel
        self.onDuration = onDuration
        self.onError = onError
    }

    var metadata: AudioMediaMetadata {
        lock.lock()
        defer { lock.unlock() }
        return AudioMediaMetadata(
            duration: sampleRate > 0 ? Double(writtenFrames) / sampleRate : 0,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        self.paused = paused
        lock.unlock()
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let meter = Self.meterLevel(buffer)

        lock.lock()
        defer { lock.unlock() }
        guard !paused, !hasFailed else { return }

        do {
            try file.write(from: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
            let duration = sampleRate > 0 ? Double(writtenFrames) / sampleRate : 0
            onLevel(meter)
            onDuration(duration)
        } catch {
            hasFailed = true
            onError(String(describing: error))
        }
    }

    private static func meterLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sumSquares: Double = 0
        var sampleCount = 0
        for channel in 0..<channelCount {
            let values = channels[channel]
            for frame in 0..<frameCount {
                let sample = Double(values[frame])
                sumSquares += sample * sample
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return 0 }

        let rms = sqrt(sumSquares / Double(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

#if os(macOS)
private enum CoreAudioInputDevices {
    static func all() throws -> [AudioInputDevice] {
        let deviceIDs = try audioDeviceIDs()
        let defaultID = try? defaultInputDeviceID()
        return deviceIDs.compactMap { id in
            guard hasInputStreams(id),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName) else {
                return nil
            }
            return AudioInputDevice(
                id: uid,
                name: name,
                isDefault: id == defaultID
            )
        }
        .sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func apply(uid: String, to inputNode: AVAudioInputNode) throws {
        guard let deviceID = try audioDeviceIDs().first(where: {
            stringProperty($0, selector: kAudioDevicePropertyDeviceUID) == uid
        }) else {
            throw DeviceError.notFound
        }
        guard let audioUnit = inputNode.audioUnit else {
            throw DeviceError.audioUnitUnavailable
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw DeviceError.couldNotSelect(status)
        }
    }

    private static func audioDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr else { throw DeviceError.coreAudio(status) }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: count)
        status = devices.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return noErr }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                UnsafeMutableRawPointer(baseAddress)
            )
        }
        guard status == noErr else { throw DeviceError.coreAudio(status) }
        return devices
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else { throw DeviceError.coreAudio(status) }
        return deviceID
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(
            id,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }
        return value as String
    }

    enum DeviceError: LocalizedError {
        case notFound
        case audioUnitUnavailable
        case couldNotSelect(OSStatus)
        case coreAudio(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound:
                "The selected microphone is no longer available."
            case .audioUnitUnavailable:
                "The microphone audio unit is unavailable."
            case .couldNotSelect(let status), .coreAudio(let status):
                "Microphone configuration failed with status \(status)."
            }
        }
    }
}
#endif
