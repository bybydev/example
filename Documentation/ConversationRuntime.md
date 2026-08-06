# Conversation Runtime

Phase 3 adds BYOKchat's local conversation engine on top of the independent provider platform.

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

Partial text and reasoning are persisted approximately every 300 milliseconds and immediately on completion, failure, or cancellation.

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

The main app now contains:

- Chats tab with conversation list, create, rename, and delete
- Native chat screen with streaming answer and reasoning display
- Stop generation
- Per-conversation provider account and model selection
- Per-conversation system prompt, reasoning, temperature, and output-token options
- Context omission indicator
- Providers tab
- Provider console tab
