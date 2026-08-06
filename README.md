# BYOKchat

BYOKchat is an iOS-only, BYOK-only AI chat client under active development.

## Current status

Phase 2 establishes a persistent provider workspace and a native provider-management experience around the independent provider core.

### First-class providers

- DeepSeek
- OpenRouter
- NVIDIA
- User-defined OpenAI-compatible providers

### Provider core

- OpenAI-compatible one-shot generation and SSE streaming
- Visible answer and reasoning separation
- Usage, finish reason, and provider metadata normalization
- Cancellation and mid-stream provider errors
- DeepSeek thinking controls
- OpenRouter reasoning and routing controls
- Model discovery with curated seed fallbacks
- Stable provider, account, and model IDs
- Bearer, named-header, and no-auth providers
- Protected custom headers and HTTPS endpoint validation

### Provider workspace

- Multiple accounts per provider
- API credentials stored separately in Keychain
- Versioned non-secret JSON workspace
- Custom providers
- Endpoint overrides and safe custom headers
- Provider defaults and per-account default models
- Model discovery, manual models, favorites, hidden models, and availability tracking
- Configuration export/import without credentials
- Complete credential cleanup when an account is deleted

### iOS app

- Providers and configured accounts browser
- Account setup and editing
- Secure credential replacement
- OpenRouter metadata fields
- Model refresh, favorites, manual models, and default selection
- Custom OpenAI-compatible provider creator
- Persistent-account streaming console

## Local validation

```sh
swift test
swift build -c release
```

On macOS with XcodeGen installed:

```sh
xcodegen generate
open BYOKchat.xcodeproj
```

Live provider tests require your own DeepSeek, OpenRouter, or NVIDIA API key. No credentials are committed or exported.

## Architecture boundary

BYOKchat owns its complete AI provider platform. It does not use AppFoundation's AI provider manager. AppFoundation may later be used only for approved non-AI UI infrastructure.
