# macOS Analytics Redesign

Status: approved for implementation in PR #19.

## Goal

Bring Analytics into the same macOS workspace language now used by Library, Projects, AI Providers, and MCP Servers while preserving the existing analytics model, telemetry semantics, usage reconstruction, budget settings, and Free/Pro feature split.

The redesign is intentionally presentation-focused. It must not introduce a storage migration or change how usage, pricing, telemetry, or budgets are calculated.

## Current problems

The current Pro Analytics screen still behaves like an older nested modal:

- it renders its own Analytics header even though `MacUtilitySheetContainer` already owns the utility title and dismiss button;
- it adds a second Done button inside that outer modal;
- it uses an internal `NavigationSplitView` with a permanent conversation sidebar;
- it still opts into the generic utility footer while Library, Projects, AI Providers, and MCP Servers are full-height workspaces;
- secondary analytics sections are stacked as a long report instead of using the card hierarchy established by the newer workspaces;
- Free Analytics is visually separate from Pro Analytics rather than being the same dashboard with fewer capabilities.

## Design principles

1. The utility container owns the single top-level Analytics title and Close control.
2. Analytics itself uses a flat workspace, never a nested `NavigationSplitView`.
3. Overview and Conversations are peer workspace sections.
4. Conversation analytics are a drill-in from the Conversations section, with an explicit Back affordance.
5. Range and Refresh controls stay consistently available at the workspace level.
6. Free and Pro use the same visual system; Pro unlocks additional sections and conversation-level analytics.
7. Preserve existing metrics and semantics rather than inventing new analytics.
8. Dense secondary information should use responsive cards instead of one long vertical report where practical.

## Workspace structure

```text
ANALYTICS
│
├── Overview
│
└── Conversations
      │
      └── Conversation Detail
```

Top-level utility shell:

```text
┌──────────────────────────────────────────────────────────────────────┐
│ ▥  Analytics                                                   ×    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  [ Overview ] [ Conversations ]          [ 7D | Month | 90D ]  ↻   │
│                                                                      │
│  ... workspace content ...                                           │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

The outer `MacUtilitySheetContainer` remains the owner of the title and dismiss action. Analytics must not render another Analytics title or Done button.

## Overview

Usage metrics remain the primary full-width summary:

```text
USAGE

┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌─────────────┐
│ SPEND        │ │ REQUESTS     │ │ INPUT        │ │ OUTPUT      │
│ ~$4.27       │ │ 1,284        │ │ 2.4M         │ │ 418K        │
└──────────────┘ └──────────────┘ └──────────────┘ └─────────────┘

┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ CACHED INPUT │ │ REASONING    │ │ TOOL CALLS   │
│ 980K         │ │ 312K         │ │ 148          │
└──────────────┘ └──────────────┘ └──────────────┘
```

Deeper analytics should use responsive section cards, ideally two columns where width allows:

```text
┌────────────────────────────┐  ┌────────────────────────────────┐
│ Performance                │  │ Reliability                    │
│ Median TTFT       420 ms   │  │ Success Rate            99.2% │
│ P95 TTFT           1.2 s   │  │ Succeeded               1,261 │
│ Median Duration     4.8 s   │  │ Failed                     10 │
│ Median Speed    54 tok/s   │  │ Tool Success            98.7% │
└────────────────────────────┘  └────────────────────────────────┘

┌────────────────────────────┐  ┌────────────────────────────────┐
│ Providers                  │  │ Models                         │
│ OpenAI         ~$2.18      │  │ GPT-5.6            ~$1.82     │
│ Anthropic      ~$1.47      │  │ Sonnet 4.6         ~$1.31     │
└────────────────────────────┘  └────────────────────────────────┘

┌────────────────────────────┐  ┌────────────────────────────────┐
│ Monthly Budget             │  │ Local Analytics                │
│ $4.27 / $10.00             │  │ Telemetry events       12,481 │
│ ████████░░░░░░░░░ 43%     │  │ Database              2.8 MB  │
└────────────────────────────┘  └────────────────────────────────┘
```

Errors remain conditional and should have stronger warning hierarchy when present.

## Conversations

Replace the permanent sidebar with a searchable flat browser:

```text
[ Overview ] [ Conversations ]          [ 7D | Month | 90D ]  ↻

