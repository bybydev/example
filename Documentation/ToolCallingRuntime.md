# Generic Tool-Calling Runtime

BYOKchat's MCP roadmap is built on a provider-neutral tool runtime. Phase 1 established normalized model/tool orchestration, Phase 2 added remote MCP transport/discovery, and Phase 3 adds conversation-scoped exposure plus explicit user interaction.

## Architecture

The generic generation loop is:

`model → normalized tool call → conversation tool executor → normalized tool result → model continues`

Provider adapters translate between their native wire formats and the shared core types:

- `ChatToolDefinition`
- `ChatToolCall`
- `ChatToolResult`
- `ChatToolRound`
- `ProviderToolContinuation`

`ChatRuntime` does not know whether a tool comes from MCP, an app-native integration, or another source.

The execution boundary is represented by `ChatConversationToolExecuting`:

- `availableTools(conversationID:)`
- `execute(_:conversationID:)`

This is important for MCP because the model-visible catalog and authorization state depend on the current conversation.

## App-native tool registry

`ToolRuntime` remains an actor-backed registry for normalized app-native tool definitions and async handlers.

Each registered tool has:

- a stable name
- a human-readable description
- a JSON input schema
- an async handler receiving normalized JSON arguments

Handler failures are converted into `ChatToolResult(isError: true)` and returned to the model. A normal tool error therefore does not automatically abort the conversation turn.

`ToolRuntime` also conforms to `ChatConversationToolExecuting` by exposing its global app-native catalog for every conversation.

## MCP conversation executor

`MCPConversationToolRuntime` composes the app-native registry with the remote MCP runtime.

For each conversation it:

1. loads that chat's MCP server/tool policy
2. intersects selected servers with globally enabled servers
3. refreshes stale selected catalogs when possible
4. removes Disabled tools
5. combines the remaining MCP definitions with app-native tools
6. returns only that conversation's final model-visible catalog

MCP bindings are **not** globally registered into `ToolRuntime`. This avoids cross-chat leakage when two conversations generate simultaneously with different tool selections or permissions.

Before every remote execution, the runtime re-checks current chat policy rather than trusting the catalog snapshot that was sent to the model.

## Multi-step orchestration

`ChatRuntime` can perform more than one provider request for a single assistant turn.

1. Build normal conversation context.
2. Ask the conversation tool executor for the current tool catalog.
3. Include those definitions in the provider request.
4. Stream the model response.
5. If the model returns tool calls, emit a live `toolCallsStarted` event.
6. Execute the calls through the conversation-scoped executor.
7. Persist a structured `ChatToolRound` immediately.
8. Append the assistant tool-call message and tool results to provider context.
9. Request the model again.
10. Repeat until the model returns a final answer.

A hard limit of 8 consecutive model/tool rounds prevents an unbounded recursive tool loop.

Multiple tool calls returned in one model step are supported. They execute sequentially for deterministic approval and result ordering.

## Permission results

Remote MCP execution can pause before the network call when a tool has Ask policy.

- **Allow Once** resumes the current call only.
- **Always Allow** persists the conversation/tool policy before the call resumes.
- **Deny** produces a structured tool error result that the provider receives in the normal continuation sequence.
- **Disabled** tools are omitted from the provider request and are also rejected if a stale model call reaches execution.

The approval continuation is cancellation-aware, so stopping generation also releases a waiting tool call.

## MCP multi-round input

MCP `2026-07-28` can return `resultType: input_required` from `tools/call`.

`MCPConversationToolRuntime` drives the logical call through up to 10 interactive rounds:

1. parse embedded input requests
2. fulfill supported `elicitation/create` requests through the app interaction center
3. create bare MCP input response result objects
4. retry the original `tools/call` with a fresh JSON-RPC ID
5. echo opaque `requestState` unchanged
6. continue until `resultType: complete`

Request-state-only rounds are paced before retrying. Unsupported sampling/roots requests fail closed because BYOKchat does not advertise those capabilities.

## Persistence and recovery

Tool execution is persisted structurally on the assistant `ChatMessage` rather than flattened into Markdown or synthetic user text.

Each `ChatToolRound` stores:

- normalized calls
- normalized results
- any assistant text/reasoning emitted before the calls
- usage for that provider step
- provider-opaque continuation metadata where required
- timestamp

The conversation context builder reconstructs the exact assistant-call/result sequence on later turns.

Because a completed round is persisted before the next model request begins, a relaunch does not lose already executed tool results. Existing interrupted-generation repair still marks an unfinished assistant turn as interrupted.

Full conversation backups include tool rounds through normal Codable persistence. Import validation rejects malformed call/result relationships and oversized continuation metadata. Conversation restore also explicitly replays persisted tool rounds and attachment data.

## Provider mappings

### OpenAI-compatible / OpenRouter / DeepSeek

- Tool declarations use Chat Completions `tools` with `type: function`.
- Assistant calls use `tool_calls`.
- Tool results use `role: tool` and `tool_call_id`.
- Streaming `delta.tool_calls` fragments are accumulated by index and function-argument JSON is parsed only after the complete stream step is received.

### Anthropic Messages

- Tool declarations use native `tools` with `input_schema`.
- Assistant calls use `tool_use` blocks.
- Tool results use `tool_result` blocks in the following user message.
- Streaming `input_json_delta.partial_json` fragments are reassembled before execution.
- Signed thinking blocks are retained as opaque `ProviderToolContinuation` data and replayed unchanged when a tool turn continues.

### Gemini GenerateContent

- Tool declarations use `functionDeclarations`.
- Assistant calls use `functionCall` parts.
- Tool results use `functionResponse` parts.
- Gemini function-call IDs are preserved and matched to results.
- Gemini thought signatures associated with function calls are retained as opaque `ProviderToolContinuation` data and replayed on the matching call part.

## Usage accounting

Provider usage is accumulated across every model step in one logical assistant turn. The final persisted assistant message therefore reports total usage for the complete model → tool → model loop rather than only the last request.

## MCP v1 status

The scoped MCP v1 product layer is implemented:

- Phase 1 — generic tool runtime
- Phase 2 — remote Streamable HTTP MCP
- Phase 3 — per-chat tools, permissions, approvals, interaction cards, and MCP multi-round elicitation

OAuth, local stdio MCP, deprecated HTTP+SSE transport, MCP Apps, Tasks, sampling, roots, and advanced MCP extensions remain outside the current BYOKchat MCP v1 scope.

See `Documentation/RemoteMCP.md` for protocol and permission details.
