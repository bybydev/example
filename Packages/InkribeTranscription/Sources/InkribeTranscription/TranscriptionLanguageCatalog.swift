import Foundation

public struct TranscriptionLanguageOption: Equatable, Hashable, Sendable, Identifiable {
    public let code: String
    public let displayName: String

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    public var id: String { code }
}

public enum TranscriptionLanguageCatalog {
    public static let automaticCode = "auto"

    public static let options: [TranscriptionLanguageOption] = [
        .init(code: automaticCode, displayName: "Automatic"),
        .init(code: "en", displayName: "English"),
        .init(code: "vi", displayName: "Vietnamese"),
        .init(code: "zh", displayName: "Chinese"),
        .init(code: "ja", displayName: "Japanese"),
        .init(code: "ko", displayName: "Korean"),
        .init(code: "es", displayName: "Spanish"),
        .init(code: "fr", displayName: "French"),
        .init(code: "de", displayName: "German"),
        .init(code: "it", displayName: "Italian"),
        .init(code: "pt", displayName: "Portuguese")
    ]

    public static var supportedCodes: Set<String> {
        Set(options.map(\.code))
    }

    public static func normalizedSelection(_ value: String?) -> String {
        guard let value else { return automaticCode }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return supportedCodes.contains(normalized) ? normalized : automaticCode
    }

    public static func requestedLanguage(for selection: String?) -> String? {
        let normalized = normalizedSelection(selection)
        return normalized == automaticCode ? nil : normalized
    }
}
