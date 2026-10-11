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

Persisted `ChatMessage` usage and billing metadata describe the current saved chat history, including token counts, request counts, tool-call counts, and recorded cost snapshots. This is not a provider billing ledger: regeneration, editing earlier turns, and deleting chats can remove paid responses and reduce totals. Costs may be provider-reported, estimated, incomplete, or unavailable. Telemetry supplements it with data such as time to first token, request duration, throughput, failure classification, tool timing, and MCP timing.

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

If retained telemetry exceeds the bounded recent-event query, the UI explicitly states that performance/reliability values use only the latest query window. Usage and spend remain available from persisted chat history; billing completeness is independent of telemetry retention.

### Request billing and pricing

`ChatRuntime` captures a pricing rule before each inference request and saves one receipt per attempted request in message metadata. It resolves cached model-API prices first, then the bundled direct-provider catalog, then unavailable pricing. Final complete reported cost overrides calculation. Mixed reported/calculated tool rounds retain both amounts and remain estimates. Missing usage survives aggregation because each receipt retains its own completeness; a failed/cancelled later request does not erase earlier paid rounds.

The lightweight conversation index already preserves usage and metadata, including these receipts. Analytics does not need to load every chat shard or reprice old responses. Older calculated records are complete only when one request and both saved plain-token dimensions establish completeness; ambiguous old totals retain their recorded amounts with uncertainty.

See [Model pricing](ModelPricing.md) for concrete coverage, units, source URLs, and supported billing contexts. Complete estimates are complete under the saved rule, not authoritative provider charges. Incomplete estimates use `~` and a partial label; only a provider-reported known subtotal can use `≥`.

### Read outcomes and recovery

The iOS dashboard uses `TelemetryRecorder.loadAnalytics`, which succeeds only when both the required event and statistics reads succeed. A successful empty read shows the healthy-empty state. Either failure, even before the recorder disables after three failures, shows unavailable performance data and hides performance/reliability details across the dashboard, conversation, and breakdowns. Retry resets session failure state and then reloads; resetting health alone does not count as recovery. Saved usage and spend remain visible.

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

## Shared product analytics

The iOS app also uses AppFoundation 1.6.4 for first-party product counters. One app-scoped client is shared between lifecycle tracking, the automatic Pro paywall funnel, and the typed `BYOKAppAnalytics` app events. It uses the Mac app’s app ID `byokchat`, runtime bundle identifier as app key, and server `https://analytics.133043.xyz`, with a one-minute upload interval on iOS. AppFoundation reports the platform as iOS.

Both apps use the canonical `BYOKProductAnalyticsEvent` and `BYOKProductAnalyticsDimension` types in `Sources/BYOKchatProviderCore/BYOKProductAnalytics.swift`. `BYOKAppAnalytics` and `MacAppAnalytics` alias those types; event strings are never declared separately by platform. Mac uses its existing MacAppFoundation client and five-minute upload interval. The same 24 product event names and fixed dimension values are emitted for corresponding actions on both platforms.

These events describe product adoption and outcomes. They do not upload the local SQLite telemetry database, chat usage receipts, prompts, responses, reasoning, attachment contents, resource IDs, provider/model IDs, custom names, URLs, credentials, or raw errors. Dimensions are fixed enum values only. Built-in provider kinds are mapped to a bounded brand token; every custom connection maps to `custom`. The SDK adds its existing bounded installation/session/runtime context.

| Event | Trigger | Dimension |
| --- | --- | --- |
| `onboarding_completed` | Onboarding changes incomplete to complete; replay does not count | None |
| `connection_created` | New provider account and model configuration successfully saved | Built-in provider kind or `custom` |
| `connection_test_succeeded`, `connection_test_failed` | Explicit saved-account connection test returns its outcome | Provider kind or `custom` |
| `chat_turn_started` | Runtime starts an accepted, persisted turn | Provider kind or `custom` |
| `message_sent` | A new user message reaches that accepted turn | None |
| `message_edited`, `response_regenerated` | Edit/resend or regeneration reaches an accepted turn | None |
| `attachment_sent` | An accepted new message contains attachments | `image`, `file`, or `mixed` |
| `chat_turn_completed`, `chat_turn_failed`, `chat_turn_cancelled` | Final generation outcome; recorded once, including throw/cancellation fallbacks | Provider kind or `custom` |
| `chat_preparation_failed` | Generation throws before a turn starts | Provider kind or `custom` |
| `first_response_completed` | First successful persisted response observed by this instrumentation | None; once using an installation-local UserDefaults flag |
| `tool_round_completed` | A tool round is recorded by the runtime, regardless of individual tool outcomes | None |
| `project_created` | Project creation succeeds | None |
| `library_item_saved` | A new Library entry is successfully saved | `image` or `file` |
| `mcp_server_created` | A new MCP server configuration is successfully saved | None |
| `mcp_discovery_succeeded`, `mcp_discovery_failed` | Post-save MCP discovery returns its outcome | None |
| `content_copied` | App copy action writes to the clipboard (iOS shared button; Mac message/reasoning, code, and diagram actions) | `message`, `code`, `diagram`, or `reasoning` |
| `feature_opened` | Explicit feature navigation; iOS also records chat-sheet Analytics openings | `providers`, `library`, `projects`, `mcp`, `analytics`, or `settings` |
| `analytics_range_selected` | An unlocked date range actually changes | `today`, `7d`, `30d`, `month`, or `all` |
| `upgrade_requested` | A Pro feature upsell is first presented | `themes`, `providers`, `projects`, `mcp`, or `analytics_history` |

Mac hooks record the same accepted-turn, terminal-outcome, resource-save, and post-save discovery boundaries as iOS. Mac workspace mutations are serialized by their existing busy guard; an existing Library entry does not count as a new save. Mac navigation records utility-sheet transitions and Settings appearances. Mac upsells record the feature gate request or explicit locked-feature upgrade button.

A failed attempt to create or save a resource is never counted as a successful creation/save. Repeated `ensureListed` calls for an existing Library entry do not count as new saves, and concurrent completions for the same entry are deduplicated within the model. An inline terminal chat event followed by a thrown error counts once. Opening a blank chat without sending is not a chat-start or activation event.

App events are queued serially and submitted asynchronously so event recording does not block user actions. Tracking errors are absorbed. SDK day/count/retention limits still apply. In Debug builds, iOS XCTest hosts and screenshot-fixture runs disable the analytics client and event/activation bookkeeping. Mac XCTest hosts skip these product events and activation bookkeeping; the existing Mac SDK lifecycle/error configuration is preserved.

The 12 common purchase/restore/paywall event names already match between AppFoundation 1.6.4 and MacAppFoundation 1.5.0. MacAppFoundation additionally owns Mac-only offer-code events. Session/install accounting and these commerce events remain owned by AppFoundation and MacAppFoundation; the app does not duplicate those events. The existing in-app Analytics screen continues to derive usage and performance from local chat/telemetry stores.
