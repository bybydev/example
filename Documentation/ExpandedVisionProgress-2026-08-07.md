# BYOKchat Expanded Vision Progress Review

**Review date:** 2026-08-07  
**Baseline branch:** `develop`  
**Baseline head:** `f704b3c298cb7ac57c0df31cb78b1c8566033580`  
**Updated on PR #2:** multimodal attachments, streaming/UI stabilization, native Anthropic/Gemini APIs, Phase 1 generic tool calling, and Phase 2 remote Streamable HTTP MCP

## Executive summary

BYOKchat is already well beyond a prototype. The codebase now has a substantial provider platform, conversation runtime, streaming pipeline, local persistence, credential isolation, search, context management, recovery flows, import/export, multimodal attachments, three provider API families, a provider-neutral multi-step tool runtime, and a remote MCP transport/discovery layer.

Against the expanded product vision, the PR branch is approximately:

| Area | Progress |
|---|---:|
| Core chat | ~90% |
| BYOK/provider layer | ~95% |
| MCP v1 roadmap (Phases 1–3) | ~70% |
| Remote MCP server connectivity | Implemented |
| Power-user layer | ~20–25% |
| Whole expanded vision | ~50% |

The important remaining MCP gap is no longer protocol connectivity. Phase 2 can configure remote servers, negotiate modern or legacy Streamable HTTP behavior, discover/cache tools, and call them through the MCP core. What remains is Phase 3's user-control layer: per-chat selection, permissions, approvals, and tool-call UI before those remote tools are exposed to model-driven chat execution.

A useful framing is that BYOKchat is roughly **90% of the way toward a serious multimodal BYOK AI chat client** and now has both the generic tool engine and remote MCP transport needed for the next step into a controlled MCP-enabled workbench.

---

## 1. Core chat — ~90%

### Multiple providers — Done

Current first-class providers include:

- DeepSeek
- OpenRouter
- NVIDIA
- Anthropic
- Gemini
- user-defined OpenAI-compatible providers
- private-network OpenAI-compatible servers

The provider architecture supports multiple accounts per provider, model discovery, seed models, manual models, custom endpoints, headers, and different authentication modes.

### Model switching — Done

Provider account and model selection are first-class conversation settings. Conversations persist their provider, account, model, system prompt, and generation options.

### Image / vision / files — Implemented on PR #2

Current support includes:

- image selection from the photo library
- file selection from the system document picker
- multiple attachments per message
- attachment-only user messages
- image thumbnails and file cards in the composer
- persisted attachment previews in conversation history
- attachment filename search
- image normalization to JPEG for provider compatibility
- attachment persistence across relaunch, regeneration, and backup/restore
- OpenAI-compatible `image_url` and file content parts
- Anthropic native image/PDF content blocks
- Gemini native `inlineData` multimodal parts
- UTF-8 text-like file inlining
- context budgeting that includes attachment-bearing turns

Current safety limits are 8 attachments per message, 20 MiB per attachment, and 40 MiB total per message.

Remaining attachment polish includes richer PDF/document preview, separate blob storage/deduplication, provider-specific upload/file-ID APIs where useful, drag/drop and paste intake, and attachment metadata in Markdown export.

### Conversations / projects — Partial

Conversation support is mature: persistent local chats, per-chat provider/model settings, drafts, edit/resend, regenerate, cancellation, interrupted-generation repair, Markdown, reasoning display, copy/share/export, attachments, and stable stream following.

Projects/workspaces in the user-facing ChatGPT/Claude sense are not implemented yet.

### Search / context management — Done

Search covers conversation titles, user messages, assistant messages, and attachment filenames.

Context building includes token estimation, context-window budgeting, omission of older whole turns, attachment-aware selection, structured tool-round reconstruction, and disclosure when earlier messages were omitted.

### Local models — Mostly done for local servers

BYOKchat supports OpenAI-compatible providers reachable on localhost or the private network, including Ollama- and LM Studio-style servers.

Embedded on-device inference is separate and is not implemented.

---

## 2. BYOK/provider layer — ~95%

### OpenRouter — Done

OpenRouter is a built-in provider with model discovery, multimodal requests, provider-routing options, and OpenAI-compatible function/tool calling.

### OpenAI-compatible APIs — Done

