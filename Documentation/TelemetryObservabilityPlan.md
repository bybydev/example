# BYOK Telemetry & Observability Plan

## Goals

Build a local-first observability system for BYOK that answers two different needs without making telemetry part of the app's critical path:

1. **Analytics** — usage, cost, performance, reliability, provider/model/tool trends.
2. **Diagnostic logs** — chronological, privacy-safe lifecycle events useful for debugging provider, network, MCP, sync, and purchase behavior.

Telemetry is explicitly **non-critical and disposable**. It must never prevent app launch, conversation loading, chatting, purchases, project sync, or credential access.

## Non-goals

- Telemetry is not the durable source of truth for billing.
- Raw telemetry is not synced between devices.
- The telemetry database is not a backup format.
- We do not store prompts, assistant content, API keys, authorization headers, tool arguments/results, attachment contents, request/response bodies, or other secret/user content by default.
- We do not refactor unrelated large files just because they are large.

## Source of truth split

```text
ChatMessage + ChatBilling
        |
        +-- durable usage/cost truth

BYOKTelemetry
        |
        +-- timing
        +-- lifecycle
        +-- reliability
        +-- diagnostics
```

Existing `ChatMessage` billing metadata remains authoritative for historical tokens, model request counts, tool call counts, pricing snapshots, and cost. Telemetry supplements it with transient observability data such as time-to-first-token, request duration, throughput, retries, failures, tool/MCP timings, and other lifecycle events.

## Storage decision

Use a dedicated SQLite database, not SwiftData.

Reasons:

- append-heavy workload
- simple chronological queries
- predictable pruning and retention
- cheap aggregation by provider/model/category
- explicit schema versioning
- easy destructive recovery if a migration fails
- independent from domain persistence

Default path should live under Application Support in a telemetry-specific directory. The database must be treated as replaceable.

## Sync model

Raw events stay local to each device.

Every event is designed to carry a `deviceID` and `sessionID` so future export or aggregation remains possible. If cross-device analytics is added later, sync only compact derived records such as daily provider/model summaries rather than the raw SQLite file.

Example future summary:

```text
DailyUsageSummary
- deviceID
- date
- providerID
- modelID
- requestCount
- successCount
- inputTokens
- outputTokens
- costUSD
- totalDurationMs
- totalTTFTMs
- ttftSampleCount
- toolCallCount
```

Summaries should merge by sums/counts. Do not sync pre-computed averages when the underlying total + sample count can be merged safely.

## Privacy model

Telemetry is privacy-safe by default.

Allowed structured data includes identifiers, counts, durations, provider/model names, HTTP status, sanitized error codes, token counts, and other non-content operational fields.

Never store by default:

- API keys or credentials
- Authorization/cookie headers
- prompt text
- assistant response text
- reasoning text
- request/response body content
- tool arguments or tool result content
- attachment bytes or extracted file text
- image data

Metadata is bounded and sanitized before persistence. Suspicious metadata keys are dropped. Long values are truncated.

## Event model

Events use typed categories/severity/data classes plus a string-backed event name type so new event names do not require a database schema migration.

Core dimensions:

- id
- timestamp
- data class: analytics / diagnostic
- category
- event name
- severity
- outcome
- device/session IDs
- conversation/message IDs
- provider/account/model IDs
- duration and TTFT
- token counters
- model request/tool call counters
- HTTP status
- sanitized error code
- bounded sanitized metadata

Planned event families:

```text
chat.turn.started
chat.turn.completed
chat.turn.failed
chat.turn.cancelled
chat.turn.interrupted

provider.request.started
provider.first_token
provider.request.completed
provider.request.failed

context.built

tool.call.started
tool.call.completed
tool.call.failed

mcp.request.started
mcp.request.completed
mcp.request.failed

purchase.started
purchase.completed
purchase.failed

sync.started
sync.completed
sync.failed
```

## Retention and caps

Telemetry is bounded from day one.

Default limits:

- maximum age: **30 days**
- maximum events: **100,000**
- maximum combined SQLite/WAL footprint: **50 MB**
- maintenance cadence: opportunistic, not on every insert

Whichever limit is reached first wins. Oldest events are removed first.

Maintenance should run after a bounded number of inserts and when explicitly requested. Size recovery may checkpoint/truncate WAL and compact the database only when the size cap is exceeded.

## Clear behavior

