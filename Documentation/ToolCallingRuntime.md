# Generic Tool-Calling Runtime

Phase 1 of BYOKchat's MCP roadmap establishes a provider-neutral tool runtime. Phase 2 now adds remote Streamable HTTP MCP configuration, discovery, and execution beneath it. The two layers remain intentionally separated until Phase 3 adds per-chat selection and explicit approval policy.

## Architecture

The generic generation loop is:

`model → normalized tool call → BYOKchat ToolRuntime → normalized tool result → model continues`

Provider adapters translate between their native wire formats and the shared core types:

- `ChatToolDefinition`
- `ChatToolCall`
- `ChatToolResult`
- `ChatToolRound`
- `ProviderToolContinuation`

`ChatRuntime` does not know whether a tool comes from MCP, an app-native integration, or another source.

Remote MCP is a separate layer:

`MCP server → MCPRemoteRuntime → validated/namespaced MCPToolBinding → future ToolRuntime registration`

Phase 2 stops before the final registration step. That keeps remote tools unavailable to model-driven chat execution until Phase 3 can enforce user-visible permissions and approvals.

## Tool registry and execution

`ToolRuntime` is an actor-backed registry of tool definitions and async handlers.

Each registered tool has:

- a stable name
- a human-readable description
- a JSON input schema
- an async handler receiving normalized JSON arguments

Handler failures are converted into `ChatToolResult(isError: true)` and are returned to the model. A normal tool error therefore does not automatically abort the conversation turn.

The app owns one long-lived `ToolRuntime`. Phase 2 also owns a long-lived `MCPRemoteRuntime`, but discovered MCP tools are deliberately not registered into the shared tool registry yet.

## Multi-step orchestration

`ChatRuntime` can perform more than one provider request for a single assistant turn.

1. Build normal conversation context.
2. Include currently available tool definitions in the provider request.
3. Stream the model response.
4. If the model returns tool calls, execute them.
5. Persist a structured `ChatToolRound` immediately.
6. Append the assistant tool-call message and tool results to provider context.
7. Request the model again.
8. Repeat until the model returns a final answer.

A hard limit of 8 consecutive tool-call rounds prevents an unbounded recursive tool loop.

Multiple tool calls returned in one model step are supported. They are currently executed sequentially for deterministic behavior.

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

Full conversation backups include tool rounds through normal Codable persistence. Import validation rejects malformed call/result relationships and oversized continuation metadata.

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

Provider usage is accumulated across every model step in one logical assistant turn. The final persisted assistant message therefore reports the total usage for the full model → tool → model loop rather than only the last request.

## Phase 2 integration

Remote MCP Phase 2 is implemented in `MCPRemoteRuntime` and related workspace/credential types.

It now provides:

- persisted remote HTTPS MCP server configuration
- dedicated Keychain credentials
- MCP `2026-07-28` stateless discovery and request metadata
- fallback to initialize-era Streamable HTTP MCP revisions
- `tools/list` pagination and TTL-aware cached discovery
- `tools/call`
- JSON and request-scoped SSE responses
- current MCP tool-routing headers and `x-mcp-header` parameter mirroring
- deterministic provider-safe namespacing of remote tool names
- MCP configuration in full backups while excluding credentials

See `Documentation/RemoteMCP.md` for transport details.

## Remaining Phase 3 boundary

The generic runtime and remote MCP transport are both present. The remaining MCP v1 product layer is intentionally user-facing and permission-oriented:

- per-chat server/tool selection
- Ask / Always Allow / Disabled policies
- Allow Once / Always Allow / Deny approvals
- human-readable argument review
- running / success / failure tool-call cards
- collapsed result UI and retry
- safe handling of interactive `input_required` responses
- registration/removal of approved MCP bindings in the shared `ToolRuntime`

OAuth, local stdio MCP, deprecated HTTP+SSE transport, MCP Apps, and advanced MCP extensions remain outside the current BYOKchat MCP v1 scope.
