# BYOKchat

BYOKchat is an iOS-only, BYOK-only AI chat client under active development.

BYOKchat owns its provider and conversation runtime. It does not use AppFoundation's AI provider management.

## First-class providers

- DeepSeek
- OpenRouter
- NVIDIA
- User-defined OpenAI-compatible providers
- Private-network OpenAI-compatible servers

## Provider platform

- Multiple accounts per provider
- Keychain-isolated credentials
- Custom HTTPS endpoints and protected headers
- Explicit private-LAN HTTP support without global arbitrary loads
- Bearer, named-header, and no-auth configuration
- Model discovery and curated seed models
- Manual, favorite, hidden, and unavailable model states
- Searchable, favorites-first model selection
- Non-secret provider configuration import/export
- Connection testing and streaming console

## Native chat experience

- Multiple persistent local conversations
- Per-chat provider account, model, system prompt, and generation options
- Global default system prompt for new chats
- Multi-turn streaming with separate answer and reasoning content
- Fenced code-block rendering, horizontal scrolling, and code copy
- Message copy, share, and Markdown export
- Edit and resend with explicit linear-history truncation
- Regenerate without duplicating the user turn
- Confirmation before regenerating an uncertain billable request
- Search across titles, user messages, and assistant messages
- Per-conversation draft persistence
- Context budgeting with whole-turn omission
- Partial-output persistence and immediate background flush
- Explicit cancellation with no automatic retry
- Relaunch repair of interrupted generations
- Missing-account, credential, and model recovery guidance
- Near-bottom stream following and Jump to Latest behavior

## Data portability

- Versioned full backup containing conversations, preferences, and non-secret provider configuration
- Merge or replace restore strategies
- Pre-mutation validation and workspace rollback on import failure
- Credentials excluded from every export
- Replace restore clears affected Keychain credentials
- Delete-all controls for conversations and credentials

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
- `Documentation/NativeChatExperience.md`
- `Documentation/DataPortability.md`
- `Documentation/LocalProviders.md`
