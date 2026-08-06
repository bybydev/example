import BYOKchatProviderCore
import SwiftUI

struct ProviderCoreDebugView: View {
  @State private var providerID: ProviderID = BuiltInProviders.deepSeekID
  @State private var apiKey = ""
  @State private var model = "deepseek-v4-flash"
  @State private var prompt = "Explain why native streaming matters in an AI chat app."
  @State private var visibleText = ""
  @State private var reasoningText = ""
  @State private var status = "Ready"
  @State private var generationTask: Task<Void, Never>?

  private let transport = URLSessionProviderHTTPTransport()

  var body: some View {
    NavigationStack {
      Form {
        Section("Provider") {
          Picker("Provider", selection: $providerID) {
            Text("DeepSeek").tag(BuiltInProviders.deepSeekID)
            Text("OpenRouter").tag(BuiltInProviders.openRouterID)
            Text("NVIDIA").tag(BuiltInProviders.nvidiaID)
          }
          .onChange(of: providerID) { _, value in
            model =
              switch value {
              case BuiltInProviders.deepSeekID: "deepseek-v4-flash"
              case BuiltInProviders.openRouterID: "openrouter/free"
              default: "deepseek-ai/deepseek-v4-flash"
              }
          }
          SecureField("API key", text: $apiKey)
          TextField("Model", text: $model)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }

        Section("Prompt") {
          TextEditor(text: $prompt)
            .frame(minHeight: 100)
        }

        Section("Actions") {
          Button("Stream test") { startStream() }
            .disabled(apiKey.isEmpty || model.isEmpty || generationTask != nil)
          Button("Stop", role: .destructive) {
            generationTask?.cancel()
            generationTask = nil
            status = "Cancelled"
          }
          .disabled(generationTask == nil)
        }

        Section("Status") {
          Text(status)
          if !reasoningText.isEmpty {
            DisclosureGroup("Reasoning") {
              Text(reasoningText).textSelection(.enabled)
            }
          }
          if !visibleText.isEmpty {
            Text(visibleText).textSelection(.enabled)
          }
        }
      }
      .navigationTitle("Provider Core")
    }
  }

  private func startStream() {
    generationTask?.cancel()
    visibleText = ""
    reasoningText = ""
    status = "Connecting…"
    let selectedProvider = providerID
    let key = apiKey
    let selectedModel = model
    let input = prompt

    generationTask = Task {
      do {
        let definition = try definition(for: selectedProvider)
        let adapter = OpenAICompatibleAdapter(definition: definition, transport: transport)
        let account = ResolvedProviderAccount(
          id: ProviderAccountID(rawValue: "debug-\(selectedProvider.rawValue)"),
          providerID: selectedProvider,
          label: "Debug",
          apiKey: key,
          metadata: ["appTitle": "BYOKchat"]
        )
        let options = ProviderRequestOptions(
          reasoning: selectedProvider == BuiltInProviders.deepSeekID
            ? ReasoningOptions(enabled: true, effort: .high)
            : nil
        )
        status = "Streaming…"
        for try await event in adapter.stream(
          request: ProviderRequest(
            model: ModelID(rawValue: selectedModel),
            messages: [.init(role: .user, content: input)],
            options: options
          ),
          account: account
        ) {
          switch event {
          case .textDelta(let value): visibleText += value
          case .reasoningDelta(let value): reasoningText += value
          case .usage(let value):
            status = "Usage: \(value.inputTokens ?? 0) in / \(value.outputTokens ?? 0) out"
          case .completed:
            status = "Completed"
          }
        }
      } catch is CancellationError {
        status = "Cancelled"
      } catch {
        status = error.localizedDescription
      }
      generationTask = nil
    }
  }

  private func definition(for id: ProviderID) throws -> ProviderDefinition {
    switch id {
    case BuiltInProviders.deepSeekID: BuiltInProviders.deepSeek
    case BuiltInProviders.openRouterID: BuiltInProviders.openRouter
    case BuiltInProviders.nvidiaID: BuiltInProviders.nvidia
    default: throw ProviderError.providerNotFound(id)
    }
  }
}
