import Foundation

struct MacRenderedAnswerBlock: Identifiable, Equatable, Sendable {
  let id: Int
  let block: MacAnswerContentBlock
}

struct MacStreamingAnswerSnapshot: Equatable, Sendable {
  var stableBlocks: [MacRenderedAnswerBlock]
  var tailBlocks: [MacAnswerContentBlock]
  var revision: Int

  static let empty = MacStreamingAnswerSnapshot(
    stableBlocks: [],
    tailBlocks: [],
    revision: 0
  )
}

/// Per-message incremental renderer state. The session model already coalesces
/// provider events to the presentation cadence, so this actor is the serialized
/// parsing pump: it freezes immutable source once, reparses only newly pending
/// source plus one mutable tail, and keeps parsing off the main actor.
actor MacStreamingAnswerRenderer {
  private var stableSource = ""
  private var stableBlocks: [MacRenderedAnswerBlock] = []
  private var nextBlockID = 0
  private var revision = 0

  func update(source: String, complete: Bool = false) -> MacStreamingAnswerSnapshot {
    revision &+= 1

    if !source.hasPrefix(stableSource) {
      reset()
    }

    let stableByteCount = stableSource.utf8.count
    let pending = String(decoding: source.utf8.dropFirst(stableByteCount), as: UTF8.self)
    let split = complete
      ? (stable: pending, tail: "")
      : MacAnswerContentParser.splitStreamingSource(pending)

    if !split.stable.isEmpty {
      for block in MacAnswerContentParser.parse(split.stable) {
        stableBlocks.append(MacRenderedAnswerBlock(id: nextBlockID, block: block))
        nextBlockID &+= 1
      }
      stableSource += split.stable
    }

    let tailBlocks = split.tail.isEmpty
      ? []
      : MacAnswerContentParser.parse(split.tail)

    return MacStreamingAnswerSnapshot(
      stableBlocks: stableBlocks,
      tailBlocks: tailBlocks,
      revision: revision
    )
  }

  private func reset() {
    stableSource = ""
    stableBlocks = []
    nextBlockID = 0
  }
}
