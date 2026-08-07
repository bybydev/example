# Remote MCP

BYOKchat implements remote Model Context Protocol servers over Streamable HTTP with conversation-scoped tool selection, explicit user permissions, and native tool interaction UI.

The MCP v1 architecture is intentionally split into three layers:

1. provider-neutral model/tool orchestration
2. remote MCP transport/discovery/execution
3. per-chat authorization and human interaction

Remote MCP tools are never exposed globally just because a server exists. `MCPConversationToolRuntime` builds the model-visible catalog for each conversation independently.

## Supported protocol eras

BYOKchat prefers MCP `2026-07-28` and automatically falls back to initialize-era Streamable HTTP servers.

### MCP 2026-07-28

The modern protocol is stateless at the MCP transport layer.

BYOKchat:

- probes with `server/discover`
- bounds the discovery probe so older servers that ignore the method can fall back
- sends `MCP-Protocol-Version: 2026-07-28`
- sends `Mcp-Method` on modern requests
- sends `Mcp-Name` for named requests such as `tools/call`
- includes per-request MCP client metadata in `_meta`
- advertises form and URL elicitation support
- does not use `initialize`, `notifications/initialized`, or `Mcp-Session-Id`
- accepts either JSON or request-scoped Server-Sent Events responses
- ignores unrelated notification/progress events on a request SSE stream and accepts only the JSON-RPC response whose ID matches the request

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

The deprecated pre-Streamable-HTTP HTTP+SSE transport is not implemented.

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

Saving an enabled server immediately negotiates the connection and performs initial tool discovery.

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

The result is limited to 64 characters and uses only letters, digits, `_`, and `-`, a conservative common subset for OpenAI-compatible, Anthropic, and Gemini function calling.

This prevents two MCP servers exposing the same remote name from colliding.

## MCP parameter headers

MCP `2026-07-28` can annotate tool input properties with `x-mcp-header`.

BYOKchat validates those annotations during discovery and mirrors matching call arguments into `Mcp-Param-*` headers.

The final `2026-07-28` rules allow only:

- string
- integer
- boolean

`number` is deliberately not accepted for `x-mcp-header`. Header annotation names must be valid HTTP token values, annotations must be reachable through JSON Schema `properties`, and header names must be case-insensitively unique. Invalid annotations cause only that tool to be omitted.

Integer header values must remain within the JSON safe-integer range. Header values that cannot safely be emitted directly are encoded with the MCP Base64 sentinel format.

If a modern server reports a header/schema mismatch, BYOKchat forces fresh discovery and retries the call once using the refreshed tool definition.

## Per-chat tool selection

Each conversation owns its MCP exposure policy in the MCP workspace.

A chat can enable one or more globally enabled MCP servers. Tools from unselected servers are never included in that conversation's provider request.

Each discovered tool has one policy:

- **Ask** — expose the tool to the model, but require approval before remote execution
- **Always Allow** — expose and execute without another approval for that conversation
- **Disabled** — do not expose the tool to the model

The default is **Ask**. This also applies to tools discovered after the server was enabled, so adding a new remote capability never silently inherits blanket execution permission.

Policies are scoped by conversation and namespaced tool identity. Simultaneous chats therefore cannot leak MCP tool visibility or Always-Allow choices into one another.

Execution re-checks the live MCP workspace after the model requests a tool. If a server/tool is disabled after the model saw its schema but before execution, BYOKchat returns a structured denial/error result instead of making the remote call.

## Approval flow

For Ask-policy calls, BYOKchat pauses tool execution and renders an approval card containing:

- MCP server name
- human-readable tool name and description
- model-supplied arguments
- read-only/destructive annotation hints when present

The user can choose:

- **Allow Once**
- **Always Allow**
- **Deny**

Always-Allow is persisted before the waiting call resumes. Denial is returned to the model as a normal tool error result, allowing the model to recover or explain what it could not do instead of crashing the entire assistant turn.

Tool annotations are untrusted presentation hints. Authorization does not depend on a server claiming a tool is read-only or non-destructive.

Cancelling the assistant generation also cancels a pending approval or elicitation wait.

## Tool activity UI

When a provider emits tool calls, the chat timeline immediately shows tool activity rather than appearing frozen.

- pending approval is shown inline
- currently executing calls show a running card
- completed structured tool rounds are persisted with the assistant message
- persisted calls render as expandable Done/Failed cards
- argument and result JSON remains inspectable and selectable

The same structured rounds continue to rebuild provider context on later model turns.

## MCP 2026 multi-round input

Modern MCP can return `resultType: input_required` from `tools/call` instead of completing immediately.

BYOKchat handles this as a bounded logical tool call:

1. parse `inputRequests` and opaque `requestState`
2. fulfill supported embedded requests through native chat interaction UI
3. retry the original `tools/call` with a fresh JSON-RPC request ID
4. include an `inputResponses` entry for every input request
5. echo `requestState` byte-for-byte without interpreting it
6. repeat until `resultType: complete` or the round limit is reached

The current client supports embedded `elicitation/create` requests in:

- **form** mode
- **URL** mode

Form requests use a deliberately restricted flat schema renderer for strings, integers, numbers, booleans, and string arrays. Users can accept, decline, or cancel. URL requests open an HTTPS destination out of band and return only the user's action to the MCP server.

Request-state-only `input_required` rounds are paced before retrying instead of presenting an empty prompt.

Interactive execution is capped at 10 input-required rounds to prevent an unbounded server-driven loop.

Sampling and roots input requests are not advertised and are rejected rather than silently fulfilled.

## Backup and restore

Full BYOKchat backups include:

- MCP server configuration
- cached discovery snapshots
- per-chat enabled server IDs
- per-tool Ask/Always-Allow/Disabled policy

Credentials remain excluded.

Conversation restore can recreate conversations with new local IDs. Import therefore returns a source-to-local conversation ID mapping and remaps MCP chat policy onto the restored conversations. The same portability path now preserves attachment data and structured tool rounds as well.

Older schema-v1 backups and MCP workspaces without chat policy remain decodable.

Deleting an MCP server scrubs that server from every stored chat selection and removes known per-tool policies associated with its cached catalog.

## Deferred beyond MCP v1

The current plan intentionally defers:

- OAuth authorization flows
- local stdio/process MCP servers
- deprecated HTTP+SSE transport
- MCP Apps
- Tasks extension
- sampling
- roots
- subscriptions/listen and broader extension handling

These can be layered onto the existing provider-neutral tool model and conversation-scoped authorization boundary without creating a second chat engine.
