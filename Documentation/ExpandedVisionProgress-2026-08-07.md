# BYOKchat Expanded Vision Progress Review

**Review date:** 2026-08-07  
**Baseline branch:** `develop`  
**Baseline head:** `f704b3c298cb7ac57c0df31cb78b1c8566033580`  
**Updated on PR #2:** multimodal attachments, streaming timeline stabilization, and native Anthropic/Gemini API families implemented on the PR branch

## Executive summary

BYOKchat is already well beyond a prototype. The codebase has a substantial provider platform, conversation runtime, streaming pipeline, local persistence, credential isolation, search, context management, recovery flows, import/export support, multimodal attachments, and three provider API families.

Against the expanded product vision, the PR branch is approximately:

| Area | Progress |
|---|---:|
| Core chat | ~90% |
| BYOK/provider layer | ~95% |
| MCP | ~0% |
| Power-user layer | ~15–20% |
| Whole expanded vision | ~42% |

The whole-product percentage remains much lower than the chat/provider percentages because the expanded vision is no longer just a BYOK chat client; it describes a broader AI workbench spanning chat, MCP, projects, agents, artifacts, files, Mac tooling, and routing.

A more useful framing is that BYOKchat is now roughly **90% of the way toward a serious multimodal BYOK AI chat client**, while being roughly **42% of the way toward the larger ChatGPT/Claude/Codex-style workbench vision**.

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

The PR adds a complete first attachment path across UI, persistence, context construction, and provider requests.

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

Remaining attachment polish includes richer PDF/document preview, separate blob storage/deduplication, provider-specific upload/file-ID APIs where useful, capability warnings before sending unsupported modalities, drag/drop and paste intake, and attachment metadata in Markdown export.

### Conversations / projects — Partial

Conversations are mature. Current support includes:

- multiple persistent local conversations
- per-chat provider/model settings
- drafts
- edit and resend
- regenerate
- cancellation
- interrupted-generation repair
- Markdown rendering
- reasoning display
- message copy/share
- conversation export
- persisted image/file attachments
- stable near-bottom streaming that stops fighting the user after manual scroll

Projects/workspaces in the user-facing ChatGPT/Claude sense are not implemented yet.

### Search / context management — Done

Search covers conversation titles, user messages, assistant messages, and attachment filenames.

Context building includes token estimation, context-window budgeting, omission of older turns, attachment-aware turn selection, and UI disclosure when earlier messages were omitted from a request.

### Local models — Mostly done for local servers

BYOKchat supports OpenAI-compatible providers reachable on localhost or the private network, including Ollama- and LM Studio-style servers.

This means local-network model use is already viable. Embedded on-device inference is a separate capability and is not implemented.

---

## 2. BYOK/provider layer — ~95%

This is now one of the most complete parts of the product.

### OpenRouter — Done

OpenRouter is a built-in provider with model discovery, multimodal request support, and provider-routing options.

### OpenAI-compatible APIs — Done

OpenAI-compatible Chat Completions remains the flexible custom-provider family and supports custom endpoints, authentication strategies, custom headers, model discovery, streaming, reasoning normalization, and multimodal message content.

Text-only messages retain normal string content for broad compatibility. Attachment-bearing messages use multipart content.

### Anthropic / Gemini / DeepSeek — Done

All three are now first-class provider paths.

DeepSeek keeps its existing specialized OpenAI-compatible behavior.

Anthropic now uses the native Messages API:

- `POST /v1/messages`
- `GET /v1/models`
- `x-api-key` authentication
- Anthropic API version header
- native system-message mapping
- native image/PDF blocks
- SSE streaming
- summarized adaptive-thinking deltas
- usage and model metadata normalization

Gemini now uses the native GenerateContent API:

- `POST /models/{model}:generateContent`
- `POST /models/{model}:streamGenerateContent?alt=sse`
- `GET /models`
- `x-goog-api-key` authentication
- `systemInstruction`
- native `inlineData` multimodal parts
- thought-summary separation
- usage/model metadata normalization
- Gemini 3 thinking-level controls

`ProviderAPIFamily` now includes:

- `openAIChatCompletions`
- `anthropicMessages`
- `geminiGenerateContent`

Provider runtime selection is API-family based, so conversation/runtime code remains provider-neutral.

The native implementations intentionally do not yet round-trip Anthropic encrypted thinking signatures or Gemini thought signatures into later turns. That becomes especially important when native tool/function calling is introduced and belongs with the generic tool-runtime milestone.

### Custom endpoints — Done

Custom endpoint support includes:

- HTTPS custom providers
- explicit private-LAN HTTP support
- bearer authentication
- named credential headers
- no-auth local providers
- additional headers
- model discovery
- manual models

Custom providers remain OpenAI-compatible by design. Native Anthropic and Gemini are explicit built-in provider families rather than trying to overload the custom OpenAI-compatible editor.

### Keychain credential management — Done

Credentials are isolated from normal provider configuration and stored in Keychain. They are intentionally excluded from exports and backups.

Native Anthropic and Gemini keys use the same account-level Keychain isolation as every other provider.

