import AppKit
import BYOKchatProviderCore
import SwiftUI

/// Provider identity mark for macOS: renders a template brand SVG from the
/// shared asset catalog tinted with the active theme color, falling back to a
/// monogram tile or `server.rack` for custom OpenAI-compatible connections.
struct MacProviderMark: View {
  private let assetName: String?
  private let monogram: String?
  private let fallbackSystemImage: String?
  let size: CGFloat
  let isReady: Bool

  init(definition: ProviderDefinition?, size: CGFloat, isReady: Bool = true) {
    self.assetName = MacProviderLogoCatalog.assetName(for: definition)
    self.monogram = definition?.displayName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .first
      .map { String($0).uppercased() }
    self.fallbackSystemImage = definition?.kind == .openAICompatible ? "server.rack" : nil
    self.size = size
    self.isReady = isReady
  }

  init(account: ProviderAccount, size: CGFloat, isReady: Bool = true) {
    self.init(definition: account.definition, size: size, isReady: isReady)
  }

  init(kind: ProviderKind, size: CGFloat, isReady: Bool = true) {
    self.assetName = MacProviderLogoCatalog.assetName(for: kind)
    self.monogram = nil
    self.fallbackSystemImage = kind == .openAICompatible ? "server.rack" : providerSymbol(kind)
    self.size = size
    self.isReady = isReady
  }

  private var foregroundTint: Color {
    isReady ? MacDesignTokens.Colors.accent : MacDesignTokens.Colors.textMuted
  }

  var body: some View {
    providerLogo
      .font(.system(size: size * 0.44, weight: .semibold))
      .foregroundStyle(foregroundTint)
      .frame(width: size, height: size)
      .background(
        foregroundTint.opacity(0.11),
        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
          .stroke(MacDesignTokens.Colors.separator.opacity(0.6), lineWidth: 0.5)
      }
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var providerLogo: some View {
    if let assetName, NSImage(named: assetName) != nil {
      Image(assetName)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .padding(size * 0.21)
    } else if let monogram, !monogram.isEmpty {
      Text(monogram)
    } else if let fallbackSystemImage {
      Image(systemName: fallbackSystemImage)
    } else {
      Text("?")
    }
  }
}

/// Brand marks available to supported providers and recognizable custom
/// OpenAI-compatible connections. Mirrors iOS `ProviderLogoCatalog`.
enum MacProviderLogoCatalog {
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
    .init(
      "mistral", aliases: ["mistral", "mistral-ai"],
      hosts: ["api.mistral.ai", "codestral.mistral.ai"]),
    .init("cohere", aliases: ["cohere"], hosts: ["api.cohere.com"]),
    .init("ai21", aliases: ["ai21", "ai21-labs"], hosts: ["api.ai21.com"]),
    .init("groq", aliases: ["groq", "groqcloud"], hosts: ["api.groq.com"]),
    .init(
      "together", aliases: ["together", "together-ai"],
      hosts: ["api.together.ai", "api.together.xyz"]),
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
    .init(
      "qwen", aliases: ["qwen", "alibaba-qwen", "tongyi-qianwen"],
      hosts: ["dashscope-intl.aliyuncs.com", "dashscope-us.aliyuncs.com"]),
    .init(
      "moonshot", aliases: ["moonshot", "moonshot-ai", "kimi"],
      hosts: ["api.moonshot.ai", "api.moonshot.cn"]),
    .init("siliconflow", aliases: ["siliconflow", "silicon-cloud"], hosts: ["api.siliconflow.cn"]),
    .init(
      "minimax", aliases: ["minimax", "minimax-ai"],
      hosts: ["api.minimax.io", "api.minimaxi.com", "api.minimax.chat"]),
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

  static func assetName(for kind: ProviderKind) -> String? {
    guard case .brand(let assetName) = kind.logo else { return nil }
    return assetName
  }

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

  static func searchAliases(for kind: ProviderKind) -> [String] {
    guard case .brand(let assetName) = kind.logo else { return [] }
    return entries.first { $0.assetName == assetName }?.aliases ?? []
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

extension ProviderKind {
  var macPickerTitle: String {
    self == .openAICompatible ? "Custom (OpenAI-Compatible)" : displayName
  }

  var macPickerDescription: String {
    switch self {
    case .openai: "GPT models"
    case .xAI: "Grok models"
    case .anthropic: "Claude models"
    case .gemini: "Gemini models"
    case .deepSeek: "DeepSeek models"
    case .zAI: "GLM models"
    case .moonshot: "Kimi models"
    case .minimax: "MiniMax models"
    case .qwen: "Qwen models"
    case .mistral: "Mistral models"
    case .groq: "Fast LPU inference"
    case .together: "Open-source hosted models"
    case .fireworks: "Fast hosted inference"
    case .openRouter: "Multi-provider routing"
    case .nvidia: "NVIDIA hosted models"
    case .ollama: "Local Ollama server"
    case .lmStudio: "Local LM Studio server"
    case .openAICompatible: "Any OpenAI-compatible API"
    }
  }

  func matchesMacProviderSearch(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    return displayName.localizedCaseInsensitiveContains(trimmed)
      || macPickerTitle.localizedCaseInsensitiveContains(trimmed)
      || macPickerDescription.localizedCaseInsensitiveContains(trimmed)
      || rawValue.localizedCaseInsensitiveContains(trimmed)
      || MacProviderLogoCatalog.searchAliases(for: self).contains {
        $0.localizedCaseInsensitiveContains(trimmed)
      }
  }
}
