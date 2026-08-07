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

### Streaming and reasoning

Anthropic SSE events are normalized into the existing provider stream:

- `text_delta` → answer text
- `thinking_delta` → reasoning summary
- usage updates → `ProviderUsage`
- `message_stop` → completed response

Current Claude 5 models use adaptive thinking. When BYOKchat reasoning display is enabled, the adapter requests summarized thinking and maps BYOKchat reasoning effort to Anthropic `output_config.effort`.

The adapter intentionally does not forward generic temperature/top-p overrides to the current native Claude family.

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

### Streaming and reasoning

Gemini streaming responses are normalized into the same provider stream used by the rest of the app.

- normal text parts → answer text
- parts marked `thought` → reasoning summary
- `usageMetadata` → `ProviderUsage`
- a candidate `finishReason` completes the stream

When reasoning display is enabled, BYOKchat requests thought summaries through `thinkingConfig.includeThoughts`. Gemini 3 models map BYOKchat reasoning effort to `thinkingLevel`.

Gemini 3.6 Flash no longer advertises temperature/top-p controls in BYOKchat, and the native adapter ignores stale generic sampling values for that model family.

## Model discovery

Anthropic and Gemini both use their provider-native model-list endpoints.

BYOKchat merges discovered models with curated seed metadata while preserving local favorite/hidden/manual state through the existing provider workspace.

The initial curated native models are:

- Anthropic: `claude-sonnet-5`, `claude-opus-5`
- Gemini: `gemini-3.6-flash`

Users can refresh the account model list to discover other currently available models.

## Current limitations

The first native implementation deliberately stays within the existing chat/runtime contract.

Not yet preserved across turns:

- Anthropic encrypted thinking-block signatures
- Gemini thought signatures

Normal multi-turn text and multimodal chat work without those fields. Signature round-tripping becomes particularly important when provider-native tool/function calling is added, so it should be implemented as part of the generic tool-runtime milestone rather than hidden inside chat text persistence.

Other future work:

- provider-native file upload/file-ID APIs where they reduce repeated payload cost
- provider capability warnings before sending unsupported attachment types
- native structured-output/tool schemas
- provider-specific prompt caching controls
