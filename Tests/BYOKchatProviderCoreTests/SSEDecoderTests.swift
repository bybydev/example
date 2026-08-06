import Foundation
import Testing

@testable import BYOKchatProviderCore

@Test func decodesChunkedSSEAndIgnoresComments() throws {
  var decoder = SSEDecoder()
  let first = Data(
    ": OPENROUTER PROCESSING\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hel".utf8)
  let second = Data("lo\"}}]}\n\ndata: [DONE]\n\n".utf8)

  #expect(try decoder.append(first).isEmpty)
  let events = try decoder.append(second)
  #expect(events.count == 2)
  #expect(events[0].data.contains("Hello"))
  #expect(events[1].data == "[DONE]")
}

@Test func decodesMultiLineData() throws {
  var decoder = SSEDecoder()
  let events = try decoder.append(Data("event: message\ndata: first\ndata: second\n\n".utf8))
  #expect(events == [ServerSentEvent(event: "message", data: "first\nsecond")])
}
