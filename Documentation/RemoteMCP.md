# Remote MCP

BYOKchat Phase 2 implements remote Model Context Protocol servers over Streamable HTTP.

The transport layer is intentionally separate from chat permission policy. Phase 2 can configure servers, negotiate protocol behavior, discover tools, cache their schemas, and execute a tool through the MCP runtime. Discovered MCP tools are **not registered into the chat `ToolRuntime` yet**. Phase 3 adds per-chat selection, approval policy, and visible tool-call UI before a model can invoke remote tools.

## Supported protocol eras

BYOKchat prefers the current MCP `2026-07-28` protocol and automatically falls back to initialize-era Streamable HTTP servers.

### MCP 2026-07-28

The modern protocol is stateless at the MCP transport layer.

BYOKchat:

- probes with `server/discover`
- sends `MCP-Protocol-Version: 2026-07-28`
- sends `Mcp-Method` on modern requests
- sends `Mcp-Name` for named requests such as `tools/call`
- includes per-request MCP client metadata in `_meta`
- does not use `initialize`, `notifications/initialized`, or `Mcp-Session-Id`
- accepts either JSON or request-scoped Server-Sent Events responses
- ignores unrelated notification events on a request SSE stream and accepts only the JSON-RPC response whose ID matches the request

### Legacy Streamable HTTP fallback

For servers that do not support the modern revision, BYOKchat can negotiate:

- `2025-11-25`
- `2025-06-18`
- `2025-03-26`

The legacy path:

1. sends `initialize`
2. validates the negotiated protocol version
3. captures `Mcp-Session-Id` when the server issues one
4. sends `notifications/initialized`
5. reuses the session ID on later requests
6. reinitializes once if a stateful server reports an expired session with HTTP 404

The older deprecated HTTP+SSE transport is not implemented. Phase 2 supports remote **Streamable HTTP** only.

## Server configuration

Settings → MCP Servers supports:

- server display name
- HTTPS endpoint
- enable/disable state
- no authentication
- bearer-token authentication
- one custom authentication header
- optional additional non-secret headers

Remote endpoints must use HTTPS and cannot contain embedded URL credentials or fragments.

Protocol-owned headers are reserved and cannot be overridden through additional headers.

## Credentials

MCP credentials use a dedicated Keychain vault keyed by MCP server ID.

Credentials are never stored in:

- `mcp-servers-v1.json`
- provider configuration
- full BYOKchat backups
- cached MCP discovery snapshots

A replace-style full restore removes affected MCP credentials so restored configuration cannot silently inherit a stale secret.

## Tool discovery

BYOKchat discovers tools with `tools/list` and supports pagination through `nextCursor`.

For modern servers:

- `ttlMs` controls how long the persisted tool catalog remains fresh
- `cacheScope` is preserved with the cached snapshot
- the most restrictive cache scope across paginated pages wins

For legacy servers, BYOKchat uses a short local five-minute discovery cache.

Each tool is validated independently. A malformed tool definition is omitted and recorded as a discovery warning instead of causing all tools from the server to disappear.

Cached snapshots contain:

- protocol era/version
- server implementation metadata when supplied
- server capabilities and instructions
- tool names, descriptions, schemas, and annotations
- cache expiry metadata
- discovery warnings

## Tool names

Remote MCP tool names are not sent directly to model provider function APIs.

BYOKchat creates a deterministic exposed name using:

- the MCP server ID
- a sanitized remote tool name
- a stable hash of the full server ID plus remote name

The result is limited to 64 characters and uses only letters, digits, `_`, and `-`, which is a conservative common subset for OpenAI-compatible, Anthropic, and Gemini function calling.

This also prevents two MCP servers exposing the same remote tool name from colliding in the generic tool runtime.

## MCP parameter headers

MCP `2026-07-28` can annotate tool input properties with `x-mcp-header`.

BYOKchat validates those annotations during discovery and mirrors matching call arguments into `Mcp-Param-*` headers.

Supported annotated value types are:

- string
- integer
- number
- boolean

Annotations must be reachable through JSON Schema `properties`, and header names must be case-insensitively unique. Invalid annotations cause only that tool to be omitted.

Header values that cannot safely be emitted as direct ASCII header values are encoded with the MCP Base64 sentinel format.

If a modern server reports a header/schema mismatch, BYOKchat forces a fresh `tools/list` and retries the call once using the refreshed tool definition.

## Tool calls

`MCPRemoteRuntime.callTool` sends `tools/call` and normalizes the result into `MCPToolCallOutput`.

- plain text-only content becomes a string
- `structuredContent` is preserved as JSON
- mixed/non-text content remains structured JSON
- MCP `isError` is preserved as a tool-result error flag

`resultType: input_required` is recognized but not completed in Phase 2. It surfaces as an explicit `inputRequired` error because Multi Round-Trip Request UI belongs with Phase 3 approval and interaction work.

## Streamable HTTP responses

POST requests advertise both:

- `application/json`
- `text/event-stream`

If a server chooses request-scoped SSE, BYOKchat incrementally decodes the stream, tolerates notifications/progress events, and returns only the matching JSON-RPC result/error for the pending request.

Cancellation closes consumption of the active request stream through the existing HTTP transport task cancellation path.

## Backup and restore

Full BYOKchat backups now include MCP server configuration and cached discovery snapshots as an optional backward-compatible field in backup schema v1.

Older schema-v1 backups without MCP data remain decodable.

MCP credentials remain excluded.

## Phase 3 boundary

Phase 2 deliberately does **not** make remote tools available to the model automatically.

Phase 3 adds:

- per-chat MCP server/tool selection
- Ask / Always Allow / Disabled policy
- Allow Once / Always Allow / Deny flows
- human-readable argument review
- running / success / failure tool cards
- collapsed tool results
- retry UX
- handling for interactive `input_required` results where appropriate

Only after those controls exist should discovered MCP tools be registered into the shared chat `ToolRuntime`.

## Deferred beyond MCP v1

The current plan intentionally defers:

- OAuth authorization flows
- local stdio/process MCP servers
- deprecated HTTP+SSE transport
- MCP Apps
- Tasks extension
- subscriptions/listen and broader extension handling

These can be layered onto the remote runtime without changing the provider-neutral Phase 1 tool-call model.
