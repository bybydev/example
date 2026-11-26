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
  @ObservationIgnored private var isReasoningRenderEnabled = false
  @ObservationIgnored private var answerRenderTask: Task<Void, Never>?
  @ObservationIgnored private var reasoningRenderTask: Task<Void, Never>?

  init(messageID: ChatMessageID) {
    self.messageID = messageID
  }

  /// Reasoning disclosures start collapsed, so skip rich Markdown streaming
  /// parses until the user actually expands the reasoning block.
  func setReasoningRenderEnabled(_ enabled: Bool) {
    guard isReasoningRenderEnabled != enabled else { return }
    isReasoningRenderEnabled = enabled
    if enabled {
      if !reasoning.isEmpty, reasoningAppliedRevision < reasoningRenderRevision {
        scheduleReasoningRender()
      }
    } else {
      reasoningRenderTask?.cancel()
      reasoningRenderTask = nil
    }
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
      if isReasoningRenderEnabled {
        scheduleReasoningRender()
      }
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

  /// A live presentation owns asynchronous rich-render work in addition to the
  /// session model's presentation-coalescing task. Cancel both render lanes
  /// before this presentation is replaced or removed so completed/tool-round
  /// messages cannot leave stale Markdown/reasoning work running.
  func cancelPendingRenders() {
    answerRenderTask?.cancel()
    reasoningRenderTask?.cancel()
    answerRenderTask = nil
    reasoningRenderTask = nil
    answerCompleteRequested = false
    reasoningCompleteRequested = false
  }

  var hasPendingRenderWork: Bool {
    answerRenderTask != nil || reasoningRenderTask != nil
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
      if !Task.isCancelled, isReasoningRenderEnabled, reasoningAppliedRevision < reasoningRenderRevision {
        scheduleReasoningRender()
      }
    }
  }
}