### Usage / cost visibility — Partial

The runtime captures and persists provider usage information including input, output, cached input, and reasoning/thinking tokens where available. The native Anthropic and Gemini adapters normalize their provider-specific usage fields into the same `ProviderUsage` model.

Chat UI can display token usage, and provider models can store prompt/completion pricing metadata.

What is still missing is a complete user-facing cost layer such as:

- calculated per-message cost
- per-chat totals
- daily/monthly totals
- provider/model breakdown
- budget alerts

This cost layer is now the largest unfinished item in the BYOK/provider roadmap.

---

## 3. MCP — ~0%

The MCP layer has not been implemented yet.

Remaining work includes:

- local MCP servers
- remote MCP servers
- OAuth/authentication
- tool discovery
- permissions
- per-chat tools
- approval flows
- tool-call UI
- MCP Apps / interactive output

This is now clearly the largest untouched architectural block in the expanded vision.

The positive side is that the chat, provider, persistence, multimodal, and native-provider architecture is mature enough that MCP can be introduced as a distinct tool-runtime layer rather than mixed prematurely into provider networking.

---

## 4. Power-user layer — ~15–20%

### Projects/workspaces — Missing

No user-facing project/workspace abstraction currently groups chats, instructions, files, and tools.

### Reusable prompts — Early foundation

Global and per-conversation system prompts already exist, so the underlying prompt plumbing is present.

A reusable prompt library, picker, variables, and prompt presets are still missing.

### Agents — Missing

There is no agent execution/runtime abstraction yet.

### Artifacts — Missing

There is no first-class artifact model or artifact editor/viewer yet.

### File access — Partial

Per-message local image and file attachments are implemented, persisted, searchable, backed up, and sent as provider-native model context.

Broader workspace file access is still missing: there is no project-level file collection, filesystem tool, searchable file index, or agent-accessible file workspace yet.

### Terminal/code tools on Mac — Missing

The current product is iOS-only. Mac-specific terminal, filesystem, and code tooling are future work.

### Tool presets — Missing

This depends heavily on the MCP/tool layer.

### Model routing — Early foundation

OpenRouter-specific routing configuration supports concepts such as provider order, fallbacks, parameter requirements, price/throughput/latency sorting, and data-collection preferences.

A BYOKchat-owned router that chooses among arbitrary configured providers/models is not implemented yet.

### Export/import/sync — Partial to strong

Export/import is sophisticated:

- versioned full backup
- provider configuration export
- conversation export
- persisted attachment bytes in full backup
- merge restore
- replace restore
- schema/reference validation
- credentials excluded from backups
- Markdown conversation export

Cross-device sync is the missing major piece. Markdown export also does not yet enumerate attachment metadata.

---

## What has already been achieved

The horizontal foundation now looks like:

`providers → API-family routing → credentials → models → requests → native/provider-compatible streaming → reasoning summaries → persistence → conversations → attachments → multimodal requests → context management → search → local endpoints → recovery → import/export`

These are not superficial checklist items. They are shared infrastructure required by most of the remaining product.

The native Anthropic/Gemini work is especially meaningful because it proves the provider core is no longer structurally tied to OpenAI Chat Completions. New API families can plug into the same conversation and streaming runtime without duplicating the app layer.

---

## Recommended next product milestones

The highest-leverage sequence is now:

1. **Generic tool-calling runtime**  
   Introduce provider-neutral tool schemas, calls, results, approvals, persistence, and tool-call UI before MCP-specific transport details. Preserve provider-native thinking/thought signatures as part of this work.

2. **MCP local + remote**  
   Build server configuration, discovery, permissions, approval flows, auth, and interactive outputs on top of the generic tool runtime.

3. **Projects/workspaces**  
   Group conversations, instructions, files, and tool presets into a persistent user-facing project model.

4. **macOS target**  
   Reuse the provider/chat/tool core and add Mac-specific filesystem, terminal, and code capabilities.

5. **Agents / artifacts / routing**  
   Add higher-level orchestration only after tools, files, projects, and Mac primitives are stable.

6. **Provider/multimodal polish**  
   Add cost visibility, provider capability warnings, richer document previews, blob deduplication, drag/drop/paste intake, and provider-specific file optimizations when they materially improve the experience.

---

## Expected progress after the next major platform additions

Attachments/vision and native Anthropic/Gemini APIs are no longer future items; they are implemented on this PR.

The two largest product additions that would materially change BYOKchat next are:

- MCP/tool calling
- macOS

Together with projects/workspaces, those capabilities should unlock a large portion of the remaining power-user architecture and could reasonably move the product from roughly **42%** of the expanded vision toward approximately **60–65%**, depending on depth and polish.

## Bottom line

BYOKchat on this PR is best described as:

> **A highly developed multimodal, multi-API-family BYOK AI chat client foundation, not yet a full AI workbench.**

The provider, conversation, multimodal, and native API foundations are now strong. The next transformation is a general tool/MCP runtime, followed by projects and Mac-specific capabilities that turn the chat client into a broader workbench.
