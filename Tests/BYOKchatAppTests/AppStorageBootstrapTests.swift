import BYOKchatProviderCore
import Foundation
import Testing

@testable import BYOKchat

@Suite("App storage bootstrap")
struct AppStorageBootstrapTests {
  @Test("Schema-less provider workspace migrates to schema one")
  func migratesLegacyProviderWorkspace() throws {
    let input = try JSONSerialization.data(withJSONObject: [:])
    let output = try AppStorageBootstrap.migrateDataForTesting(
      input,
      kind: .providers,
      currentSchemaVersion: 1
    )
    let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    #expect((object["schemaVersion"] as? NSNumber)?.intValue == 1)
    #expect((object["accounts"] as? [Any])?.isEmpty == true)
    #expect((object["modelRecords"] as? [Any])?.isEmpty == true)
    #expect((object["customProviders"] as? [Any])?.isEmpty == true)
  }

  @Test("Current workspace is left byte-for-byte unchanged")
  func currentDataIsUnchanged() throws {
    let input = Data("{\"schemaVersion\":1,\"conversations\":[]}".utf8)
    let output = try AppStorageBootstrap.migrateDataForTesting(
      input,
      kind: .conversations,
      currentSchemaVersion: 1
    )
    #expect(output == input)
  }

  @Test("Newer workspace is rejected without migration")
  func rejectsNewerWorkspace() throws {
    let input = Data("{\"schemaVersion\":2,\"projects\":[],\"conversationProjectIDs\":{}}".utf8)
    do {
      _ = try AppStorageBootstrap.migrateDataForTesting(
        input,
        kind: .projects,
        currentSchemaVersion: 1
      )
      Issue.record("Expected newer schema to be rejected")
    } catch let error as AppStorageMigrationError {
      #expect(error == .newerVersion(store: "projects", stored: 2, supported: 1))
    }
  }
}

@Suite("Library view support")
struct LibraryViewSupportTests {
  @Test("Date grouper classifies future dates as Upcoming and never emits duplicate section titles")
  func dateGrouperUniqueSections() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 14))!
    let future = calendar.date(byAdding: .day, value: 3, to: now)!
    let today = calendar.date(byAdding: .hour, value: -2, to: now)!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    let fourDaysAgo = calendar.date(byAdding: .day, value: -4, to: now)!
    let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: now)!
    let older = calendar.date(byAdding: .day, value: -45, to: now)!

    func makeEntry(_ name: String, createdAt: Date) -> LibraryEntry {
      LibraryEntry(
        filename: name,
        kind: .file,
        mimeType: "text/plain",
        byteCount: 16,
        createdAt: createdAt
      )
    }

    let entries = [
      makeEntry("future.txt", createdAt: future),
      makeEntry("today.txt", createdAt: today),
      makeEntry("yesterday.txt", createdAt: yesterday),
      makeEntry("four-days.txt", createdAt: fourDaysAgo),
      makeEntry("older.txt", createdAt: older),
      // Deliberately out-of-order entry in the same bucket to verify title deduplication.
      makeEntry("six-days.txt", createdAt: sixDaysAgo),
    ]

    let sections = LibraryDateGrouper.sections(for: entries, now: now, calendar: calendar)
    let titles = sections.map(\.title)
    #expect(Set(titles).count == titles.count)
    #expect(titles.prefix(4) == ["Upcoming", "Today", "Yesterday", "Previous 7 Days"])
    #expect(sections[3].entries.map(\.filename) == ["four-days.txt", "six-days.txt"])
  }

  @Test("Temp file support sanitizes path separators and cleans up materialized directories")
  func tempFileSanitizationAndCleanup() throws {
    #expect(LibraryTempFileSupport.safeFilename("2026/04:report.pdf") == "2026-04-report.pdf")
    #expect(LibraryTempFileSupport.safeFilename(".") == "file")
    #expect(LibraryTempFileSupport.safeFilename("..") == "file")
    #expect(LibraryTempFileSupport.safeFilename("   ") == "file")
    #expect(LibraryTempFileSupport.safeFilename(".env") == "file.env")

    let payload = Data("report bytes".utf8)
    let materialized = try LibraryTempFileSupport.materializeTempFile(
      directoryPrefix: "LibrarySupportTests",
      filename: "nested/dir/report.pdf",
      data: payload
    )
    defer { LibraryTempFileSupport.cleanupDirectory(materialized.directory) }

    #expect(materialized.fileURL.lastPathComponent == "nested-dir-report.pdf")
    #expect(try Data(contentsOf: materialized.fileURL) == payload)

    LibraryTempFileSupport.cleanupDirectory(materialized.directory)
    #expect(!FileManager.default.fileExists(atPath: materialized.directory.path))
  }

  @Test("Photo import support preserves PNG and JPEG payloads without lossy re-encoding")
  func photoImportPreservesSupportedFormats() {
    let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
    let png = LibraryImportSupport.preparedPhotoPayload(from: pngHeader)
    #expect(png?.mimeType == "image/png")
    #expect(png?.fileExtension == "png")
    #expect(png?.data == pngHeader)

    let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    let jpeg = LibraryImportSupport.preparedPhotoPayload(from: jpegHeader)
    #expect(jpeg?.mimeType == "image/jpeg")
    #expect(jpeg?.fileExtension == "jpg")
    #expect(jpeg?.data == jpegHeader)
  }

  @Test("Batch error formatter deduplicates and summarizes overflow errors")
  func batchErrorFormatting() {
    let formatted = LibraryImportSupport.formattedBatchErrors([
      "Error A",
      "Error A",
      "Error B",
      "Error C",
      "Error D",
      "Error E",
    ])
    #expect(formatted == "Error A\nError B\nError C\nAnd 2 more errors.")
  }
}
