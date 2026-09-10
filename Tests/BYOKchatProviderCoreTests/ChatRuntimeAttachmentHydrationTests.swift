import Foundation
import Testing

@testable import BYOKchatProviderCore

@Suite("Chat runtime attachment hydration")
struct ChatRuntimeAttachmentHydrationTests {
  @Test("Missing historical attachment is omitted without blocking a later user turn")
  func historicalMissingAttachmentIsDropped() async throws {
    let missing = ChatAttachment(
      id: "missing-old",
      kind: .file,
      filename: "old.pdf",
      mimeType: "application/pdf",
      data: Data(),
      declaredByteCount: 12
    )
    var messages: [ProviderMessage] = [
      ProviderMessage(role: .user, content: "Old request", attachments: [missing]),
      ProviderMessage(role: .assistant, content: "Old response"),
      ProviderMessage(role: .user, content: "Continue without that file"),
    ]

    try await hydrateChatRuntimeAttachments(into: &messages) { _ in nil }

    #expect(messages[0].attachments == nil)
    #expect(messages[2].content == "Continue without that file")
  }

  @Test("Missing attachment on latest user turn fails instead of silently changing the prompt")
  func currentMissingAttachmentFails() async {
    let missing = ChatAttachment(
      id: "missing-current",
      kind: .file,
      filename: "current.pdf",
      mimeType: "application/pdf",
      data: Data(),
      declaredByteCount: 12
    )
    var messages: [ProviderMessage] = [
      ProviderMessage(role: .user, content: "Analyze this", attachments: [missing])
    ]

    await #expect(throws: ProviderError.self) {
      try await hydrateChatRuntimeAttachments(into: &messages) { _ in nil }
    }
  }

  @Test("Available metadata-only attachment is hydrated for the provider request")
  func availableAttachmentIsHydrated() async throws {
    let attachment = ChatAttachment(
      id: "available",
      kind: .file,
      filename: "notes.txt",
      mimeType: "text/plain",
      data: Data(),
      declaredByteCount: 5
    )
    var messages: [ProviderMessage] = [
      ProviderMessage(role: .user, content: "Read this", attachments: [attachment])
    ]

    try await hydrateChatRuntimeAttachments(into: &messages) { id in
      id == "available" ? Data("hello".utf8) : nil
    }

    #expect(messages[0].attachments?.first?.data == Data("hello".utf8))
  }
}
