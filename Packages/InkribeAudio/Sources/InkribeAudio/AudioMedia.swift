import Foundation

public struct AudioMediaMetadata: Codable, Equatable, Sendable {
    public let duration: TimeInterval
    public let sampleRate: Double
    public let channelCount: Int

    public init(duration: TimeInterval, sampleRate: Double, channelCount: Int) {
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public struct DurableMediaReference: Codable, Equatable, Hashable, Sendable {
    public let relativePath: String

    public init(relativePath: String) {
        self.relativePath = relativePath
    }
}
