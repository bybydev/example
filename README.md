# BYOKchat

BYOKchat is an iOS-only, BYOK-only AI chat client under active development.

BYOKchat owns its provider, conversation, and tool runtime. It does not use AppFoundation's AI provider management.

## First-class providers

- DeepSeek
- OpenRouter
- NVIDIA
- Anthropic
- Gemini
- User-defined OpenAI-compatible providers
- Private-network OpenAI-compatible servers

## Provider platform

- Native OpenAI-compatible Chat Completions, Anthropic Messages, and Gemini GenerateContent API families
- Multiple accounts per provider
- Keychain-isolated credentials
- Custom HTTPS endpoints and protected headers
- Explicit private-LAN HTTP support without global arbitrary loads
- Bearer, named-header, and no-auth configuration
- Model discovery and curated seed models
- Manual, favorite, hidden, and unavailable model states
- Searchable, favorites-first model selection
- Provider-native streaming with separate answer and reasoning/thought summaries where supported
- Provider-neutral function/tool calling across OpenAI-compatible, Anthropic, and Gemini wire formats
- Persisted multi-step model → tool → model execution rounds
- Anthropic thinking-signature and Gemini thought-signature continuity for tool turns
- Non-secret provider configuration import/export
- Connection testing and streaming console

## Native chat experience

- Multiple persistent local conversations
- Per-chat provider account, model, system prompt, and generation options
- Global default system prompt for new chats
- Multi-turn streaming with separate answer and reasoning content
- Image and file attachments from Photos and the system document picker
- Provider-native multimodal image/file payloads for OpenAI-compatible, Anthropic, and Gemini APIs
- Text-file context and binary file content for supporting providers
- Persisted attachment previews in conversation history
- Attachment-only messages and attachment filename search
- Fenced code-block rendering, horizontal scrolling, and code copy
- Message copy, share, and Markdown export
- Edit and resend with explicit linear-history truncation
- Regenerate without duplicating the user turn
- Confirmation before regenerating an uncertain billable request
- Search across titles, user messages, assistant messages, and attachment filenames
- Per-conversation draft persistence
- Context budgeting with whole-turn omission
- Partial-output persistence and immediate background flush
- Explicit cancellation with no automatic retry
- Relaunch repair of interrupted generations
- Missing-account, credential, and model recovery guidance
- Near-bottom stream following and Jump to Latest behavior

## Tool runtime

Phase 1 of the MCP roadmap is implemented as a generic tool layer beneath chat.

- `ToolRuntime` registers normalized tool definitions and async handlers.
- `ChatRuntime` can execute multiple model/tool rounds before producing the final assistant answer.
- Tool calls, tool results, provider continuation metadata, and per-step usage are persisted structurally.
- Tool-handler failures are returned to the model as error results instead of automatically aborting the chat turn.
- A hard eight-round limit prevents unbounded recursive tool loops.
- No production tools or MCP servers are registered yet; remote MCP is Phase 2 and per-chat permissions/tool UI are Phase 3.

## Data portability

- Versioned full backup containing conversations, attachments, structured tool rounds, preferences, and non-secret provider configuration
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
- `Documentation/MultimodalAttachments.md`
- `Documentation/NativeProviderAPIs.md`
- `Documentation/ToolCallingRuntime.md`
- `Documentation/ExpandedVisionProgress-2026-08-07.md`
