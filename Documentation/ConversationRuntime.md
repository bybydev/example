# Conversation Runtime

BYOKchat's local conversation engine sits on top of the independent provider platform and supports editable linear history, regeneration, drafts, search, context management, and immediate lifecycle flushing.

## Persistence

Conversations are stored in a versioned JSON workspace at `Application Support/BYOKchat/conversations-v1.json`.

The conversation file contains:

- Conversation titles and timestamps
- Provider, account, and model snapshots
- Per-chat system prompts and generation options
- User and assistant messages
- Visible response text and separately stored reasoning
- Usage, finish reason, and safe provider metadata
- Failed, cancelled, and interrupted message states

Credentials and authorization headers never enter the conversation workspace.

## Message lifecycle

Assistant messages move through these states:

```text
pending -> streaming -> complete
                    -> failed
                    -> cancelled
pending/streaming at relaunch -> interrupted
```

Partial text and reasoning are persisted approximately every 300 milliseconds and immediately on completion, failure, cancellation, or app deactivation.

## Context building

The context builder:

1. Preserves the system prompt.
2. Includes complete user and assistant messages only.
3. Excludes pending, streaming, failed, cancelled, and interrupted assistant messages.
4. Keeps the newest complete turns.
5. Removes whole oldest turns when the model context budget is exceeded.
6. Reserves output capacity using model metadata when available.
7. Records how many earlier messages were omitted.

Assistant reasoning is preserved separately and is passed back only through provider adapters that support it.

## Cancellation and retry safety

Only one generation may run for a conversation at a time. Stop explicitly cancels the provider stream and waits for the runtime to persist a cancelled state. The runtime never automatically retries a generation because a provider may already have processed and billed the request.

## App surface

The app exposes:

- local conversation list and search, with create, rename, pin, and delete actions
- native chat screen with streaming answer, reasoning, Markdown, and code blocks
- Stop, edit and resend, and regenerate
- per-conversation draft restoration
- per-conversation provider account and searchable model selection
- per-conversation system prompt and supported model parameters
- context omission and repair indicators
- Settings with provider management and provider console
