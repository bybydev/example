# Telemetry and Observability

BYOKchat has a local-first observability system for two distinct purposes:

1. **Analytics** — usage, cost, performance, reliability, provider/model/tool trends.
2. **Diagnostics** — chronological privacy-safe lifecycle events for investigating provider, network, MCP, storage, and app behavior.

Telemetry is deliberately non-critical and disposable. Failure to open, migrate, write, query, prune, or export telemetry must never prevent app launch, conversation loading, chatting, purchases, project sync, or credential access.

## Source of truth

Usage accounting and observability are intentionally separate.

```text
ChatMessage + ChatBilling
        |
        +-- durable usage and cost truth

BYOK telemetry
        |
        +-- timing
        +-- lifecycle
        +-- reliability
        +-- diagnostics
```

Persisted `ChatMessage` billing metadata remains authoritative for historical token counts, request counts, tool-call counts, pricing snapshots, and cost. Telemetry supplements it with data such as time to first token, request duration, throughput, failure classification, tool timing, and MCP timing.

Clearing or losing telemetry therefore does not remove historical chat usage or spend.

## Storage

Telemetry uses its own SQLite database under Application Support rather than SwiftData or the conversation store.

The workload is append-heavy, chronological, retention-bound, and disposable. A dedicated SQLite store provides explicit control over schema validation, pruning, indexing, compaction, and destructive recovery without introducing domain-model observation or object-graph behavior.

SQLite is configured with WAL and normal synchronous mode. The store is actor-isolated, so writes and maintenance are serialized even when lifecycle events arrive concurrently.

Raw telemetry is local to each device. The SQLite file itself must never be synchronized between devices.

If cross-device analytics is added later, it should sync compact derived records such as daily provider/model summaries containing mergeable sums and sample counts rather than raw events or precomputed averages.

## Event model

Each event can contain:

- unique event ID and timestamp
- analytics or diagnostic data class
- category, event name, severity, and outcome
- device and session IDs
- conversation and message IDs
- provider, account, and model IDs
- total duration and time to first token
- token counters
- model-request and tool-call counters
- HTTP status
- stable machine-readable error code
- bounded sanitized metadata

Event names are string-backed so adding a new lifecycle event does not require a database migration.

Current instrumentation covers chat turns, context construction, provider requests, tool calls, and MCP transport/execution. Provider completion events contain performance metrics such as TTFT, duration, and output-token throughput where available.

## Privacy boundary

Telemetry stores operational metadata, not conversation content.

The default persistence path must never store:

- API keys or credentials
- authorization, cookie, or secret headers
- prompt text
- assistant response text
- reasoning text
- request or response bodies
- tool arguments or tool results
- attachment bytes or extracted file content
- image data
- endpoint URLs, request/response URLs, hostnames, or URL query data

Metadata is sanitized before SQLite persistence. Sensitive keys and URL/credential-like values are dropped, metadata count and value lengths are bounded, and invalid numeric metrics are discarded.

`errorCode` is restricted to a short machine-readable form. Free-form error strings or values containing URL-like content are replaced with `redacted` rather than persisted.

Diagnostics text and JSON export run the privacy sanitizer again even though persisted events are already sanitized. This keeps export safe if an unsanitized in-memory event is ever passed directly to the formatter.

## Retention and query bounds

Default storage limits are:

- maximum age: **30 days**
- maximum events: **100,000**
- maximum combined SQLite/WAL footprint: **50 MB**
- automatic maintenance after a bounded number of inserts

Whichever limit is reached first wins. Oldest events are removed first.

The maximum recent-event query is centralized as `TelemetryStoreConfiguration.maximumRecentEventQueryCount` and currently equals **5,000**. Analytics and the Event Log use the same limit, so UI disclosure and store behavior cannot drift.

Size maintenance first checkpoints WAL. If the database is still above its cap, the store removes old events in batches and compacts only when necessary.

## Schema and self-recovery

The database uses `PRAGMA user_version` plus structural validation of the required `telemetry_events` columns.

Opening follows this policy:

```text
open telemetry.sqlite
        |
        +-- valid current schema -> use it
        |
        +-- migration succeeds -> verify schema/indexes -> use it
        |
        +-- open/migration/schema failure
              |
              +-- close database
              +-- remove telemetry DB/WAL/SHM
              +-- create current schema
              +-- continue app normally
```

Required indexes are recreated idempotently when the store opens. A database that claims the current schema version but is structurally incomplete is treated as disposable and recreated.

If storage continues failing, `TelemetryRecorder` absorbs the error. After three consecutive failures it disables recording for the session instead of propagating failure into product code. Diagnostics exposes an explicit retry action so recording can resume after the underlying storage problem is fixed.

## Index policy

The store maintains indexes for actual access patterns:

- timestamp
- data class + timestamp
- category + timestamp
- provider + timestamp
- model + timestamp
- conversation + timestamp

Do not add speculative indexes for arbitrary metadata. Diagnostic filtering is performed over a bounded recent-event set in memory, and avoiding unnecessary indexes keeps append cost predictable.

## Analytics

The Analytics screen combines two sources without conflating them:

- `ChatBilling` supplies spend, tokens, model request counts, tool-call counts, and historical accounting.
- telemetry supplies success rate, TTFT, generation duration, throughput, provider/model reliability, MCP reliability, tool reliability, and privacy-safe failure breakdowns.

Supported ranges include Today, 7 Days, 30 Days, Month, and All. Conversation-level drill-down uses the same accounting/telemetry split.

If retained telemetry exceeds the bounded recent-event query, the UI explicitly states that performance/reliability values use only the latest query window. Usage and spend remain complete relative to persisted chat history.

## Diagnostics

Settings → Diagnostics & Logs provides:

- recorder health and retry state
- event count, database size, schema version, oldest/newest event
- configured retention limits
- manual cleanup
- chronological Event Log
- search and filtering by data class, category, severity, provider, model, and conversation
- event detail with structured timing/status metadata
- copy/share of a sanitized event
- filtered sanitized JSON export

Two clear operations have intentionally different scopes:

### Clear Diagnostic Logs

Deletes only events whose data class is `diagnostic`. Analytics telemetry is preserved.

### Clear All Telemetry

Removes and recreates the telemetry SQLite store. Conversation history, billing metadata, credentials, projects, provider configuration, and purchase state are unaffected.

## Runtime isolation

Chat/provider/tool/MCP instrumentation emits structured events through `TelemetryRecorder`. Telemetry writes are submitted independently of the provider streaming path and are not required for generation to proceed.

A telemetry failure must always degrade to missing observability, never to a failed chat or failed tool execution.

## Regression coverage

Permanent regression suites cover:

- structured event round-trip
- metadata and error-code privacy sanitization
- age, event-count, and physical database-size retention
- diagnostic-only and full clearing
- corrupt/malformed database recreation
- fail-open behavior and explicit recovery
- concurrent writes without event loss
- automatic maintenance
- analytics aggregation and error de-duplication
- diagnostic filtering and double-sanitized export
- chat/provider lifecycle instrumentation
- MCP transport and tool lifecycle instrumentation without arguments, results, credentials, endpoints, or response bodies leaking into telemetry

These tests are organized by responsibility rather than by implementation milestone so they remain useful as the telemetry system evolves.
