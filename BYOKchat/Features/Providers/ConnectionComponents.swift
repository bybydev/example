import AppFoundation
import BYOKchatProviderCore
import SwiftUI

struct ConnectionCredentialFields: View {
  let provider: ProviderDefinition
  let hasStoredCredential: Bool
  @Binding var credential: String
  @Binding var baseURL: String
  @Binding var headersText: String
  @Binding var appTitle: String
  @Binding var httpReferer: String

  @State private var replaceCredential = false
  @State private var showAdvanced = false
  @State private var showKeyHelp = false

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(spacing: 14) {
      ConnectionSurface {
        if connectionRequiresCredential(provider) {
          if hasStoredCredential && !replaceCredential {
            HStack(spacing: 12) {
              Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(theme.secondaryForegroundColor)
              VStack(alignment: .leading, spacing: 3) {
                Text("API Key")
                  .font(.system(size: 15, weight: .medium))
                Text("Saved securely in Keychain")
                  .font(.caption)
                  .foregroundStyle(theme.secondaryForegroundColor)
              }
              Spacer()
              Button("Replace") { replaceCredential = true }
                .font(.system(size: 14, weight: .semibold))
            }
          } else {
            VStack(alignment: .leading, spacing: 8) {
              Text("API Key")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondaryForegroundColor)
              SecureField("Paste your API key", text: $credential)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16))
            }
          }
        } else {
          Label("No API key required", systemImage: "checkmark.shield")
            .font(.system(size: 15, weight: .medium))
        }
      }

      if connectionRequiresCredential(provider) {
        Button("Where do I find my API key?") { showKeyHelp = true }
          .font(.system(size: 14, weight: .medium))
      }

      ConnectionSurface {
        DisclosureGroup("Advanced Settings", isExpanded: $showAdvanced) {
          VStack(alignment: .leading, spacing: 16) {
            Divider().padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
              Text("Endpoint Override")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryForegroundColor)
              TextField("Use provider default", text: $baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            }
            if provider.id == BuiltInProviders.openRouterID {
              VStack(alignment: .leading, spacing: 6) {
                Text("OpenRouter App Title")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(theme.secondaryForegroundColor)
                TextField("BYOKchat", text: $appTitle)
              }
              VStack(alignment: .leading, spacing: 6) {
                Text("HTTP Referer")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(theme.secondaryForegroundColor)
                TextField("Optional", text: $httpReferer)
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
                  .keyboardType(.URL)
              }
            }
            VStack(alignment: .leading, spacing: 6) {
              Text("Additional Headers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryForegroundColor)
              TextEditor(text: $headersText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 84)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
          }
        }
        .font(.system(size: 15, weight: .medium))
      }

      Text("Your key is stored in Keychain and sent only to \(provider.displayName) when BYOKchat makes a request.")
        .font(.caption)
        .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
    }
    .alert("Finding your API key", isPresented: $showKeyHelp) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Open the \(provider.displayName) developer console, create an API key, then copy and paste it here. BYOKchat never needs your provider password.")
    }
  }
}

struct ConnectionPreferencesFields: View {
  @Binding var connectionName: String
  @Binding var selectedModelID: ModelID?
  @Binding var manualModelID: String
  let models: [AccountModelRecord]

  @Environment(\.appFoundationTheme) private var theme

  private var selectedModel: AccountModelRecord? {
    guard let selectedModelID else { return nil }
    return models.first { $0.model.id == selectedModelID }
  }