OpenAI-compatible Chat Completions remains the flexible custom-provider family and supports custom endpoints, authentication strategies, custom headers, model discovery, streaming, reasoning normalization, multimodal content, function declarations, streamed tool-call reconstruction, and tool-result replay.

### Anthropic / Gemini / DeepSeek — Done

All three are first-class provider paths.

DeepSeek keeps its specialized OpenAI-compatible behavior and participates in the generic tool runtime through function calling.

Anthropic uses the native Messages API with system mapping, image/PDF blocks, SSE streaming, adaptive-thinking summaries, native tool declarations, `tool_use`/`tool_result`, streamed input JSON reconstruction, and signed-thinking continuation for tool turns.

Gemini uses native GenerateContent with `systemInstruction`, `inlineData`, thought summaries, usage normalization, `functionDeclarations`, `functionCall`/`functionResponse`, and thought-signature continuation for Gemini tool turns.

`ProviderAPIFamily` includes:

- `openAIChatCompletions`
- `anthropicMessages`
- `geminiGenerateContent`

Provider runtime selection remains API-family based, so conversation/tool orchestration stays provider-neutral.

### Custom endpoints — Done

Custom endpoint support includes HTTPS custom providers, explicit private-LAN HTTP, bearer/named-header/no-auth strategies, additional headers, model discovery, and manual models.

### Keychain credential management — Done

Provider credentials are isolated from normal provider configuration and stored in Keychain. Remote MCP credentials now use a separate Keychain vault with the same no-secret-export principle.

### Usage / cost visibility — Partial

Provider usage is normalized into input/output/cached/reasoning tokens where available. Tool-driven assistant turns accumulate usage across every model step in the logical turn.

Still missing is a complete user-facing cost layer: per-message calculated cost, chat totals, time-period totals, provider/model breakdown, and budgets.

---

## 3. MCP v1 — Phases 1–2 complete, Phase 3 remaining

BYOKchat's intentionally scoped MCP v1 consists of three phases.

### Phase 1 — Generic tool-calling runtime — Done on PR #2

Implemented:

- provider-neutral `ChatToolDefinition`
- normalized `ChatToolCall` and `ChatToolResult`
- actor-backed `ToolRuntime` registry/execution
- multi-step `model → tool → model` orchestration in `ChatRuntime`
- multiple tool calls in one model step
- handler errors returned to the model as structured error results
- hard 8-round recursion guard
- structured `ChatToolRound` persistence
- tool history reconstruction in `ChatContextBuilder`
- accumulated usage across tool-driven provider requests
- OpenAI-compatible native tool wire format
- Anthropic native tool wire format
- Gemini native function-calling wire format
- Anthropic signed-thinking continuation across tool turns
- Gemini thought-signature continuation across tool turns
- import validation for structured tool traces
- regression coverage for provider formats and the two-pass orchestration loop

### Phase 2 — Remote Streamable HTTP MCP — Done on PR #2

Implemented:

- persisted remote MCP server configuration in Settings
- HTTPS endpoint validation
- enable/disable state
- none, bearer-token, and custom-header authentication
- dedicated MCP Keychain credential storage
- current MCP `2026-07-28` stateless protocol path
- `server/discover` probing and per-request MCP metadata
- compatibility fallback to initialize-era Streamable HTTP revisions `2025-11-25`, `2025-06-18`, and `2025-03-26`
- legacy `Mcp-Session-Id` capture and one-time expired-session recovery
- JSON and request-scoped SSE responses
- strict JSON-RPC response-ID matching while ignoring unrelated SSE notifications/progress events
- `tools/list` pagination
- persisted TTL-aware tool catalog cache
- conservative cache-scope aggregation across pages
- per-tool validation with warnings rather than whole-catalog failure
- deterministic provider-safe namespacing when servers expose the same tool name
- `tools/call` with structured result normalization
- modern `Mcp-Method` / `Mcp-Name` routing headers
- `x-mcp-header` validation and `Mcp-Param-*` argument mirroring
- forced discovery refresh and one retry after a modern header/schema mismatch
- explicit handling of interactive `input_required` as a deferred Phase 3 interaction
- MCP server configuration/discovery cache included in full backups
- MCP secrets excluded from persistence/backups and cleared on replace restore
- regression coverage for modern transport, legacy fallback, request-scoped SSE, header annotations, namespacing, workspace import, and backup compatibility