🔍 Search conversations

CONVERSATIONS

┌────────────────────────────────────────────────────────────────┐
│ Refactor provider architecture                            →    │
│ Updated Today, 9:42 AM                                          │
│                                                                │
│ 82 requests     148K tokens        ~$0.72                      │
└────────────────────────────────────────────────────────────────┘
```

Requirements:

- search by conversation title;
- preserve the model's current most-recently-updated ordering;
- show range-aware request/token/spend context on each card;
- clicking a card drills into conversation analytics;
- no permanent nested sidebar.

## Conversation detail

```text
‹ Conversations

Refactor provider architecture                         Month

┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌──────────────┐
│ SPEND       │ │ REQUESTS    │ │ INPUT       │ │ OUTPUT       │
│ ~$0.72      │ │ 82          │ │ 118K        │ │ 30K          │
└─────────────┘ └─────────────┘ └─────────────┘ └──────────────┘

┌────────────────────────────┐  ┌────────────────────────────────┐
│ Performance                │  │ Reliability                    │
│ Median TTFT       380 ms   │  │ Success Rate            100%  │
│ P95 TTFT           1.1 s   │  │ Succeeded                  82 │
│ Median Speed    61 tok/s   │  │ Failed                      0 │
└────────────────────────────┘  └────────────────────────────────┘
```

The existing `conversationSnapshot` remains authoritative.

## Free Analytics

Free Analytics should use the same workspace/card language:

```text
Overview                                         This Month    ↻

┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌─────────────┐
│ SPEND        │ │ REQUESTS     │ │ INPUT        │ │ OUTPUT      │
│ ~$0.82       │ │ 194          │ │ 318K         │ │ 57K         │
└──────────────┘ └──────────────┘ └──────────────┘ └─────────────┘

┌────────────────────────────────────────────────────────────────┐
│ ♛ Advanced Analytics                                      PRO │
│ Performance · Reliability · Providers · Models · Conversations │
│ Cached/reasoning tokens · Tool usage · Budgets                 │
│                                             [ Unlock BYOK Pro ] │
└────────────────────────────────────────────────────────────────┘
```

Free remains monthly-only and continues reconstructing usage from local conversation history. No Pro-only telemetry features should be exposed through the free UI.

## Existing behavior to preserve

- `MacAnalyticsModel` loading and sorting;
- `UsageAnalytics.snapshot` and `conversationSnapshot`;
- spend partial/unknown-cost semantics;
- cached input, reasoning, and tool-call metrics;
- provider and model breakdowns;
- provider/tool/MCP performance and reliability metrics;
- conditional error breakdown;
- monthly budget and warning threshold stored in `AppStorage`;
- local telemetry statistics and retention explanation;
- Free/Pro gating through `MacAnalyticsGateView`;
- refresh behavior;
- local-only usage messaging.

## Implementation plan

### Phase 1 — shell

- remove Analytics' nested `NavigationSplitView`;
- remove the inner Analytics title and Done button;
- make `.analytics` full-height/no-footer;
- introduce explicit `Overview` and `Conversations` workspace sections.

### Phase 2 — Pro overview

- retain current usage metric grid;
- convert performance, reliability, provider/model breakdown, budget, local analytics, and errors into the new card hierarchy;
- keep range and refresh controls at workspace level.

### Phase 3 — conversations

- add searchable flat conversation cards;
- show range-aware requests/tokens/spend summary;
- add conversation drill-in and Back behavior;
- retain existing conversation performance/reliability metrics.

### Phase 4 — Free Analytics

- remove the standalone legacy title treatment;
- reuse the new metric/card language;
- keep monthly-only Free capabilities and the Pro upgrade surface.

### Phase 5 — regression/validation

- add a small test contract for Analytics workspace sections;
- run the exact PR head through the macOS `mycli deploy mac` validation path;
- fix any compile/runtime integration issue on the same PR.

## Non-goals

- no storage migration;
- no changes to telemetry collection or retention;
- no changes to pricing reconstruction;
- no new charts or persisted analytics history;
- no remote analytics service integration;
- no changes to Free/Pro entitlement rules.