  var body: some View {
    VStack(spacing: 14) {
      ConnectionSurface {
        VStack(alignment: .leading, spacing: 8) {
          Text("Connection Name")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondaryForegroundColor)
          TextField("Personal", text: $connectionName)
            .font(.system(size: 16))
        }
      }

      ConnectionSurface {
        VStack(alignment: .leading, spacing: 10) {
          Text("Default Model")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondaryForegroundColor)
          if models.isEmpty {
            TextField("Model ID", text: $manualModelID)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Text("No models were discovered. Enter a model ID manually.")
              .font(.caption)
              .foregroundStyle(theme.secondaryForegroundColor)
          } else {
            NavigationLink {
              ConnectionSetupModelPickerView(
                models: models,
                selection: $selectedModelID
              )
            } label: {
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(selectedModel?.model.displayName ?? "Choose a model")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.primaryForegroundColor)
                    .lineLimit(2)
                  if let selectedModel {
                    Text(selectedModel.model.id.rawValue)
                      .font(.caption.monospaced())
                      .foregroundStyle(theme.secondaryForegroundColor)
                      .lineLimit(1)
                  } else {
                    Text("\(models.count) models available")
                      .font(.caption)
                      .foregroundStyle(theme.secondaryForegroundColor)
                  }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }
}

private struct ConnectionSetupModelPickerView: View {
  let models: [AccountModelRecord]
  @Binding var selection: ModelID?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.appFoundationTheme) private var theme
  @State private var searchText = ""

  private var records: [AccountModelRecord] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return models }
    return models.filter { record in
      record.model.displayName.localizedCaseInsensitiveContains(query)
        || record.model.id.rawValue.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    List {
      if records.isEmpty {
        ContentUnavailableView.search(text: searchText)
          .listRowBackground(Color.clear)
      } else {
        ForEach(records) { record in
          Button {
            selection = record.model.id
            dismiss()
          } label: {
            HStack(alignment: .top, spacing: 10) {
              VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                  Text(record.model.displayName)
                    .font(.headline)
                    .foregroundStyle(theme.primaryForegroundColor)
                  if record.model.id == selection {
                    Image(systemName: "checkmark")
                      .foregroundStyle(.tint)
                  }
                }
                Text(record.model.id.rawValue)
                  .font(.caption.monospaced())
                  .foregroundStyle(theme.secondaryForegroundColor)
                  .lineLimit(2)

                HStack(spacing: 8) {
                  if let context = record.model.contextWindow {
                    Text("\(context.formatted(.number.notation(.compactName))) ctx")
                  }
                  if record.model.inputModalities.contains("image") {
                    Label("Vision", systemImage: "photo")
                  }
                  if record.model.inputModalities.contains("file") {
                    Label("Files", systemImage: "doc")
                  }
                }
                .font(.caption2)
                .foregroundStyle(theme.secondaryForegroundColor)
              }
              Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        .listRowBackground(theme.surfaceColor)
      }
    }
    .scrollContentBackground(.hidden)
    .foregroundStyle(theme.primaryForegroundColor)
    .background(AppThemeBackground(theme: theme))
    .navigationTitle("Choose Model")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $searchText, prompt: "Search models")
  }
}

struct ConnectionStepHeader: View {
  let definition: ProviderDefinition?
  let icon: String?
  let title: String
  let subtitle: String

  init(definition: ProviderDefinition?, title: String, subtitle: String) {
    self.definition = definition
    self.icon = nil
    self.title = title
    self.subtitle = subtitle
  }

  init(icon: String, title: String, subtitle: String) {
    self.definition = nil
    self.icon = icon
    self.title = title
    self.subtitle = subtitle
  }

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    VStack(spacing: 12) {
      if let definition {
        ConnectionProviderMark(definition: definition, size: 54)
      } else if let icon {
        Image(systemName: icon)
          .font(.system(size: 28, weight: .medium))
          .frame(width: 54, height: 54)
          .background(theme.elevatedSurfaceColor, in: RoundedRectangle(cornerRadius: 16))
          .overlay {
            RoundedRectangle(cornerRadius: 16)
              .stroke(theme.borderColor, lineWidth: 1)
          }
      }
      Text(title)
        .font(.system(size: 28, weight: .semibold))
        .multilineTextAlignment(.center)
      Text(subtitle)
        .font(.system(size: 15))
        .foregroundStyle(theme.secondaryForegroundColor)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
    }
  }
}

struct ConnectionProgressView: View {
  let current: Int
  let count: Int

  var body: some View {
    HStack(spacing: 7) {
      ForEach(0..<count, id: \.self) { index in
        Capsule()
          .fill(index <= current ? Color.primary.opacity(index == current ? 0.7 : 0.28) : Color.primary.opacity(0.12))
          .frame(width: index == current ? 24 : 8, height: 6)
      }
    }
    .animation(.snappy, value: current)
    .accessibilityLabel("Step \(current + 1) of \(count)")
  }
}

struct ConnectionProviderMark: View {
  let definition: ProviderDefinition?
  let size: CGFloat

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    Image(systemName: providerSymbol(definition?.id))
      .font(.system(size: size * 0.42, weight: .semibold))
      .frame(width: size, height: size)
      .background(
        theme.elevatedSurfaceColor,
        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
          .stroke(theme.borderColor, lineWidth: 1)
      }
  }
}

