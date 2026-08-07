# Native Provider APIs

BYOKchat supports multiple provider-native API families behind the same `ProviderAdapter` runtime.

## API families

`ProviderAPIFamily` currently includes:

- `openAIChatCompletions`
- `anthropicMessages`
- `geminiGenerateContent`

`ProviderRuntime` chooses the adapter from the provider definition, so chat persistence and the rest of the app remain provider-neutral.

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

For now the provider will surface that error. A later provider-native Files API/blob-reference layer should prevent repeated large inline payloads and is intentionally kept separate from this native adapter milestone.

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

Anthropic and Gemini both use their provider-native model-list endpoints.

BYOKchat merges discovered models with curated seed metadata while preserving local favorite/hidden/manual state through the existing provider workspace.

The initial curated native models are:

- Anthropic: `claude-sonnet-5`, `claude-opus-5`
- Gemini: `gemini-3.6-flash`

Users can refresh the account model list to discover other currently available models.

## Tool continuation compatibility

Provider-native reasoning metadata is no longer treated as display-only when a model requests tools.

The generic tool-runtime milestone adds `ProviderToolContinuation`, an opaque persistence envelope used only by the matching provider adapter. This keeps provider-required continuation metadata out of normal chat text while allowing a tool turn to survive persistence, relaunch, and later context rebuilding.

Current continuation support includes:

- Anthropic signed thinking blocks
- Gemini thought signatures associated with function calls

OpenAI-compatible Chat Completions does not currently require an equivalent opaque continuation field for normal function calling.

## Current limitations

Future provider-specific work includes:

- provider-native file upload/file-ID APIs where they reduce repeated payload cost
- native structured-output schema controls beyond ordinary tool schemas
- provider-specific prompt caching controls

Tool execution permissions, per-chat tool selection, and tool-call rendering belong to Phase 3 of the MCP roadmap rather than the provider adapters.
