import InkribeTranscription
import Testing

@Test func languageCatalogNormalizesSupportedSelections() {
    #expect(TranscriptionLanguageCatalog.normalizedSelection(nil) == "auto")
    #expect(TranscriptionLanguageCatalog.normalizedSelection(" VI ") == "vi")
    #expect(TranscriptionLanguageCatalog.normalizedSelection("unsupported") == "auto")
}

@Test func languageCatalogMapsAutomaticToNilRequest() {
    #expect(TranscriptionLanguageCatalog.requestedLanguage(for: "auto") == nil)
    #expect(TranscriptionLanguageCatalog.requestedLanguage(for: "EN") == "en")
}
