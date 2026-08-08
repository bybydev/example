# Context Management

BYOKchat owns conversation state locally and treats provider APIs as stateless transports. The local transcript remains the source of truth even when a conversation switches provider or model.

## Current strategy

The request context is built from:

1. The conversation system prompt.
2. Persistent project/reference attachments.
3. The newest complete conversation turns that fit the input budget.
4. Any required in-flight tool continuation messages.
5. Tool definitions supplied with the request.

The reducer removes only whole historical turns. A user message, its assistant reply, and persisted tool exchanges are kept or removed together so the app never creates orphaned tool calls or tool results.

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

`ChatContextPolicy.automatic` reserves 5% of the model context window as estimation headroom, with a 64-token minimum and an 8192-token maximum. This is deliberately conservative because BYOKchat currently uses a local approximate token estimator and providers add model-specific serialization overhead.

The output reserve still uses the explicit request value first, then model metadata, with a 256-token minimum.

## Tools and MCP

Tool schemas are part of the model prompt and therefore count against the context window. Context budgeting must include tool names, descriptions, and JSON schemas.

A multi-round tool turn is also dynamic: tool calls and tool results increase the next request size after the first model response. `ChatRuntime` therefore rebuilds the context after every tool round. Older historical turns may be removed as the live tool continuation grows, but the current user turn and all required continuation messages are preserved atomically.

If the current turn plus its required tool continuation cannot fit, BYOKchat fails with `contextWindowExceeded` instead of silently dropping tool state and sending an invalid conversation.

## Why this is implemented in BYOKchatProviderCore

The proven algorithms needed for ordinary chat context are small: output reservation, token-budget reduction, newest-turn retention, atomic tool grouping, and optional summarization. Pulling in a general agent framework would couple conversation semantics to a framework that is not shared across Swift providers and would make provider switching harder.

BYOKchat therefore keeps the reducer provider-independent and uses provider adapters only for transport/wire-format concerns.

## Token counting roadmap

The current estimator intentionally has a safety margin. A future `TokenCounter` abstraction can provide provider/model-specific counting while keeping `ChatContextBuilder` as the policy layer:

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
