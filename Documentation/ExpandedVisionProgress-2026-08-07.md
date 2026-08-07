# BYOKchat Expanded Vision Progress Review

**Review date:** 2026-08-07  
**Baseline branch:** `develop`  
**Baseline head:** `f704b3c298cb7ac57c0df31cb78b1c8566033580`  
**Updated on PR #2:** multimodal attachments, streaming/UI stabilization, native Anthropic/Gemini APIs, and Phase 1 generic tool calling

## Executive summary

BYOKchat is already well beyond a prototype. The codebase has a substantial provider platform, conversation runtime, streaming pipeline, local persistence, credential isolation, search, context management, recovery flows, import/export support, multimodal attachments, three provider API families, and now a provider-neutral multi-step tool orchestration layer.

Against the expanded product vision, the PR branch is approximately:

| Area | Progress |
|---|---:|
| Core chat | ~90% |
| BYOK/provider layer | ~95% |
| MCP v1 roadmap (Phases 1–3) | ~30% |
| Actual MCP server connectivity | 0% |
| Power-user layer | ~20% |
| Whole expanded vision | ~45% |

The MCP distinction matters: Phase 1 provides the generic model/tool runtime that MCP will plug into, but BYOKchat does not yet initialize, discover, or call an MCP server. That begins in Phase 2.

A useful framing is that BYOKchat is now roughly **90% of the way toward a serious multimodal BYOK AI chat client** and has completed the foundational tool-calling work needed to become an MCP client without coupling MCP protocol details to provider adapters.

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

DeepSeek keeps its specialized OpenAI-compatible behavior and now participates in the generic tool runtime through function calling.

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

Credentials are isolated from normal provider configuration and stored in Keychain. They remain excluded from exports and backups.

### Usage / cost visibility — Partial

Provider usage is normalized into input/output/cached/reasoning tokens where available. Tool-driven assistant turns now accumulate usage across every model step in the logical turn.

Still missing is a complete user-facing cost layer: per-message calculated cost, chat totals, time-period totals, provider/model breakdown, and budgets.

---

## 3. MCP v1 — Phase 1 complete, Phases 2–3 remaining

BYOKchat's intentionally scoped MCP v1 consists of only three phases.

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

No production tools are registered yet. `AppModel` owns the shared runtime, ready for Phase 2 to populate it from MCP discovery.

### Phase 2 — Remote MCP — Not started

Planned scope:

- remote Streamable HTTP server configuration
- initialize / capability negotiation
- `tools/list`
- tool catalog caching
- `tools/call`
- connection testing
- bearer/custom-header authentication
- reliable transport and server error handling
- deterministic namespacing when different MCP servers expose the same tool name

Actual MCP protocol/server connectivity remains **0%** until this phase lands.

### Phase 3 — Per-chat tools, safety, and UI — Not started

Planned scope:

- enable servers/tools per chat
- individual tool toggles
- Ask / Always Allow / Disabled permission policy
- Allow once / Always allow / Deny approvals
- human-readable tool arguments before mutation approval
- persisted permission choices
- inline running/success/failure tool cards
- collapsed tool results
- retry/recovery UX

### Explicitly outside MCP v1

The current product scope intentionally defers:

- OAuth
- local stdio MCP servers
- spawning Node/Python MCP processes
- MCP Apps
- Tasks and advanced MCP extensions

---

## 4. Power-user layer — ~20%

### Projects/workspaces — Missing

No user-facing project/workspace abstraction currently groups chats, instructions, files, and tools.

### Reusable prompts — Early foundation

Global and per-conversation system prompts exist. A reusable prompt library and variables/presets are still missing.

### Agents — Early runtime foundation

There is no user-facing agent abstraction, but the new multi-step tool orchestration loop provides a key primitive that future agents would reuse.

### Artifacts — Missing

There is no first-class artifact model or editor/viewer.

### File access — Partial

Per-message images/files are implemented and persisted. Project-level file collections, searchable file indexes, and tool-accessible workspace files are not.

### Terminal/code tools on Mac — Missing

The current product remains iOS-only.

### Tool presets — Foundation only

The generic tool registry exists, but user-facing tool presets depend on MCP Phase 2 and per-chat selection in Phase 3.

### Model routing — Early foundation

OpenRouter-specific routing exists. A BYOKchat-owned router across arbitrary configured providers/models does not.

### Export/import/sync — Partial to strong

Export/import includes versioned backup, provider config, conversation data, attachment bytes, structured tool rounds, merge/replace restore, validation, and credentials excluded from backups.

Cross-device sync remains the major missing piece.

---

## What has already been achieved

The horizontal foundation now looks like:

`providers → API-family routing → credentials → models → streaming → reasoning → persistence → conversations → attachments → multimodal context → generic tool schemas → native tool calls → tool execution → tool-result replay → recovery → import/export`

The generic tool runtime is important because MCP can now be introduced as a **tool source and transport**, not as a second chat engine. Provider adapters only translate tool wire formats; MCP Phase 2 will discover tools and register handlers against the same normalized runtime.

---

## Recommended next product milestones

Within the current MCP v1 scope, the immediate sequence is:

1. **Phase 2 — Remote MCP**  
   Implement Streamable HTTP server configuration, initialize/discovery, `tools/list`, `tools/call`, caching, auth headers, and server lifecycle/error handling.

2. **Phase 3 — Per-chat tools + safety/UI**  
   Add tool selection, permissions, approvals, and first-class tool-call rendering.

After MCP v1, the next larger product decisions can be projects/workspaces, macOS, cost visibility, and higher-level agents/artifacts.

---

## Bottom line

BYOKchat on this PR is best described as:

> **A mature multimodal, multi-provider BYOK chat foundation with a completed provider-neutral tool-calling engine, but not yet an MCP-connected client.**

Phase 1 removes the hardest coupling risk: the app no longer needs to teach MCP about OpenAI vs Anthropic vs Gemini. Phase 2 can focus on speaking MCP and registering discovered tools; Phase 3 can focus on user control and presentation.
