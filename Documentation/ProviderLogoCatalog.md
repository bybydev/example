# Provider Logo Catalog

BYOKchat bundles monochrome vector marks independently from its supported-provider catalog. A logo's presence means the app can recognize that brand visually; it does not claim native API compatibility.

## Included brands

- Built in: Anthropic, OpenAI, xAI, Gemini, DeepSeek, OpenRouter, NVIDIA
- Model labs: Mistral AI, Cohere, AI21 Labs, Meta, Alibaba, Qwen, Moonshot AI/Kimi, MiniMax, Z.ai/Zhipu
- Hosted inference: Groq, Together AI, Fireworks AI, Cerebras, Perplexity, DeepInfra, Baseten, Replicate, SambaNova, Hyperbolic, Nebius, fal.ai, SiliconFlow
- Cloud platforms: Amazon Bedrock, Azure AI, Vertex AI, Cloudflare Workers AI, Hugging Face, IBM watsonx, Snowflake Cortex, Vercel AI Gateway
- Local runtimes: Ollama, LM Studio

Custom OpenAI-compatible connections resolve a logo from their display name or a known API hostname. Unknown providers continue to use the monogram fallback.

## Asset convention

Each asset is named `provider.<canonical-id>` and stored as a template-rendered SVG with vector preservation enabled. Additions should include:

1. An entry in `scripts/import_provider_logos.sh`.
2. A matching entry and aliases in `ProviderLogoCatalog`.
3. A recognition test when a name or hostname needs special handling.

## Source and license

The marks were imported from `@lobehub/icons-static-svg` version 1.94.0, part of [Lobe Icons](https://github.com/lobehub/lobe-icons), and normalized from `currentColor` to black for Xcode template rendering. Lobe Icons is distributed under the MIT License; its required notice is preserved in `Documentation/LobeIcons-LICENSE.txt`.

The logos and brand names remain trademarks of their respective owners. They are used only to identify providers and services.
