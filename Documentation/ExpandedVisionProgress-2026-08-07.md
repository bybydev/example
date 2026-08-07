# BYOKchat Expanded Vision Progress Review

**Review date:** 2026-08-07  
**Reviewed branch:** `develop`  
**Reviewed head:** `f704b3c298cb7ac57c0df31cb78b1c8566033580`

## Executive summary

BYOKchat is already well beyond a prototype. The current codebase has a substantial provider platform, conversation runtime, streaming pipeline, local persistence, credential isolation, search, context management, recovery flows, and import/export support.

Against the expanded product vision below, the current implementation is approximately:

| Area | Progress |
|---|---:|
| Core chat | ~75% |
| BYOK/provider layer | ~80% |
| MCP | ~0% |
| Power-user layer | ~10–15% |
| Whole expanded vision | ~35% |

The whole-product percentage looks lower because the expanded vision is no longer just a BYOK chat client; it describes a broader AI workbench spanning chat, MCP, projects, agents, artifacts, files, Mac tooling, and routing.

A more useful framing is that BYOKchat is roughly **75–80% of the way toward a serious BYOK AI chat client**, while being roughly **35% of the way toward the larger ChatGPT/Claude/Codex-style workbench vision**.

---

## 1. Core chat — ~75%

### Multiple providers — Done

Current first-class providers include:

- DeepSeek
- OpenRouter
- NVIDIA
- user-defined OpenAI-compatible providers
- private-network OpenAI-compatible servers

The provider architecture also supports multiple accounts per provider, model discovery, seed models, manual models, custom endpoints, headers, and different authentication modes.

### Model switching — Done

Provider account and model selection are already first-class conversation settings. Conversations persist their provider, account, model, system prompt, and generation options.

### Image / vision / files — Missing

The current chat model is text-oriented. Image input, vision payloads, and general file attachments are not implemented yet.

This is one of the largest remaining gaps in the core chat experience.

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

Projects/workspaces in the user-facing ChatGPT/Claude sense are not implemented yet.

### Search / context management — Done

Search already covers conversation titles, user messages, and assistant messages.

Context building includes token estimation, context-window budgeting, omission of older turns, and UI disclosure when earlier messages were omitted from a request.

### Local models — Mostly done for local servers

BYOKchat supports OpenAI-compatible providers reachable on localhost or the private network, including Ollama- and LM Studio-style servers.

This means local-network model use is already viable. Embedded on-device inference is a separate capability and is not implemented.

---

## 2. BYOK/provider layer — ~80%

This is currently the strongest part of the product.

### OpenRouter — Done

OpenRouter is a built-in provider with model discovery and provider-routing options.

### OpenAI-compatible APIs — Done

This is the main provider abstraction currently implemented and already supports custom endpoints, authentication strategies, custom headers, model discovery, and streaming.

### Anthropic / Gemini / DeepSeek — Partial

DeepSeek is first-class.

Anthropic and Gemini are not yet implemented as native API families in the current provider core. The active provider API family is still centered on OpenAI-compatible Chat Completions.

### Custom endpoints — Done

Custom endpoint support is already strong, including:

- HTTPS custom providers
- explicit private-LAN HTTP support
- bearer authentication
- named credential headers
- no-auth local providers
- additional headers
- model discovery
- manual models

### Keychain credential management — Done

Credentials are isolated from normal provider configuration and stored in Keychain. They are intentionally excluded from exports and backups.

### Usage / cost visibility — Partial

The runtime already captures and persists provider usage information including input, output, cached input, and reasoning tokens where available.

Chat UI can display token usage, and provider models can store prompt/completion pricing metadata.

What is still missing is a complete user-facing cost layer such as:

- calculated per-message cost
- per-chat totals
- daily/monthly totals
- provider/model breakdown
- budget alerts

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

This is the largest untouched architectural block in the expanded vision.

The positive side is that the current chat and provider architecture is already mature enough that MCP can be introduced as a distinct tool-runtime layer instead of being mixed prematurely into provider networking or conversation persistence.

---

## 4. Power-user layer — ~10–15%

### Projects/workspaces — Missing

No user-facing project/workspace abstraction currently groups chats, instructions, files, and tools.

### Reusable prompts — Early foundation

Global and per-conversation system prompts already exist, so the underlying prompt plumbing is present.

A reusable prompt library, picker, variables, and prompt presets are still missing.

### Agents — Missing

There is no agent execution/runtime abstraction yet.

### Artifacts — Missing

There is no first-class artifact model or artifact editor/viewer yet.

### File access — Missing

General file attachment and file-context access are not implemented.

### Terminal/code tools on Mac — Missing

The current product is iOS-only. Mac-specific terminal, filesystem, and code tooling are future work.

### Tool presets — Missing

This depends heavily on the MCP/tool layer.

### Model routing — Early foundation

OpenRouter-specific routing configuration already supports concepts such as provider order, fallbacks, parameter requirements, price/throughput/latency sorting, and data-collection preferences.

A BYOKchat-owned router that chooses among arbitrary configured providers/models is not implemented yet.

### Export/import/sync — Partial to strong

Export/import is already sophisticated:

- versioned full backup
- provider configuration export
- conversation export
- merge restore
- replace restore
- schema/reference validation
- credentials excluded from backups
- Markdown conversation export

Cross-device sync is the missing major piece.

---

## What has already been achieved

The most important progress is the horizontal foundation already in place:

`providers → credentials → models → requests → streaming → reasoning → persistence → conversations → context management → search → local endpoints → recovery → import/export`

These are not superficial checklist items. They are the shared infrastructure required by most of the remaining product.

Because of that, the remaining roadmap should not be interpreted as another 65% of equally foundational work. Much of the future product can now be layered on top of an existing runtime.

---

## Recommended next product milestones

The highest-leverage sequence is:

1. **Attachments + vision**  
   Extend the conversation/message/request model to support image and file content safely across providers.

2. **Generic tool-calling runtime**  
   Introduce provider-neutral tool schemas, calls, results, approvals, persistence, and tool-call UI before MCP-specific transport details.

3. **MCP local + remote**  
   Build server configuration, discovery, permissions, approval flows, auth, and interactive outputs on top of the generic tool runtime.

4. **Projects/workspaces**  
   Group conversations, instructions, files, and tool presets into a persistent user-facing project model.

5. **macOS target**  
   Reuse the provider/chat/tool core and add Mac-specific filesystem, terminal, and code capabilities.

6. **Agents / artifacts / routing**  
   Add higher-level orchestration only after tools, files, projects, and Mac primitives are stable.

---

## Expected progress after the next major platform additions

Adding the following three capabilities would move BYOKchat much closer to the expanded vision:

- attachments/vision
- MCP/tool calling
- macOS

Those additions should unlock a large portion of the remaining power-user architecture and could reasonably move the product from roughly **35%** of the expanded vision to approximately **60–65%**, depending on depth and polish.

## Bottom line

BYOKchat today is best described as:

> **A largely built BYOK AI chat foundation, not yet a full AI workbench.**

The provider and conversation foundations are already the strongest and most difficult parts of a BYOK client. The next transformation is adding multimodal input and a general tool/MCP runtime, then using those primitives to build projects, Mac tooling, agents, and artifacts.
