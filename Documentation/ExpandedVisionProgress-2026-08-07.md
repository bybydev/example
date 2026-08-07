# BYOKchat Expanded Vision Progress Review

**Review date:** 2026-08-07  
**Baseline branch:** `develop`  
**Baseline head:** `f704b3c298cb7ac57c0df31cb78b1c8566033580`  
**Updated on PR #2:** multimodal attachments, streaming/UI stabilization, native Anthropic/Gemini APIs, generic tool calling, and the complete scoped MCP v1 roadmap

## Executive summary

BYOKchat is already well beyond a prototype. The PR branch now has a substantial provider platform, conversation runtime, streaming pipeline, local persistence, credential isolation, search, context management, recovery flows, import/export, multimodal attachments, three provider API families, provider-neutral multi-step tool orchestration, real remote MCP connectivity, and a conversation-scoped MCP permission/interaction layer.

Against the expanded product vision, the PR branch is approximately:

| Area | Progress |
|---|---:|
| Core chat | ~90–95% |
| BYOK/provider layer | ~95% |
| Scoped MCP v1 roadmap (Phases 1–3) | ~100% |
| Remote MCP server connectivity | Implemented |
| MCP per-chat safety/UI | Implemented |
| Power-user layer | ~30% |
| Whole expanded vision | ~55% |

The important MCP gap is no longer basic protocol connectivity or authorization UX. BYOKchat can now select remote MCP servers per conversation, expose only the allowed tool catalog to that chat's model, require approval before Ask-policy calls, persist Always-Allow choices per chat/tool, render tool activity/results, and fulfill supported MCP `2026-07-28` multi-round elicitation.

A useful framing is that BYOKchat is roughly **90%+ of the way toward a serious multimodal BYOK AI chat client** and now has a complete first MCP product slice rather than only MCP infrastructure.

---

## 1. Core chat — ~90–95%

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

Remaining attachment polish includes richer PDF/document previews, separate blob storage/deduplication, provider-specific upload/file-ID APIs where useful, drag/drop and paste intake, and attachment metadata in Markdown export.

### Conversations / projects — Partial

Conversation support is mature: persistent local chats, per-chat provider/model settings, drafts, edit/resend, regenerate, cancellation, interrupted-generation repair, Markdown, reasoning display, copy/share/export, attachments, stable stream following, and per-chat MCP tool configuration.

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

Provider credentials are isolated from normal provider configuration and stored in Keychain. Remote MCP credentials use a separate Keychain vault with the same no-secret-export principle.

### Usage / cost visibility — Partial

Provider usage is normalized into input/output/cached/reasoning tokens where available. Tool-driven assistant turns accumulate usage across every model step in the logical turn.

Still missing is a complete user-facing cost layer: per-message calculated cost, chat totals, time-period totals, provider/model breakdown, and budgets.

---

## 3. Scoped MCP v1 — Phases 1–3 complete

BYOKchat's intentionally scoped MCP v1 consists of three phases, all implemented on PR #2.

### Phase 1 — Generic tool-calling runtime — Done

Implemented:

- provider-neutral `ChatToolDefinition`
- normalized `ChatToolCall` and `ChatToolResult`
- actor-backed app-native `ToolRuntime`
- conversation-scoped `ChatConversationToolExecuting` boundary
- multi-step `model → tool → model` orchestration in `ChatRuntime`
- multiple tool calls in one model step
- handler errors returned to the model as structured error results
- hard 8-round model/tool recursion guard
- structured `ChatToolRound` persistence
- tool history reconstruction in `ChatContextBuilder`
- accumulated usage across tool-driven provider requests
- OpenAI-compatible native tool wire format
- Anthropic native tool wire format
- Gemini native function-calling wire format
- Anthropic signed-thinking continuation across tool turns
- Gemini thought-signature continuation across tool turns
- import validation for structured tool traces

### Phase 2 — Remote Streamable HTTP MCP — Done

Implemented:

- persisted remote MCP server configuration in Settings
- HTTPS endpoint validation
- enable/disable state
- none, bearer-token, and custom-header authentication
- dedicated MCP Keychain credential storage
- MCP `2026-07-28` stateless protocol path
- `server/discover` probing and per-request MCP metadata
- bounded modern discovery with legacy fallback
- compatibility with initialize-era Streamable HTTP revisions `2025-11-25`, `2025-06-18`, and `2025-03-26`
- legacy `Mcp-Session-Id` capture and one-time expired-session recovery
- JSON and request-scoped SSE responses
- strict JSON-RPC response-ID matching while ignoring unrelated SSE notifications/progress events
- `tools/list` pagination
- persisted TTL-aware tool catalog cache
- per-tool validation with warnings rather than whole-catalog failure
- deterministic provider-safe namespacing when servers expose the same tool name
- `tools/call` with structured result normalization
- modern `Mcp-Method` / `Mcp-Name` routing headers
- final `x-mcp-header` rules with string/integer/boolean `Mcp-Param-*` mirroring
- forced discovery refresh and one retry after a modern header/schema mismatch
- MCP server configuration/discovery cache included in full backups
- MCP secrets excluded from persistence/backups and cleared on replace restore

