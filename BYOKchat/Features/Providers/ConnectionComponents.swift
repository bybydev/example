import AppFoundation
import BYOKchatProviderCore
import SwiftUI

/// Provider identity mark: brand asset when the kind has one, monogram tile
/// otherwise (`.openAICompatible` and unknown providers).
struct ConnectionProviderMark: View {
  let definition: ProviderDefinition?
  let size: CGFloat

  @Environment(\.appFoundationTheme) private var theme

  var body: some View {
    providerLogo
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(theme.primaryForegroundColor)
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

  @ViewBuilder
  private var providerLogo: some View {
    if let assetName = ProviderLogoCatalog.assetName(for: definition) {
      Image(assetName).resizable().scaledToFit()
        .padding(size * 0.2)
    } else {
      Text(String((definition?.displayName.first ?? "?")).uppercased())
        .foregroundStyle(theme.secondaryForegroundColor)
    }
  }
}

/// Brand marks available to supported providers and recognizable custom
/// OpenAI-compatible connections. Keeping this separate from `ProviderKind`
/// lets the asset library grow without claiming wire-level provider support.
enum ProviderLogoCatalog {
  struct Entry: Sendable {
    let assetName: String
    let aliases: [String]
    let hostSuffixes: [String]

    init(_ asset: String, aliases: [String], hosts: [String] = []) {
      assetName = "provider.\(asset)"
      self.aliases = aliases
      hostSuffixes = hosts
    }
  }

  static let entries: [Entry] = [
    .init("openai", aliases: ["openai", "chatgpt"], hosts: ["api.openai.com"]),
    .init("anthropic", aliases: ["anthropic", "claude"], hosts: ["api.anthropic.com"]),
    .init(
      "gemini", aliases: ["gemini", "google-ai", "google-ai-studio"],
      hosts: ["generativelanguage.googleapis.com"]),
    .init("deepseek", aliases: ["deepseek"], hosts: ["api.deepseek.com"]),
    .init("openrouter", aliases: ["openrouter"], hosts: ["openrouter.ai"]),
    .init("nvidia", aliases: ["nvidia", "nvidia-nim", "nim"], hosts: ["api.nvidia.com"]),
    .init("xai", aliases: ["xai", "x-ai", "grok"], hosts: ["api.x.ai"]),
    .init("mistral", aliases: ["mistral", "mistral-ai"], hosts: ["api.mistral.ai"]),
    .init("cohere", aliases: ["cohere"], hosts: ["api.cohere.com"]),
    .init("ai21", aliases: ["ai21", "ai21-labs"], hosts: ["api.ai21.com"]),
    .init("groq", aliases: ["groq", "groqcloud"], hosts: ["api.groq.com"]),
    .init("together", aliases: ["together", "together-ai"], hosts: ["api.together.xyz"]),
    .init("fireworks", aliases: ["fireworks", "fireworks-ai"], hosts: ["api.fireworks.ai"]),
    .init("cerebras", aliases: ["cerebras"], hosts: ["api.cerebras.ai"]),
    .init("perplexity", aliases: ["perplexity", "pplx"], hosts: ["api.perplexity.ai"]),
    .init("deepinfra", aliases: ["deepinfra"], hosts: ["api.deepinfra.com"]),
    .init("baseten", aliases: ["baseten"], hosts: ["api.baseten.co"]),
    .init("replicate", aliases: ["replicate"], hosts: ["api.replicate.com"]),
    .init("sambanova", aliases: ["sambanova", "sambanova-cloud"], hosts: ["api.sambanova.ai"]),
    .init("hyperbolic", aliases: ["hyperbolic"], hosts: ["api.hyperbolic.xyz"]),
    .init("nebius", aliases: ["nebius", "nebius-ai"], hosts: ["api.tokenfactory.nebius.com"]),
    .init("fal", aliases: ["fal", "fal-ai"], hosts: ["fal.run"]),
    .init(
      "aws-bedrock", aliases: ["aws-bedrock", "amazon-bedrock", "bedrock"],
      hosts: []),
    .init(
      "azure-ai", aliases: ["azure-ai", "azure-openai", "microsoft-foundry", "azure-foundry"],
      hosts: ["openai.azure.com", "services.ai.azure.com"]),
    .init(
      "vertex-ai", aliases: ["vertex-ai", "google-vertex"],
      hosts: ["aiplatform.googleapis.com"]),
    .init(
      "cloudflare-workers-ai", aliases: ["cloudflare-workers-ai", "workers-ai"],
      hosts: []),
    .init(
      "huggingface", aliases: ["huggingface", "hugging-face"],
      hosts: ["api-inference.huggingface.co"]),
    .init("meta", aliases: ["meta", "meta-ai", "llama"]),
    .init("alibaba", aliases: ["alibaba", "alibaba-cloud"], hosts: ["dashscope.aliyuncs.com"]),
    .init("qwen", aliases: ["qwen", "tongyi-qianwen"]),
    .init(
      "moonshot", aliases: ["moonshot", "moonshot-ai", "kimi"],
      hosts: ["api.moonshot.ai", "api.moonshot.cn"]),
    .init("siliconflow", aliases: ["siliconflow", "silicon-cloud"], hosts: ["api.siliconflow.cn"]),
    .init("minimax", aliases: ["minimax"], hosts: ["api.minimax.io", "api.minimaxi.com"]),
    .init(
      "zai", aliases: ["zai", "z-ai", "zhipu", "chatglm", "glm"],
      hosts: ["api.z.ai", "open.bigmodel.cn"]),
    .init("ibm-watsonx", aliases: ["ibm-watsonx", "watsonx"], hosts: ["watsonx.ai"]),
    .init(
      "snowflake", aliases: ["snowflake", "snowflake-cortex"],
      hosts: ["snowflakecomputing.com"]),
    .init(
      "vercel-ai", aliases: ["vercel", "vercel-ai", "vercel-ai-gateway"],
      hosts: ["ai-gateway.vercel.sh"]),
    .init("ollama", aliases: ["ollama"]),
    .init("lmstudio", aliases: ["lm-studio", "lmstudio"]),
  ]

