# BYOKchat

BYOKchat is an iOS-only, BYOK-only AI chat client under active development.

BYOKchat owns its provider, conversation, tool, and MCP runtime. It does not use AppFoundation's AI provider management.

## First-class providers

- OpenAI
- xAI
- DeepSeek
- OpenRouter
- NVIDIA
- Anthropic
- Gemini
- User-defined OpenAI-compatible providers
- Private-network OpenAI-compatible servers

## Provider platform

- Native OpenAI/xAI Responses, OpenAI-compatible Chat Completions, Anthropic Messages, and Gemini GenerateContent API families
- Multiple accounts per provider
- Keychain-isolated credentials
- Custom HTTPS endpoints and protected headers
- Explicit private-LAN HTTP support without global arbitrary loads
- Bearer, named-header, and no-auth configuration
- Model discovery and curated seed models
- Manual, favorite, hidden, and unavailable model states
- Searchable, favorites-first model selection
- Provider-native streaming with separate answer and reasoning/thought summaries where supported
- Provider-neutral function/tool calling across OpenAI/xAI Responses, OpenAI-compatible, Anthropic, and Gemini wire formats
- Persisted multi-step model → tool → model execution rounds
- OpenAI/xAI encrypted-reasoning/output continuation, Anthropic thinking-signature, and Gemini thought-signature continuity
- Non-secret provider configuration import/export
- Connection testing and streaming console

## Native chat experience

- Multiple persistent local conversations
- Per-chat provider account, model, system prompt, generation options, and MCP tool selection
- Global default system prompt for new chats
- Multi-turn streaming with separate answer and reasoning content
- Image and file attachments from Photos and the system document picker
- Provider-native multimodal image/file payloads for OpenAI/xAI Responses, OpenAI-compatible, Anthropic, and Gemini APIs
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

The generic tool layer beneath chat is provider-neutral and MCP-aware.

- `ToolRuntime` registers app-native normalized tool definitions and async handlers.
- `MCPConversationToolRuntime` adds chat-scoped remote MCP catalogs without globally leaking tools between conversations.
- `ChatRuntime` can execute multiple model/tool rounds before producing the final assistant answer.
- Tool calls, tool results, provider continuation metadata, and per-step usage are persisted structurally.
- Tool-handler failures and denied calls are returned to the model as structured error results instead of automatically aborting the chat turn.
- A hard eight-round model/tool limit prevents unbounded recursive tool loops.

## Remote MCP

The MCP v1 product surface is implemented.

### Remote servers and transport

- Settings-managed remote MCP servers with HTTPS validation.
- None, bearer-token, and custom-header authentication.
- MCP credentials stored in a dedicated Keychain vault.
- Current MCP `2026-07-28` stateless protocol support with `server/discover` and per-request metadata.
- Automatic compatibility fallback to initialize-era Streamable HTTP revisions `2025-11-25`, `2025-06-18`, and `2025-03-26`.
- JSON and request-scoped SSE responses with strict JSON-RPC response-ID matching.
- `tools/list` pagination, persisted TTL-aware discovery cache, and per-tool validation warnings.
- `tools/call` runtime with structured result normalization.
- Current `Mcp-Method`, `Mcp-Name`, and `x-mcp-header` / `Mcp-Param-*` routing behavior.
- Deterministic 64-character provider-compatible namespacing for MCP tools.

### Per-chat tools and safety

- Enable MCP servers independently for each conversation.
- Configure each discovered tool as **Ask**, **Always Allow**, or **Disabled**.
- Newly discovered tools default to **Ask** rather than inheriting blanket authorization.
- Approval cards show the server, tool, arguments, and read-only/destructive annotation hints before execution.
- **Allow Once**, **Always Allow**, and **Deny** decisions are supported.
- Always-Allow decisions persist per conversation/tool before the waiting call resumes.
- Execution re-checks the current conversation policy before every remote call, so disabling a tool while a generation is active still blocks execution.
- Live running/waiting cards appear in the transcript, and completed tool rounds persist as expandable success/failure cards.
- Tool annotations are treated as display hints only; authorization does not rely on them.

### MCP 2026 multi-round input

- `resultType: input_required` is handled without exposing the server request directly to the model.
- Form-mode and URL-mode `elicitation/create` input requests are surfaced as native chat cards.
- Accept, decline, and cancel responses are returned using MCP result objects.
- The original `tools/call` is retried with a fresh JSON-RPC request ID, `inputResponses`, and byte-exact opaque `requestState` echo.
- Request-state-only rounds are paced before retrying.
- Interactive tool execution is capped at 10 input-required rounds.
- BYOKchat advertises only the MCP client capabilities it currently handles: form and URL elicitation.

Explicitly deferred from MCP v1: OAuth, local stdio/process spawning, deprecated HTTP+SSE, MCP Apps, Tasks, sampling, roots, and other advanced extensions.

## Analytics and diagnostics

BYOKchat keeps durable usage accounting separate from disposable observability.

- Conversation `ChatBilling` metadata remains the source of truth for historical tokens, model requests, tool calls, pricing snapshots, and spend.
- A dedicated local SQLite telemetry store records privacy-safe timing, lifecycle, and reliability data.
- Analytics includes TTFT, request duration, generation speed, success rates, provider/model breakdowns, tool/MCP reliability, and stable error classifications.
- Settings → Diagnostics & Logs provides local event search/filtering, event details, sanitized export, recorder health, retention status, cleanup, and clear controls.
- Raw telemetry stays on the device and is never used as a backup or synchronized as a SQLite file.
- Telemetry is capped by age, event count, and database size and can be discarded/recreated if corrupt or incompatible.
- Telemetry storage failures fail open and never block chat, tools, purchases, project sync, or app launch.
- Prompts, responses, reasoning, credentials, tool arguments/results, attachment contents, URLs, and hostnames are excluded from telemetry by default.

## Data portability

- Versioned full backup containing conversations, attachments, structured tool rounds, preferences, non-secret provider configuration, MCP server configuration/discovery cache, and per-chat MCP tool policies
- Backward-compatible import of existing schema-v1 backups that predate MCP configuration and per-chat MCP policies
- Merge or replace restore strategies
- Conversation import preserves attachments and structured tool rounds
- Per-chat MCP policy is remapped when imported conversation IDs change
- Repeated keep-existing import is idempotent
- Pre-mutation validation and workspace rollback on import failure
- Provider and MCP credentials excluded from every export
- Replace restore clears affected provider and MCP Keychain credentials
- Delete-all credential controls include provider and MCP credentials

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
- `Documentation/RemoteMCP.md`
- `Documentation/TelemetryObservability.md`
- `Documentation/ExpandedVisionProgress-2026-08-07.md`
