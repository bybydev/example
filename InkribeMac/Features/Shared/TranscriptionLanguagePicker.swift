import SwiftUI

struct TranscriptionLanguagePicker: View {
    @Binding var selection: String

    static let options: [(code: String, name: String)] = [
        ("auto", "Automatic"),
        ("en", "English"),
        ("vi", "Vietnamese"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese")
    ]

    var body: some View {
        Picker("Language", selection: $selection) {
            ForEach(Self.options, id: \.code) { option in
                Text(option.name).tag(option.code)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 220)
    }

    static func requestedLanguage(for selection: String) -> String? {
        selection == "auto" ? nil : selection
    }
}