Two destructive operations are required:

### Clear Diagnostic Logs

Delete events classified as `diagnostic` while preserving analytics telemetry.

### Clear All Telemetry

Close and remove the telemetry SQLite files and recreate a fresh current-schema store.

Neither operation deletes conversation history or `ChatBilling` metadata, so token/cost history remains available from messages.

## Migration and failure policy

Use `PRAGMA user_version` for a small integer schema version.

Preferred migrations are additive. However, preserving telemetry is never more important than app stability.

Startup/open behavior:

```text
open telemetry.sqlite
        |
        +-- current schema -> use it
        |
        +-- migration succeeds -> use migrated DB
        |
        +-- open/migration/schema failure
              |
              +-- close database
              +-- remove telemetry DB/WAL/SHM
              +-- create current schema
              +-- continue app normally
```

If recovery also fails, telemetry recording becomes a no-op for that session. Errors never propagate into chat/provider/purchase flows.

## Large-file decomposition rule

Large files are split **only when the current task already needs to touch them**.

No drive-by refactors. When a phase must substantially modify a large file, first separate the touched responsibility into focused files without behavior changes, then add the phase's feature work.

## Progress

- [x] Phase 1 — Telemetry foundation
- [x] Phase 2 — Chat and provider instrumentation
- [x] Phase 3 — Tool and MCP instrumentation
- [x] Phase 4 — Advanced Analytics UI
- [x] Phase 5 — Developer Logs and controls
- [ ] Phase 6 — Consolidation and hardening

## Implementation phases

### Phase 1 — Telemetry foundation

- typed telemetry event model
- privacy sanitizer
- SQLite append store
- schema versioning
- migration/reset recovery
- age/event/size caps
- explicit prune
- clear diagnostics / clear all
- non-throwing fail-open recorder facade
- unit tests for persistence, privacy, retention, clearing, and recovery
- no runtime instrumentation yet

### Phase 2 — Chat and provider instrumentation

Instrument the chat/provider path and decompose only the large files touched by this work.

Capture:

- turn lifecycle
- provider request lifecycle
- time to first token
- total duration
- tokens/second
- HTTP/provider failure classification
- request/retry counts where available
- context omission/count metrics

`ChatBilling` remains the accounting source of truth.

### Phase 3 — Tool and MCP instrumentation

Instrument tool and MCP lifecycles and decompose only touched MCP/runtime files.

Capture:

- tool start/end/failure
- execution duration
- MCP request duration/status
- tool rounds
- sanitized diagnostic metadata

Never persist tool arguments or result content by default.

### Phase 4 — Advanced Analytics UI

Turn the existing Usage surface into a richer Analytics module instead of growing `UsageViews.swift`.

Views cover:

- spend/tokens/requests from persisted `ChatMessage` billing
- success rate
- median and P95 TTFT
- median generation speed
- median and P95 request duration
- provider/model breakdown with reliability context
- privacy-safe error breakdown
- Today / 7D / 30D / Month / All
- conversation-level drill-down
- local telemetry storage/retention disclosure

`UsageViews.swift` is split into focused files because this phase directly touched it. Performance analytics currently read the latest 5,000 retained local events; if the store contains more, the UI discloses that cap rather than implying complete telemetry history. Usage/cost history remains independent and is reconstructed from messages.

### Phase 5 — Developer Logs and controls

The Settings diagnostics surface now provides:

- chronological event log over the latest 5,000 retained local events
- data-class/category/severity/provider/model/chat filters
- search across structured sanitized fields
- event detail view with timing/token/request/status metadata
- copy/share of a single sanitized event
- filtered JSON diagnostics export with a second privacy-sanitization pass
- recorder health and retry state
- event/database/schema statistics
- explicit retention-cap display and manual maintenance
- clear diagnostic logs without clearing analytics
- clear all telemetry with database recreation

Diagnostics are available in normal builds so a user can inspect/export/clear their own local telemetry. DEBUG-only purchase simulation and onboarding replay were moved into a focused `DeveloperSettingsSection` because this phase directly touched that large Settings file. No unrelated Settings responsibilities were refactored.

### Phase 6 — Consolidation and hardening

- performance profiling
- storage/migration tests
- privacy audit
- query/index review
- remaining touched-file cleanup
- remove dead helpers/duplication introduced during the work

Do not turn Phase 6 into a repository-wide refactor.
