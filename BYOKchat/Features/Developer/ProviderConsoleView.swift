import AppFoundation
import BYOKchatProviderCore
import Foundation
import SwiftUI

struct ProviderConsoleView: View {
  @Bindable var model: ProviderManagementModel

  @State private var accountID: ProviderAccountID?
  @State private var modelID: ModelID?
  @State private var prompt = "Explain why native streaming matters in an AI chat app."
  @State private var includeReasoning = true
  @State private var visibleText = ""
  @State private var reasoningText = ""
  @State private var status = "Ready"
  @State private var generationTask: Task<Void, Never>?
  @State private var generationRevision: UInt64 = 0
  @Environment(\.appFoundationTheme) private var theme

  private var selectedAccount: ProviderAccount? {
    model.accounts.first { $0.id == accountID }
  }

  private var availableModels: [AccountModelRecord] {
    guard let accountID else { return [] }
    return model.models(for: accountID)
  }

  var body: some View {
    Form {
      Section("Target") {
        Picker("Account", selection: $accountID) {
          Text("Select account").tag(ProviderAccountID?.none)
          ForEach(model.accounts.filter(\.isEnabled)) { account in
            Text(account.label).tag(Optional(account.id))
          }
        }
        .onChange(of: accountID) { _, value in
          modelID =
            model.accounts.first(where: { $0.id == value })?.defaultModelID
            ?? value.flatMap { model.models(for: $0).first?.model.id }
        }

        Picker("Model", selection: $modelID) {
          Text("Select model").tag(ModelID?.none)
          ForEach(availableModels) { record in
            Text(record.model.displayName).tag(Optional(record.model.id))
          }
        }
        Toggle("Show reasoning", isOn: $includeReasoning)
      }
      .listRowBackground(theme.surfaceColor)

      Section("Prompt") {
        TextEditor(text: $prompt)
          .frame(minHeight: 120)
      }
      .listRowBackground(theme.surfaceColor)

      Section("Actions") {
        Button("Stream", systemImage: "paperplane.fill") { startStream() }
          .disabled(accountID == nil || modelID == nil || prompt.isEmpty || generationTask != nil)
        Button("Stop", systemImage: "stop.fill", role: .destructive) { stop() }
          .disabled(generationTask == nil)
      }
      .listRowBackground(theme.surfaceColor)

      Section("Status") {
        Text(status)
        if !reasoningText.isEmpty {
          DisclosureGroup("Reasoning") {
            Text(reasoningText)
              .textSelection(.enabled)
          }
        }
        if !visibleText.isEmpty {
          Text(visibleText)
            .textSelection(.enabled)
        }
      }
      .listRowBackground(theme.surfaceColor)
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Console")
    .onAppear {
      if accountID == nil {
        accountID = model.accounts.first?.id
        modelID =
          model.accounts.first?.defaultModelID
          ?? model.accounts.first.flatMap { model.models(for: $0.id).first?.model.id }
      }
    }
    .onDisappear { stop() }
  }

  private func startStream() {
    guard let accountID, let modelID else { return }
    generationTask?.cancel()
    generationRevision &+= 1
    let revision = generationRevision
    let requestPrompt = prompt
    let requestReasoning = includeReasoning

    visibleText = ""
    reasoningText = ""
    status = "Connecting…"

    generationTask = Task { @MainActor in
      do {
        let stream = try await model.stream(
          accountID: accountID,
          modelID: modelID,
          prompt: requestPrompt,
          reasoning: requestReasoning
        )
        guard generationRevision == revision else { return }
        status = "Streaming…"

        for try await event in stream {
          try Task.checkCancellation()
          guard generationRevision == revision else { return }
          switch event {
          case .textDelta(let value): visibleText += value
          case .reasoningDelta(let value): reasoningText += value
          case .usage(let value):
            status = "\(value.inputTokens ?? 0) input · \(value.outputTokens ?? 0) output"
          case .completed(let response):
            status = response.metadata["provider"].map { "Completed via \($0)" } ?? "Completed"
          }
        }
      } catch is CancellationError {
        guard generationRevision == revision else { return }
        status = "Cancelled"
      } catch {
        guard generationRevision == revision else { return }
        status = error.localizedDescription
      }

      guard generationRevision == revision else { return }
      generationTask = nil
    }
  }

  private func stop() {
    generationRevision &+= 1
    generationTask?.cancel()
    generationTask = nil
    if status == "Streaming…" || status == "Connecting…" { status = "Cancelled" }
  }
}
