import BYOKchatProviderCore
import Testing

@testable import BYOKmac

@Suite("macOS stream accumulator")
struct MacStreamAccumulatorTests {
  @Test("Raw deltas coalesce behind one presentation gate")
  func coalescesPresentationRequests() async {
    let accumulator = MacStreamAccumulator()
    let messageID = ChatMessageID(rawValue: "stream-test")

    #expect(await accumulator.appendText("Hello", to: messageID))
    #expect(!(await accumulator.appendText(" world", to: messageID)))
    #expect(!(await accumulator.appendReasoning("thinking", to: messageID)))

    let first = await accumulator.takeSnapshot(for: messageID)
    #expect(first?.content == "Hello world")
    #expect(first?.reasoning == "thinking")

    #expect(await accumulator.appendText("!", to: messageID))
    let second = await accumulator.takeSnapshot(for: messageID)
    #expect(second?.content == "Hello world!")
  }

  @Test("Removing a stream clears snapshot and presentation gate")
  func removalClearsState() async {
    let accumulator = MacStreamAccumulator()
    let messageID = ChatMessageID(rawValue: "stream-remove")

    #expect(await accumulator.appendText("partial", to: messageID))
    await accumulator.remove(messageID)
    #expect(await accumulator.takeSnapshot(for: messageID) == nil)

    #expect(await accumulator.appendText("fresh", to: messageID))
    #expect(await accumulator.takeSnapshot(for: messageID)?.content == "fresh")
  }
}
