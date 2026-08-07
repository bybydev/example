# BYOKchat Expanded Vision Progress Review

**Review date:** 2026-08-07  
**Baseline branch:** `develop`  
**Baseline head:** `f704b3c298cb7ac57c0df31cb78b1c8566033580`  
**Updated on PR #2:** image, vision, and file attachments implemented on the PR branch

## Executive summary

BYOKchat is already well beyond a prototype. The codebase has a substantial provider platform, conversation runtime, streaming pipeline, local persistence, credential isolation, search, context management, recovery flows, import/export support, and now a first multimodal attachment path.

Against the expanded product vision, the PR branch is approximately:

| Area | Progress |
|---|---:|
| Core chat | ~90% |
| BYOK/provider layer | ~80% |
| MCP | ~0% |
| Power-user layer | ~15–20% |
| Whole expanded vision | ~40% |

The whole-product percentage remains much lower than the chat percentage because the expanded vision is no longer just a BYOK chat client; it describes a broader AI workbench spanning chat, MCP, projects, agents, artifacts, files, Mac tooling, and routing.

A more useful framing is that BYOKchat is now roughly **90% of the way toward a serious BYOK AI chat client**, while being roughly **40% of the way toward the larger ChatGPT/Claude/Codex-style workbench vision**.

---

## 1. Core chat — ~90%

### Multiple providers — Done

Current first-class providers include:

- DeepSeek
- OpenRouter
- NVIDIA
- user-defined OpenAI-compatible providers
- private-network OpenAI-compatible servers

The provider architecture also supports multiple accounts per provider, model discovery, seed models, manual models, custom endpoints, headers, and different authentication modes.

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
- image `image_url` request parts using base64 data URLs
- UTF-8 text-like file inlining for broad OpenAI-compatible support
- binary `file` content parts for providers that support them, including OpenRouter-style file input
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

Projects/workspaces in the user-facing ChatGPT/Claude sense are not implemented yet.

### Search / context management — Done

Search covers conversation titles, user messages, assistant messages, and attachment filenames.

Context building includes token estimation, context-window budgeting, omission of older turns, attachment-aware turn selection, and UI disclosure when earlier messages were omitted from a request.

### Local models — Mostly done for local servers

BYOKchat supports OpenAI-compatible providers reachable on localhost or the private network, including Ollama- and LM Studio-style servers.

This means local-network model use is already viable. Embedded on-device inference is a separate capability and is not implemented.

---

## 2. BYOK/provider layer — ~80%

This remains one of the strongest parts of the product.

### OpenRouter — Done

OpenRouter is a built-in provider with model discovery and provider-routing options. The multimodal layer now also uses OpenAI-compatible image/file content parts that map naturally onto OpenRouter's multimodal API.

### OpenAI-compatible APIs — Done

This is the main provider abstraction currently implemented and supports custom endpoints, authentication strategies, custom headers, model discovery, streaming, and multimodal message content.

Text-only messages retain normal string content for compatibility. Attachment-bearing messages use multipart content.

### Anthropic / Gemini / DeepSeek — Partial

DeepSeek is first-class.

Anthropic and Gemini are not yet implemented as native API families in the current provider core. The active provider API family is still centered on OpenAI-compatible Chat Completions.

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

Custom endpoints can receive multimodal OpenAI-compatible content, but binary file support ultimately depends on what that endpoint implements. BYOKchat surfaces provider rejection instead of silently dropping attachments.

### Keychain credential management — Done

Credentials are isolated from normal provider configuration and stored in Keychain. They are intentionally excluded from exports and backups.

### Usage / cost visibility — Partial

The runtime captures and persists provider usage information including input, output, cached input, and reasoning tokens where available.

Chat UI can display token usage, and provider models can store prompt/completion pricing metadata.

What is still missing is a complete user-facing cost layer such as calculated per-message cost, per-chat totals, daily/monthly totals, provider/model breakdowns, and budget alerts.

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

The positive side is that the chat, provider, persistence, and attachment architecture is mature enough that MCP can be introduced as a distinct tool-runtime layer rather than mixed prematurely into provider networking.

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

Per-message local image and file attachments are now implemented, persisted, searchable, backed up, and sent as model context.

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

`providers → credentials → models → requests → streaming → reasoning → persistence → conversations → attachments → multimodal requests → context management → search → local endpoints → recovery → import/export`

These are not superficial checklist items. They are shared infrastructure required by most of the remaining product.

The new attachment implementation is especially useful because it is not just a picker UI: the data survives in conversation history, flows through context selection, and reaches the provider request layer.

---

## Recommended next product milestones

The highest-leverage sequence is now:

1. **Generic tool-calling runtime**  
   Introduce provider-neutral tool schemas, calls, results, approvals, persistence, and tool-call UI before MCP-specific transport details.

2. **MCP local + remote**  
   Build server configuration, discovery, permissions, approval flows, auth, and interactive outputs on top of the generic tool runtime.

3. **Projects/workspaces**  
   Group conversations, instructions, files, and tool presets into a persistent user-facing project model.

4. **macOS target**  
   Reuse the provider/chat/tool core and add Mac-specific filesystem, terminal, and code capabilities.

5. **Agents / artifacts / routing**  
   Add higher-level orchestration only after tools, files, projects, and Mac primitives are stable.

6. **Multimodal polish**  
   Add provider capability warnings, richer document previews, blob deduplication, drag/drop/paste intake, and provider-specific file optimizations when they materially improve the experience.

---

## Expected progress after the next major platform additions

Attachments/vision are no longer part of the future estimate; they are now implemented on this PR.

The two largest product additions that would materially change BYOKchat next are:

- MCP/tool calling
- macOS

Together with projects/workspaces, those capabilities should unlock a large portion of the remaining power-user architecture and could reasonably move the product from roughly **40%** of the expanded vision toward approximately **60–65%**, depending on depth and polish.

## Bottom line

BYOKchat on this PR is best described as:

> **A highly developed multimodal BYOK AI chat client foundation, not yet a full AI workbench.**

The provider, conversation, and multimodal foundations are now strong. The next transformation is a general tool/MCP runtime, followed by projects and Mac-specific capabilities that turn the chat client into a broader workbench.
