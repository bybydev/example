# BYOKchat

BYOKchat is an iOS-only, BYOK-only AI chat client under active development.

## Current implementation

BYOKchat owns its provider and conversation runtime. It does not use AppFoundation's AI provider management.

### First-class providers

- DeepSeek
- OpenRouter
- NVIDIA
- User-defined OpenAI-compatible providers

### Provider platform

- Multiple accounts per provider
- Keychain-isolated credentials
- Custom HTTPS endpoints and safe headers
- Bearer, named-header, and no-auth configuration
- Model discovery and curated seed models
- Manual, favorite, hidden, and unavailable model states
- Non-secret provider configuration import/export
- Connection testing and streaming console

### Conversation runtime

- Multiple persistent conversations
- Local versioned conversation storage
- Per-chat provider account, model, system prompt, and generation options
- Multi-turn streaming
- Separate visible answer and reasoning content
- Context budgeting with whole-turn omission
- Partial-output persistence
- Explicit cancellation with no automatic retry
- Relaunch repair of interrupted generations
- Provider/account/model snapshots on every message
- Conversation create, rename, and delete
- Native Chats-first iOS interface

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

The app requires your own provider keys. No live credentials are committed.

## Documentation

- `IMPLEMENTATION_PLAN.md`
- `Documentation/ProviderCoreOrigin.md`
- `Documentation/ProviderWorkspace.md`
- `Documentation/ConversationRuntime.md`