The deprecated pre-Streamable-HTTP HTTP+SSE transport is not implemented.

### Phase 3 — Per-chat tools, safety, and UI — Done

Implemented:

- per-chat enabled MCP server IDs
- individual tool policy: Ask / Always Allow / Disabled
- new tools default to Ask
- conversation-scoped tool catalogs instead of global MCP registration
- no cross-chat MCP tool leakage during simultaneous generation
- execution-time re-check of current server/tool policy
- Allow Once / Always Allow / Deny approval flows
- Always-Allow persistence before execution resumes
- human-readable server/tool/argument approval cards
- read-only/destructive annotation hints treated as untrusted UI hints
- live tool-request/running state in the transcript
- persisted expandable success/failure tool cards
- denial returned to the provider as a structured tool error result
- cancellation-aware approval/input waits
- MCP `2026-07-28` `resultType: input_required` handling
- embedded form-mode `elicitation/create`
- embedded URL-mode `elicitation/create`
- Accept / Decline / Cancel input results
- fresh JSON-RPC request IDs for retry rounds
- byte-exact opaque `requestState` echo
- request-state-only pacing
- bounded 10-round interactive loop
- advertised elicitation capabilities limited to form + URL
- sampling/roots deliberately not advertised or auto-fulfilled
- per-chat MCP policy in backup/restore
- conversation-ID remapping during restore so imported tool policy follows the restored chat
- restored attachments and structured tool rounds preserved by the same portability path

### Explicitly outside MCP v1

The current product scope intentionally defers:

- OAuth
- local stdio MCP servers
- spawning Node/Python MCP processes
- deprecated HTTP+SSE transport
- MCP Apps
- Tasks
- sampling
- roots
- broader advanced MCP extensions

---

## 4. Power-user layer — ~30%

### Projects/workspaces — Missing

No user-facing project/workspace abstraction currently groups chats, instructions, files, and tools.

### Reusable prompts — Early foundation

Global and per-conversation system prompts exist. A reusable prompt library and variables/presets are still missing.

### Agents — Stronger runtime foundation

There is no user-facing agent abstraction yet, but BYOKchat now has multi-step provider tool orchestration, real remote MCP tools, explicit user approval, and interactive MCP input. Those are major primitives a future agent layer can reuse.

### Artifacts — Missing

There is no first-class artifact model or editor/viewer.

### File access — Partial

Per-message images/files are implemented and persisted. Project-level file collections, searchable file indexes, and tool-accessible workspace files are not.

### Terminal/code tools on Mac — Missing

The current product remains iOS-only.

### Tool presets — Partial

Per-chat MCP server and tool policy now exists. Higher-level named tool presets shared across chats/projects are still missing.

### Model routing — Early foundation

OpenRouter-specific routing exists. A BYOKchat-owned router across arbitrary configured providers/models does not.

### Export/import/sync — Strong local portability

Export/import includes versioned backup, provider configuration, MCP server configuration/discovery cache, per-chat MCP policy, conversation data, attachment bytes, structured tool rounds, merge/replace restore, validation, and provider/MCP credentials excluded from backups.

Cross-device sync remains the major missing piece.

---

## What has already been achieved

The horizontal foundation now looks like:

`providers → API-family routing → credentials → models → streaming → reasoning → persistence → conversations → attachments → multimodal context → generic tool schemas → native provider tool calls → conversation tool policy → remote MCP transport → MCP discovery/cache → approval → MCP tool call → interactive input → tool result replay → recovery → import/export`

The architecture has a useful separation of responsibilities:

- provider adapters translate model-specific function-call wire formats
- `ChatRuntime` owns model/tool orchestration
- `ToolRuntime` owns app-native tools
- `MCPRemoteRuntime` owns MCP protocol, discovery, authentication, caching, and remote request execution
- `MCPConversationToolRuntime` owns conversation-specific MCP exposure, approval, and multi-round input
- the chat UI owns visible human approval and interaction cards

This avoids making MCP a second chat engine and avoids globally registering remote tools that should only exist in one conversation.

---

## Recommended next product milestones

The scoped MCP v1 roadmap is complete. The highest-leverage next product milestones are now outside that original three-phase MCP slice:

1. **Projects/workspaces**  
   Group chats, instructions, files, and MCP tool presets into persistent work contexts.

2. **macOS target**  
   Reuse the provider/tool/MCP core and add desktop-native workflows, eventually including local process tools if desired.

3. **Usage/cost visibility**  
   Turn existing normalized usage into per-message/chat/model spend and budgets.

4. **Artifacts / higher-level agents**  
   Build on the now-complete tool execution and approval primitives.

5. **Multimodal/file storage polish**  
   Separate attachment blob storage, richer document previews, paste/drop intake, and provider-native file reuse.

---

## Bottom line

BYOKchat on this PR is best described as:

> **A mature multimodal, multi-provider BYOK chat foundation with a complete first MCP product slice: remote servers, conversation-scoped tools, explicit approvals, persisted tool activity, and interactive multi-round MCP input.**

The next major gains now come from product organization and desktop/power-user workflows rather than basic MCP plumbing.
