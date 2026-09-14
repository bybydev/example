# Native Provider APIs

BYOKchat supports multiple provider-native API families behind the same `ProviderAdapter` runtime.

## API families

`ProviderAPIFamily` currently includes:

- `openAIResponses`
- `openAIChatCompletions`
- `anthropicMessages`
- `geminiGenerateContent`

`ProviderRuntime` chooses the adapter from the provider definition, so chat persistence and the rest of the app remain provider-neutral. OpenAI and xAI both use the OpenResponses-compatible family while retaining separate adapters for provider-specific model, reasoning, file, and usage behavior.

## Transport security

Provider HTTP uses an ephemeral URL session on Apple platforms. Cookies and URL caching are disabled.

Redirects are followed only when scheme, host, and effective port remain unchanged. Original request headers are retained only for an approved same-origin redirect; cross-host, cross-port, and cross-scheme redirects are rejected. This prevents bearer keys and custom secret headers from being forwarded to a different origin.

Private-LAN plain HTTP is opt-in per provider and is accepted only for private/local hosts. Enabling local HTTP does not permit arbitrary public `http://` endpoints.

## OpenAI

The built-in OpenAI provider uses the native Responses API. User-defined OpenAI-compatible providers remain on Chat Completions so switching the built-in provider does not change custom-server compatibility.

- Base URL: `https://api.openai.com/v1`
- Responses: `POST /responses`
- Models: `GET /models`
- Authentication: bearer API key
- Response storage: disabled (`store: false`)

### Request mapping

- BYOKchat system, user, and assistant history becomes Responses `input` message items.
- Images use `input_image` data URLs.
- Files use `input_file` with filename and inline data.
- Tool declarations use native Responses function tools.
- Assistant function calls and tool results use `function_call` and `function_call_output` items.
- `maxOutputTokens` maps to `max_output_tokens`.
- Sampling controls are model-aware: GPT-6 Astra never receives `temperature`/`top_p`; GPT-5 reasoning families receive them only when reasoning is explicitly `none`; ordinary non-reasoning chat models can still use them.

### Streaming and reasoning

Responses SSE is normalized into the existing provider stream:

- `response.output_text.delta` and refusal deltas → answer text
- `response.reasoning_summary_text.delta` → reasoning summary
- completion usage → `ProviderUsage`, including cached-input and reasoning tokens
- `response.completed` / `response.incomplete` → normalized completed response

BYOKchat requests reasoning summaries rather than exposing hidden chain-of-thought. Provider-neutral reasoning effort is mapped to the supported OpenAI reasoning effort for the selected reasoning-model family. GPT-6 Astra has no `none` mode, so an explicit BYOKchat reasoning-off request is clamped to Astra's lowest supported `low` effort; GPT-5.6 models use `none`.

BYOKchat manages conversation history locally and sends `store: false`. It therefore requests `reasoning.encrypted_content` and persists the returned opaque Responses output in the authoritative conversation record. Historical OpenAI assistant turns replay that provider output unchanged, including encrypted reasoning items and function-call items. The compact conversation index omits this opaque payload so it is not duplicated into `index.json`.

The connection probe also uses the lowest supported reasoning setting with a small but safe output budget, avoiding false failures caused by reasoning tokens consuming an extremely small generation cap.

### Current curated models

The built-in fallback catalog currently includes:

- `gpt-6-astra`
- `gpt-5.6-sol`
- `gpt-5.6-terra`
- `gpt-5.6-luna`

All four carry the current 1.05M context / 128K maximum-output metadata in the seed catalog. Account refresh still uses `GET /models`, and discovered records are merged with the curated metadata.

OpenAI's model-list endpoint also returns models that are not normal Responses chat targets. BYOKchat filters obvious embedding, moderation, image, audio, transcription, realtime, video, and similar specialized families from the chat model picker. Discovered GPT/o-series chat models are enriched with provider capabilities such as function tools and reasoning support so the model picker can expose the right controls even though `GET /models` does not provide those capability fields.

## xAI

The built-in xAI provider uses xAI's native Responses API through a dedicated adapter. It shares BYOKchat's provider-neutral Responses continuation format with OpenAI, but xAI-specific reasoning, model discovery, file upload, and billing behavior remains isolated in `XAIResponsesAdapter`.

- Base URL: `https://api.x.ai/v1`
- Responses: `POST /responses`
- Language models: `GET /language-models`
- Compatibility discovery fallback: `GET /models`
- Files: `POST /files`
- Authentication: bearer API key
- Response storage: disabled (`store: false`)