struct ConnectionSurface<Content: View>: View {
  let content: Content

  @Environment(\.appFoundationTheme) private var theme

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(theme.borderColor, lineWidth: 1)
    }
  }
}

struct ConnectionDetailButton: View {
  let title: String
  let value: String
  let systemImage: String
  let action: () -> Void

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .frame(width: 24)
          .foregroundStyle(theme.secondaryForegroundColor)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.system(size: 15, weight: .medium))
          Text(value)
            .font(.caption)
            .foregroundStyle(theme.secondaryForegroundColor)
            .lineLimit(1)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct ConnectionActionLabel: View {
  let title: String
  let systemImage: String

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .frame(width: 24)
        .foregroundStyle(theme.secondaryForegroundColor)
      Text(title)
        .font(.system(size: 15, weight: .medium))
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(theme.secondaryForegroundColor.opacity(0.72))
    }
    .contentShape(Rectangle())
  }
}

struct ConnectionStatus {
  let label: String
  let isReady: Bool
}

@MainActor
func connectionStatus(model: ProviderManagementModel, account: ProviderAccount) -> ConnectionStatus {
  guard account.isEnabled else { return .init(label: "Disabled", isReady: false) }
  if let provider = model.provider(for: account.providerID),
    connectionRequiresCredential(provider),
    !model.credentialAccountIDs.contains(account.id)
  {
    return .init(label: "Needs API key", isReady: false)
  }
  let availableModels = model.models(for: account.id).filter(\.isAvailable)
  if availableModels.isEmpty {
    return .init(label: "Needs model", isReady: false)
  }
  return .init(label: "Ready", isReady: true)
}

func connectionRequiresCredential(_ provider: ProviderDefinition) -> Bool {
  switch provider.authentication {
  case .none: false
  case .bearer, .header: true
  }
}

func providerDescription(_ provider: ProviderDefinition) -> String {
  switch provider.id {
  case BuiltInProviders.openAIID: "GPT models directly from OpenAI"
  case BuiltInProviders.anthropicID: "Claude models directly from Anthropic"
  case BuiltInProviders.geminiID: "Google Gemini models"
  case BuiltInProviders.openRouterID: "Models from many AI providers"
  case BuiltInProviders.deepSeekID: "DeepSeek models directly"
  case BuiltInProviders.nvidiaID: "NVIDIA-hosted AI models"
  default: provider.isBuiltIn ? "Connect directly to this AI provider" : "OpenAI-compatible custom provider"
  }
}

func credentialSubtitle(_ provider: ProviderDefinition) -> String {
  connectionRequiresCredential(provider)
    ? "Use your own \(provider.displayName) API key. BYOKchat stores it securely in Keychain."
    : "This provider does not require an API key. Review the endpoint, then continue."
}

func providerSymbol(_ providerID: ProviderID?) -> String {
  switch providerID {
  case BuiltInProviders.openAIID: "circle.hexagongrid.fill"
  case BuiltInProviders.anthropicID: "a.circle.fill"
  case BuiltInProviders.geminiID: "sparkles"
  case BuiltInProviders.openRouterID: "arrow.triangle.branch"
  case BuiltInProviders.deepSeekID: "wave.3.right.circle.fill"
  case BuiltInProviders.nvidiaID: "cpu.fill"
  case .some(_): "server.rack"
  case .none: "sparkles"
  }
}

@MainActor
func modelDisplayName(
  model: ProviderManagementModel,
  accountID: ProviderAccountID?,
  modelID: ModelID
) -> String {
  guard let accountID else { return modelID.rawValue }
  return model.models(for: accountID, includeHidden: true)
    .first(where: { $0.model.id == modelID })?.model.displayName ?? modelID.rawValue
}

func parseHeaders(_ text: String) -> [String: String] {
  var values: [String: String] = [:]
  for line in text.split(whereSeparator: \.isNewline) {
    guard let colon = line.firstIndex(of: ":") else { continue }
    let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty, !value.isEmpty { values[name] = value }
  }
  return values
}

func serializeHeaders(_ headers: [String: String]) -> String {
  headers.keys.sorted().map { "\($0): \(headers[$0]!)" }.joined(separator: "\n")
}