The Phase 2 core can call an MCP tool directly, but discovered MCP tools are **not registered into chat's shared `ToolRuntime` yet**. That is deliberate: remote model-driven execution remains blocked until Phase 3 has explicit user permission and approval behavior.

The deprecated pre-Streamable-HTTP HTTP+SSE transport is not implemented.

### Phase 3 — Per-chat tools, safety, and UI — Not started

Planned scope:

- enable servers/tools per chat
- individual tool toggles
- Ask / Always Allow / Disabled permission policy
- Allow Once / Always Allow / Deny approvals
- human-readable tool arguments before mutation approval
- persisted permission choices
- controlled registration/removal of approved MCP tools in the shared `ToolRuntime`
- inline running/success/failure tool cards
- collapsed tool results
- retry/recovery UX
- safe handling of interactive `input_required` results where appropriate

### Explicitly outside MCP v1

The current product scope intentionally defers:

- OAuth
- local stdio MCP servers
- spawning Node/Python MCP processes
- deprecated HTTP+SSE transport
- MCP Apps
- Tasks and advanced MCP extensions

---

## 4. Power-user layer — ~20–25%

### Projects/workspaces — Missing

No user-facing project/workspace abstraction currently groups chats, instructions, files, and tools.

### Reusable prompts — Early foundation

Global and per-conversation system prompts exist. A reusable prompt library and variables/presets are still missing.

### Agents — Early runtime foundation

There is no user-facing agent abstraction, but the multi-step tool orchestration loop and remote MCP runtime provide key primitives that future agents would reuse.

### Artifacts — Missing

There is no first-class artifact model or editor/viewer.

### File access — Partial

Per-message images/files are implemented and persisted. Project-level file collections, searchable file indexes, and tool-accessible workspace files are not.

### Terminal/code tools on Mac — Missing

The current product remains iOS-only.

### Tool presets — Foundation advancing

The generic tool registry and remote MCP discovery layer exist. User-facing tool presets still depend on Phase 3 per-chat selection and permission state.

### Model routing — Early foundation

OpenRouter-specific routing exists. A BYOKchat-owned router across arbitrary configured providers/models does not.

### Export/import/sync — Partial to strong

Export/import includes versioned backup, provider configuration, MCP server configuration/discovery cache, conversation data, attachment bytes, structured tool rounds, merge/replace restore, validation, and provider/MCP credentials excluded from backups.

Cross-device sync remains the major missing piece.

---

## What has already been achieved

The horizontal foundation now looks like:

`providers → API-family routing → credentials → models → streaming → reasoning → persistence → conversations → attachments → multimodal context → generic tool schemas → native provider tool calls → tool execution → remote MCP transport → MCP discovery/cache → MCP tool calls → recovery → import/export`

The architecture now has a useful separation of responsibilities:

- provider adapters translate model-specific function-call wire formats
- `ChatRuntime` owns model/tool orchestration
- `ToolRuntime` owns normalized executable tools
- `MCPRemoteRuntime` owns MCP protocol, discovery, authentication, caching, and remote execution
- Phase 3 will own user policy deciding which MCP bindings become available to a conversation

This avoids making the MCP client itself a second chat engine or letting protocol transport implicitly bypass user approval.

---

## Recommended next product milestones

Within the current MCP v1 scope, the immediate next milestone is:

1. **Phase 3 — Per-chat tools + safety/UI**  
   Add server/tool selection, permissions, approvals, controlled ToolRuntime registration, interactive tool states, and first-class tool-call rendering.

After MCP v1, the next larger product decisions can be projects/workspaces, macOS, cost visibility, and higher-level agents/artifacts.

---

## Bottom line

BYOKchat on this PR is best described as:

> **A mature multimodal, multi-provider BYOK chat foundation with a provider-neutral tool engine and real remote MCP connectivity, but with remote model-driven tool execution intentionally gated until the Phase 3 permission/UI layer exists.**

Phase 1 removed provider coupling from tool execution. Phase 2 now speaks remote MCP and manages real remote tool catalogs. Phase 3 is the product layer that makes those capabilities safely usable inside everyday chats.