### Request mapping

- Text/history uses Responses `input` message items.
- PNG/JPEG images use `input_image` data URLs.
- Private document attachments are uploaded to the xAI Files API first and referenced using `input_file.file_id`.
- Uploaded BYOKchat attachment files use a 24-hour `expires_after` TTL so temporary chat attachments are not left in xAI storage indefinitely.
- Function/MCP tools use native Responses function definitions, with `function_call` and `function_call_output` items preserved across tool rounds.
- `maxOutputTokens` maps to `max_output_tokens`; provider-neutral temperature/top-p options are forwarded when present.

The multipart uploader deliberately emits `expires_after` before the `file` field because xAI requires that ordering. BYOKchat keeps its existing stricter local attachment limits even though the xAI Files API itself accepts larger files.

### Reasoning and continuation

Reasoning capability and configurable reasoning effort are treated separately because current Grok families differ:

- Grok 4.6: low / medium / high / xhigh; reasoning cannot be disabled.
- Grok 4.5: low / medium / high; BYOKchat clamps its Max setting to high.
- Grok 4.3: configurable reasoning including `none`; reasoning-off maps to `none`.
- Grok 4.20 Multi-Agent: effort controls agent count; BYOKchat maps Max to `xhigh`.
- Grok 4.20 reasoning: reasoning is preserved, but BYOKchat does not send an undocumented effort override.
- Grok 4.20 non-reasoning: no reasoning control is advertised.

For reasoning families that cannot be disabled, an explicit reasoning-off selection is clamped to their lowest supported `low` behavior rather than sending an invalid `none`.

With `store: false`, reasoning-capable xAI requests include `reasoning.encrypted_content` even when a family has no configurable effort control. Returned opaque reasoning and function-call output items are persisted and replayed unchanged for later local-history and MCP/tool turns. Streaming reasoning summaries are normalized separately from answer text.

### Usage and billing

xAI usage is normalized into `ProviderUsage`, including cached input and reasoning tokens. When xAI returns `cost_in_usd_ticks`, BYOKchat preserves the raw tick value and converts it into generic provider-reported USD cost (10,000,000,000 ticks = USD 1).

For model → tool → model loops, provider-reported costs are summed across every model request. BYOKchat marks the final turn as provider-reported only when every request in the loop supplied exact cost; if any request omits it, partial exact cost is discarded and normal token-price calculation is used instead of silently undercounting.

Native `/language-models` discovery also imports xAI's live prompt/completion token prices into `ProviderModel` when those fields are present. Exact provider-reported billed cost still wins after inference, including cases where provider pricing tiers or discounts differ from a simple token estimate.

### Current curated models

The fallback catalog includes current Grok chat families so a newly connected account is usable before discovery:

- `grok-4.6`
- `grok-4.20-0309-reasoning`
- `grok-4.20-non-reasoning`
- `grok-4.20-multi-agent`
- `grok-4.3`

BYOKchat prefers xAI's native `GET /language-models` endpoint because it exposes richer language-model metadata such as modalities, aliases, fingerprints, and token pricing. If that endpoint is unavailable for an otherwise compatible xAI account, discovery falls back to `GET /models`. The resulting catalog still filters obvious image/video/voice and other non-chat model families and merges curated reasoning/tool/multimodal metadata where useful.

### Deliberately separate xAI features

Normal BYOKchat chat/MCP parity does not require every xAI-hosted server-side capability. Web/X search, code execution, Structured Outputs UI/schema controls, conversation-specific `prompt_cache_key` routing, collections/RAG, and media-generation APIs remain separate product features rather than being silently enabled inside the chat provider adapter.

## Anthropic

The built-in Anthropic provider uses the native Messages API.

- Base URL: `https://api.anthropic.com`
- Messages: `POST /v1/messages`
- Models: `GET /v1/models`
- Authentication: `x-api-key`
- API version header: `anthropic-version: 2023-06-01`

### Request mapping

- BYOKchat system messages become the top-level Anthropic `system` value.
- User and assistant turns become Messages API `messages` entries.
- Images become base64 `image` source blocks.
- PDFs become base64 `document` source blocks.
- UTF-8 text-like files become text blocks with the filename and contents.
- Unsupported binary file formats are rejected before the request rather than silently discarded.
- Tool declarations use native `tools` with `input_schema`.
- Assistant tool calls use `tool_use` blocks and results use `tool_result` blocks.

### Streaming and reasoning

Anthropic SSE events are normalized into the existing provider stream:

