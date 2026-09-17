import Foundation
import InkribeCore
import InkribeExport
import Testing

@Test func textExportsUseRequestedSourceAndPreserveUnicode() throws {
    let transcript = Transcript(
        title: "Phỏng vấn 東京",
        createdAt: Date(timeIntervalSince1970: 0),
        rawText: "raw text",
        editedText: "Xin chào — こんにちは 👋"
    )
    let exporter = TranscriptExporter()

    let editedPlain = try exporter.document(
        for: transcript,
        format: .plainText,
        textSource: .edited
    )
    let rawPlain = try exporter.document(
        for: transcript,
        format: .plainText,
        textSource: .raw
    )
    let markdown = try exporter.document(
        for: transcript,
        format: .markdown,
        textSource: .edited
    )

    #expect(editedPlain.content == "Xin chào — こんにちは 👋")
    #expect(rawPlain.content == "raw text")
    #expect(String(decoding: editedPlain.utf8Data, as: UTF8.self) == editedPlain.content)
    #expect(markdown.content == "# Phỏng vấn 東京\n\nXin chào — こんにちは 👋\n")
}

@Test func editedAndRawSourcesPreserveStoredWhitespaceExactly() throws {
    let transcript = Transcript(
        title: "Sources",
        rawText: "  Original Whisper text.  ",
        editedText: "   \n"
    )
    let exporter = TranscriptExporter()

    #expect(exporter.copyText(for: transcript, source: .edited) == "   \n")
    #expect(exporter.copyText(for: transcript, source: .raw) == "  Original Whisper text.  ")

    let edited = try exporter.document(
        for: transcript,
        format: .plainText,
        textSource: .edited
    )
    let raw = try exporter.document(
        for: transcript,
        format: .plainText,
        textSource: .raw
    )
    #expect(edited.content == "   \n")
    #expect(raw.content == "  Original Whisper text.  ")
}

@Test func filenameUsesSafeTitleAndInjectedCalendarDate() throws {
    let transcript = Transcript(
        title: "  Project / Demo: Notes?  ",
        createdAt: Date(timeIntervalSince1970: 0),
        rawText: "Text"
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let exporter = TranscriptExporter(calendar: calendar)

    #expect(
        exporter.fileName(for: transcript, format: .markdown)
            == "Project Demo Notes - 1970-01-01.md"
    )
}

@Test func filenameFallsBackWhenTitleHasNoUsableCharacters() throws {
    let transcript = Transcript(
        title: " / : ? * ",
        createdAt: Date(timeIntervalSince1970: 0)
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let exporter = TranscriptExporter(calendar: calendar)

    #expect(
        exporter.fileName(for: transcript, format: .plainText)
            == "Transcript - 1970-01-01.txt"
    )
}

@Test func srtSortsCuesButPreservesValidOverlappingTimestamps() throws {
    let transcript = Transcript(
        title: "Subtitles",
        segments: [
            TranscriptSegment(startTime: 2.0, endTime: 3.0, text: "Third"),
            TranscriptSegment(startTime: -4.0, endTime: 0.0, text: "First"),
            TranscriptSegment(startTime: 1.5, endTime: 2.5, text: "Second"),
            TranscriptSegment(startTime: .nan, endTime: .nan, text: "   ")
        ]
    )
    let exporter = TranscriptExporter()

    let document = try exporter.document(for: transcript, format: .srt)

    #expect(
        document.content == """
        1
        00:00:00,000 --> 00:00:00,001
        First

        2
        00:00:01,500 --> 00:00:02,500
        Second

        3
        00:00:02,000 --> 00:00:03,000
        Third
        \n"""
    )
}

@Test func vttUsesWebVTTHeaderAndDotMilliseconds() throws {
    let transcript = Transcript(
        title: "VTT",
        segments: [
            TranscriptSegment(startTime: 0.125, endTime: 1.25, text: "Hello"),
            TranscriptSegment(startTime: 1.25, endTime: 61.005, text: "World")
        ]
    )
    let exporter = TranscriptExporter()

    let document = try exporter.document(for: transcript, format: .vtt)

    #expect(
        document.content == """
        WEBVTT

        00:00:00.125 --> 00:00:01.250
        Hello

        00:00:01.250 --> 00:01:01.005
        World
        \n"""
    )
}

@Test func subtitleExportRequiresTimestampedText() {
    let transcript = Transcript(title: "No Segments", rawText: "Text")
    let exporter = TranscriptExporter()

    #expect(throws: TranscriptExportError.noTimestampedSegments) {
        try exporter.document(for: transcript, format: .srt)
    }
}