  static func assetName(for definition: ProviderDefinition?) -> String? {
    guard let definition else { return nil }

    if let kind = definition.kind, case .brand(let assetName) = kind.logo {
      return assetName
    }

    let identities = [definition.id.rawValue, definition.displayName].map(normalize)
    let host = definition.defaultBaseURL.host?.lowercased() ?? ""
    return entries.first { entry in
      entry.aliases.contains { alias in identities.contains { matches(alias: alias, in: $0) } }
        || entry.hostSuffixes.contains { suffix in
          host == suffix || host.hasSuffix(".\(suffix)")
        }
    }?.assetName
  }

  private static func normalize(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: "-")
      .lowercased()
  }

  private static func matches(alias: String, in identity: String) -> Bool {
    identity == alias
      || identity.hasPrefix("\(alias)-")
      || identity.hasSuffix("-\(alias)")
      || identity.contains("-\(alias)-")
  }
}

struct ConnectionStatus {
  let label: String
  let isReady: Bool
}

/// Status derivation for list rows and the picker account strip. Built on the
/// model's single readiness predicate.
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

/// One strict parser shared by every surface: one `Name: Value` per line.
struct HeaderParseError: LocalizedError {
  let line: Int
  var errorDescription: String? { "Header line \(line) must use Name: Value." }
}

func parseHeadersStrict(_ text: String) throws -> [String: String] {
  var values: [String: String] = [:]
  let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
  for (offset, rawLine) in lines.enumerated() {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { continue }
    guard let colon = line.firstIndex(of: ":") else {
      throw HeaderParseError(line: offset + 1)
    }
    let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !value.isEmpty else {
      throw HeaderParseError(line: offset + 1)
    }
    values[name] = value
  }
  return values
}

func serializeHeaders(_ headers: [String: String]) -> String {
  headers.keys.sorted().map { "\($0): \(headers[$0]!)" }.joined(separator: "\n")
}