- `text_delta` → answer text
- `thinking_delta` → reasoning summary
- `input_json_delta` → streamed tool-argument fragments
- usage updates → `ProviderUsage`
- `message_stop` → completed response

Current Claude 5 models use adaptive thinking. When BYOKchat reasoning display is enabled, the adapter requests summarized thinking and maps BYOKchat reasoning effort to Anthropic `output_config.effort`.

For tool turns, signed thinking blocks are retained as opaque provider continuation data and replayed unchanged on the next Messages request. BYOKchat does not interpret the signature itself.

The adapter intentionally does not forward generic temperature/top-p overrides to the current native Claude family.

### Request-size caveat

The direct Anthropic Messages API has a 32 MB request limit. Because BYOKchat currently stores inline attachment bytes in conversation history, a long retained context containing several large historical attachments can exceed that provider request limit even though each original message passed BYOKchat's local per-message limits.

For now the provider will surface that error. A later provider-native Files API/blob-reference layer should prevent repeated large inline payloads and remains separate from the native adapter.

## Gemini

The built-in Gemini provider uses the native GenerateContent API.

- Base URL: `https://generativelanguage.googleapis.com/v1beta`
- Generate: `POST /models/{model}:generateContent`
- Stream: `POST /models/{model}:streamGenerateContent?alt=sse`
- Models: `GET /models`
- Authentication: `x-goog-api-key`

### Request mapping

- BYOKchat system messages become `systemInstruction`.
- User turns use Gemini `user` content and assistant history uses `model` content.
- Images and binary files use base64 `inlineData` parts.
- UTF-8 text-like files are inserted as text parts with filename context.
- Tool declarations use native `functionDeclarations`.
- Assistant calls use `functionCall` parts and results use `functionResponse` parts.

### Streaming and reasoning

Gemini streaming responses are normalized into the same provider stream used by the rest of the app.

- normal text parts → answer text
- parts marked `thought` → reasoning summary
- function-call parts → normalized `ChatToolCall`
- `usageMetadata` → `ProviderUsage`
- a candidate `finishReason` completes the stream

When reasoning display is enabled, BYOKchat requests thought summaries through `thinkingConfig.includeThoughts`. Gemini 3 models map BYOKchat reasoning effort to `thinkingLevel`.

For tool turns, the thought signature attached to a function call is retained as opaque provider continuation data and replayed on the matching historical `functionCall` part.

Gemini 3.6 Flash no longer advertises temperature/top-p controls in BYOKchat, and the native adapter ignores stale generic sampling values for that model family.

## Model discovery

OpenAI, xAI, Anthropic, and Gemini use provider model-discovery endpoints. xAI prefers `/language-models` and falls back to `/models`; OpenAI uses `/models`; Anthropic and Gemini use their native model-list endpoints.

BYOKchat merges discovered models with curated seed metadata while preserving local favorite/hidden/manual state through the existing provider workspace.

The initial curated native models are:

- OpenAI: `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`
- xAI: `grok-4.6`, `grok-4.20-0309-reasoning`, `grok-4.20-non-reasoning`, `grok-4.20-multi-agent`, `grok-4.3`
- Anthropic: `claude-sonnet-5`, `claude-opus-5`
- Gemini: `gemini-3.6-flash`

Users can refresh the account model list to discover other currently available models.

## Tool continuation compatibility

Provider-native reasoning metadata is not treated as display-only when a model requests tools.

The generic tool runtime defines `ProviderToolContinuation`, an opaque persistence envelope used only by the matching provider adapter. This keeps provider-required continuation metadata out of normal chat text while allowing a tool turn to survive persistence, relaunch, backup/restore, and later context rebuilding. Continuation is stored only in authoritative conversation state and is omitted from the compact index.

Current continuation support includes:

- OpenAI Responses output items, including encrypted reasoning content and function calls
- xAI Responses output items, including encrypted reasoning content and function calls
- Anthropic signed thinking blocks
- Gemini thought signatures associated with function calls

OpenAI-compatible Chat Completions does not currently require an equivalent opaque continuation field for normal function calling.

## Current limitations

Future provider-specific work includes:

- provider-native file upload/file-ID APIs for providers that still inline attachment data (xAI already uses its Files API)
- native structured-output schema controls beyond ordinary tool schemas
- provider-specific prompt caching controls where the provider exposes meaningful explicit controls
- provider-hosted search/code/RAG tools as explicit product features rather than implicit chat behavior

Tool execution permissions, per-chat tool selection, and tool-call rendering are implemented by the provider-neutral tool/MCP runtime rather than by individual provider adapters.
