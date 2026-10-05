import Foundation

/// Request-only projection. Stored attachments, tool rounds, and MCP configuration are never edited.
public enum ModelRequestPolicy {
  public static func attachmentError(
    _ attachment: ChatAttachment, kind: ProviderKind, capabilities: ResolvedModelCapabilities
  ) -> String? {
    if attachment.byteCount > 20 * 1_024 * 1_024 {
      return "\(attachment.filename) exceeds the 20 MB attachment limit."
    }
    let mime = attachment.mimeType.lowercased()
    let capability: ModelCapability = attachment.isImage ? .imageInput
      : mime.hasPrefix("audio/") ? .audioInput
      : attachment.utf8Text != nil ? .textInput : .fileInput
    if capabilities[capability] == .unsupported {
      return "\(attachment.filename) is not supported by the selected model. Choose another model or remove the attachment."
    }
    if attachment.isImage, kind != .gemini {
      let formats = kind == .xAI ? ["image/jpeg", "image/jpg", "image/png"]
        : ["image/jpeg", "image/png", "image/gif", "image/webp"]
      if !formats.contains(mime) {
        return "Unsupported image type for \(attachment.filename). Convert it to PNG or JPEG."
      }
    }
    if kind == .anthropic {
      if !attachment.isImage, attachment.utf8Text == nil, mime != "application/pdf" {
        return "Anthropic supports text files, images, and PDFs. \(attachment.filename) must be converted first."
      }
    }
    return nil
  }

  public static func validateAttachments(
    _ attachments: [ChatAttachment], kind: ProviderKind, capabilities: ResolvedModelCapabilities
  ) throws {
    guard attachments.count <= 8 else {
      throw ProviderError.invalidRequest("A message can include at most 8 attachments.")
    }
    guard attachments.reduce(0, { $0 + $1.byteCount }) <= 40 * 1_024 * 1_024 else {
      throw ProviderError.invalidRequest("Attachments in one message cannot exceed 40 MB total.")
    }
    for attachment in attachments {
      if let error = attachmentError(attachment, kind: kind, capabilities: capabilities) {
        throw ProviderError.invalidRequest(error)
      }
    }
  }

  public static func project(
    messages: [ProviderMessage], kind: ProviderKind, capabilities: ResolvedModelCapabilities,
    validateLatestUser: Bool = true
  ) throws -> [ProviderMessage] {
    let latestUser = messages.lastIndex { $0.role == .user }
    return try messages.enumerated().compactMap { index, original in
      var message = original
      let attachments = message.attachments ?? []
      if validateLatestUser, index == latestUser {
        try validateAttachments(attachments, kind: kind, capabilities: capabilities)
      } else {
        var kept: [ChatAttachment] = []
        var omitted: [ChatAttachment] = []
        var totalBytes = 0
        for attachment in attachments {
          if attachmentError(attachment, kind: kind, capabilities: capabilities) != nil
            || kept.count >= 8 || totalBytes + attachment.byteCount > 40 * 1_024 * 1_024 {
            omitted.append(attachment)
          } else {
            kept.append(attachment)
            totalBytes += attachment.byteCount
          }
        }
        message.attachments = kept.isEmpty ? nil : kept
        if !omitted.isEmpty {
          let note = "[Earlier attachments omitted for this model: \(omitted.map(\.filename).joined(separator: ", "))]"
          message.content += (message.content.isEmpty ? "" : "\n\n") + note
        }
      }
      if capabilities[.tools] == .unsupported {
        if let calls = message.toolCalls, !calls.isEmpty {
          let note = calls.map { "Earlier tool call: \($0.name) \($0.arguments.compactJSONString())" }.joined(separator: "\n")
          message.content += (message.content.isEmpty ? "" : "\n\n") + note
        }
        if message.role == .tool {
          message.role = .assistant
          let results = (message.toolResults ?? []).map {
            "Earlier tool result (\($0.callID)): \($0.content.compactJSONString())"
          }.joined(separator: "\n")
          if !results.isEmpty { message.content += (message.content.isEmpty ? "" : "\n\n") + results }
        }
        message.toolCalls = nil
        message.toolResults = nil
        message.toolContinuation = nil
      }
      if message.content.isEmpty, (message.attachments ?? []).isEmpty,
        (message.toolCalls ?? []).isEmpty, (message.toolResults ?? []).isEmpty,
        message.toolContinuation == nil { return nil }
      return message
    }
  }

  public static func prepare(_ original: ProviderRequest, kind: ProviderKind) throws -> ProviderRequest {
    var request = original
    let capabilities = request.capabilities ?? ModelCapabilityResolver.resolve(kind: kind, modelID: request.model)
    request.capabilities = capabilities
    if let error = capabilities.reasoning.budgetValidationMessage(request.options.reasoning,
      outputLimit: kind == .anthropic ? (request.options.maxOutputTokens ?? 4_096) : nil) {
      throw ProviderError.invalidRequest(error)
    }
    request.options.reasoning = capabilities.reasoning.normalize(request.options.reasoning)
    if let maximum = capabilities.maxOutputTokens, let requested = request.options.maxOutputTokens,
      requested > maximum {
      throw ProviderError.invalidRequest("The selected model supports at most \(maximum) output tokens.")
    }
    if capabilities[.tools] == .unsupported { request.tools = [] }
    request.messages = try project(messages: request.messages, kind: kind, capabilities: capabilities)
    return request
  }
}
