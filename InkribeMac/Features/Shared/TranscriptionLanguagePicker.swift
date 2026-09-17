import InkribeTranscription
import SwiftUI

struct TranscriptionLanguagePicker: View {
    @Binding var selection: String

    var body: some View {
        Picker("Language", selection: $selection) {
            ForEach(TranscriptionLanguageCatalog.options) { option in
                Text(option.displayName).tag(option.code)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 220)
    }

    static func requestedLanguage(for selection: String) -> String? {
        TranscriptionLanguageCatalog.requestedLanguage(for: selection)
    }
}
