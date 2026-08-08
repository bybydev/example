# Context Management

BYOKchat owns conversation state locally and treats provider APIs as stateless transports. The local transcript remains the source of truth even when a conversation switches provider or model.

## Current strategy

The request context is built from:

1. The conversation system prompt.
2. Persistent project/reference attachments.
3. The newest complete conversation turns that fit the input budget.
4. Any required in-flight tool continuation messages.
5. Tool definitions supplied with the request.

The reducer removes only whole historical turns. A user message, its assistant reply, and persisted tool exchanges are kept or removed together so the app never creates orphaned tool calls or tool results. History also remains contiguous: the reducer never skips a large recent turn just to include an older smaller one.

## Budgeting

The effective history budget is:

```text
context window
- reserved output tokens
- estimation safety margin
- system/project fixed context
- tool definitions
- required in-flight tool continuation
```

Output reservation deliberately separates **what the request asks for** from **what the model is capable of producing**:

- An explicit per-chat output limit is the requested generation ceiling and is reserved as-is.
- When the chat does not set an output limit, BYOKchat uses a 4096-token fallback reserve.
- A model's advertised `maxOutputTokens` is only a capability ceiling on that fallback. It can reduce a 4096-token fallback for a small-output model, but a 128k/384k advertised maximum never inflates the reserve to 128k/384k.
- For a small known context window, the fallback is also capped at one quarter of the total window so the fallback itself cannot consume the entire prompt budget.

This matches the transport behavior: an unset generation option is still unset when the request reaches providers whose API can choose its own default; Anthropic currently supplies its own 4096-token default at the adapter layer.

`ChatContextPolicy.automatic` targets 5% of the model context window as estimation headroom, with a 64-token preferred minimum and a 65,536-token maximum. For small models, the safety reserve is capped at one quarter of the capacity remaining after output reservation. The safety margin exists to absorb estimation error; it must never starve the actual prompt.

`estimatedInputTokens` reports the estimated request payload itself. It intentionally does not include the unused safety reserve.

## Approximate token counting

The current counter is a provider-independent fallback, not a claim of exact tokenizer parity.

- ASCII text uses the common approximately four-bytes-per-token heuristic.
- Non-ASCII text is counted more conservatively using both UTF-8 bytes and Unicode scalar count so CJK text is not underestimated by simply dividing its multibyte UTF-8 representation by four.
- Attachment metadata, tool schemas, tool-call IDs, tool-result IDs, tool arguments/results, and opaque provider continuation payloads all contribute to the estimate.

Images and binary documents remain inherently provider-specific. Their fallback costs are deliberately coarse until provider/model-specific token counters are added. Therefore the safety margin is a guardrail, not a guarantee of exact fit for every multimodal payload.

## Tools and MCP

Tool schemas are part of the model prompt and therefore count against the context window. Context budgeting includes tool names, descriptions, and JSON schemas before the first provider request.

A multi-round tool turn is also dynamic: tool calls and tool results increase the next request size after the first model response. `ChatRuntime` therefore rebuilds the context after every tool round. Older historical turns may be removed as the live tool continuation grows, but the current user turn and all required continuation messages are preserved atomically.

If the current turn plus its required tool continuation cannot fit, BYOKchat fails with `contextWindowExceeded` instead of silently dropping tool state and sending an invalid conversation. If a fixed tool schema is already too large, the failure happens before the provider request so the user is not billed for a request that BYOKchat already knows cannot fit.

## Why this is implemented in BYOKchatProviderCore

The proven algorithms needed for ordinary chat context are small: output reservation, token-budget reduction, newest-turn retention, atomic tool grouping, and optional summarization. Pulling in a general agent framework would couple conversation semantics to a framework that is not shared across Swift providers and would make provider switching harder.

BYOKchat therefore keeps the reducer provider-independent and uses provider adapters only for transport/wire-format concerns.

## Regression coverage

The context suites cover:

- explicit small output ceilings;
- distinction between requested output and advertised model maximum output;
- unknown output limits on small context windows;
- safety-margin starvation protection;
- CJK fallback estimation;
- tool-schema and tool-call/result-ID accounting;
- opaque provider continuation accounting;
- atomic trimming of persisted tool rounds;
- required live tool continuation preservation;
- two consecutive tool rounds preserving every call/result/continuation in order;
- overflow failure instead of dropping the current user turn;
- preflight rejection of oversized tool schemas before any provider request;
- runtime re-budgeting between the first and second requests of a tool loop;
- oversized tool results stopping before a second provider request while persisting the failed turn.

## Token counting roadmap

A future `TokenCounter` abstraction can provide provider/model-specific counting while keeping `ChatContextBuilder` as the policy layer:

- exact provider token-count endpoints when available;
- local model tokenizers when practical;
- approximate counting as the universal fallback;
- calibration against returned `usage.inputTokens`.

Exact counting should reduce the safety margin, not move conversation ownership into provider SDKs.

## Rolling summary roadmap

Rolling summarization is intentionally not automatic yet. It adds another paid BYOK request, latency, and lossy state that needs clear product behavior.

When introduced, the summary should be a derived context artifact, never the canonical transcript. The intended layout is:

```text
system prompt
+ structured summary of older turns
+ newest raw turns that fit
+ current user/tool continuation
```

The complete original messages remain stored locally. A summary can be discarded and regenerated without changing chat history.
