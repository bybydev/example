import BYOKchatProviderCore
import Observation

@MainActor
@Observable
final class MacLiveMessagePresentation {
  let messageID: ChatMessageID
  private(set) var content = ""
  private(set) var reasoning = ""
  private(set) var usage: ProviderUsage?
  private(set) var answerSnapshot = MacStreamingAnswerSnapshot.empty
  private(set) var reasoningSnapshot = MacStreamingAnswerSnapshot.empty

  @ObservationIgnored private let answerRenderer = MacStreamingAnswerRenderer()
  @ObservationIgnored private let reasoningRenderer = MacStreamingAnswerRenderer()
  @ObservationIgnored private var answerRenderRevision = 0
  @ObservationIgnored private var reasoningRenderRevision = 0
  @ObservationIgnored private var answerAppliedRevision = 0
  @ObservationIgnored private var reasoningAppliedRevision = 0
  @ObservationIgnored private var answerCompleteRequested = false
  @ObservationIgnored private var reasoningCompleteRequested = false
  @ObservationIgnored private var answerRenderTask: Task<Void, Never>?
  @ObservationIgnored private var reasoningRenderTask: Task<Void, Never>?

  init(messageID: ChatMessageID) {
    self.messageID = messageID
  }

  @discardableResult
  func apply(
    content: String,
    reasoning: String,
    usage: ProviderUsage?,
    complete: Bool = false
  ) -> Bool {
    let contentChanged = self.content != content || complete
    let reasoningChanged = self.reasoning != reasoning || complete
    let usageChanged = self.usage != usage

    guard contentChanged || reasoningChanged || usageChanged else { return false }

    self.content = content
    self.reasoning = reasoning
    self.usage = usage

    if contentChanged {
      answerRenderRevision &+= 1
      answerCompleteRequested = answerCompleteRequested || complete
      scheduleAnswerRender()
    }
    if reasoningChanged {
      reasoningRenderRevision &+= 1
      reasoningCompleteRequested = reasoningCompleteRequested || complete
      scheduleReasoningRender()
    }
    return true
  }

  func resolve(_ stored: ChatMessage) -> ChatMessage {
    var result = stored
    result.content = content
    result.reasoning = reasoning
    result.usage = usage ?? stored.usage
    result.status = .streaming
    return result
  }

  private func scheduleAnswerRender() {
    guard answerRenderTask == nil else { return }
    answerRenderTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let revision = answerRenderRevision
        let source = content
        let complete = answerCompleteRequested
        let snapshot = await answerRenderer.update(source: source, complete: complete)
        guard !Task.isCancelled else { break }

        if revision == answerRenderRevision {
          answerSnapshot = snapshot
          answerAppliedRevision = revision
          answerCompleteRequested = false
          break
        }
      }
      answerRenderTask = nil
      if !Task.isCancelled, answerAppliedRevision < answerRenderRevision {
        scheduleAnswerRender()
      }
    }
  }

  private func scheduleReasoningRender() {
    guard reasoningRenderTask == nil else { return }
    reasoningRenderTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let revision = reasoningRenderRevision
        let source = reasoning
        let complete = reasoningCompleteRequested
        let snapshot = await reasoningRenderer.update(source: source, complete: complete)
        guard !Task.isCancelled else { break }

        if revision == reasoningRenderRevision {
          reasoningSnapshot = snapshot
          reasoningAppliedRevision = revision
          reasoningCompleteRequested = false
          break
        }
      }
      reasoningRenderTask = nil
      if !Task.isCancelled, reasoningAppliedRevision < reasoningRenderRevision {
        scheduleReasoningRender()
      }
    }
  }
}
